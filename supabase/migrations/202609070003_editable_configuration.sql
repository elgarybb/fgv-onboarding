-- Editable restaurant configuration and compatible booking rule changes.
BEGIN;
ALTER TABLE public.establishments ADD COLUMN settings_revision integer NOT NULL DEFAULT 1;
CREATE OR REPLACE FUNCTION public.fgv_save_settings(p_establishment_id uuid,p_settings jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE d text; s jsonb; part jsonb; a time; b time; tz text; r record; service_day date; fits boolean; peak integer; conflicts integer:=0;
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 PERFORM 1 FROM public.establishments WHERE id=p_establishment_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Restaurante inexistente.'; END IF;
 IF jsonb_typeof(p_settings->'schedules') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Configura los horarios.'; END IF;
 FOREACH d IN ARRAY ARRAY['monday','tuesday','wednesday','thursday','friday','saturday','sunday'] LOOP
  s:=p_settings->'schedules'->d;
  IF s IS NULL OR jsonb_typeof(s->'closed') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Falta el horario de %.',d; END IF;
  IF NOT (s->>'closed')::boolean THEN
   IF jsonb_typeof(s->'services') IS DISTINCT FROM 'array' OR jsonb_array_length(s->'services') NOT BETWEEN 1 AND 2 THEN RAISE EXCEPTION 'Indica uno o dos turnos para %.',d; END IF;
   FOR part IN SELECT value FROM jsonb_array_elements(s->'services') LOOP
    IF coalesce(part->>'open','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' OR coalesce(part->>'close','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN RAISE EXCEPTION 'Hora inválida en %.',d; END IF;
    a:=(part->>'open')::time; b:=(part->>'close')::time;
    IF a=b THEN RAISE EXCEPTION 'La apertura y el cierre no pueden coincidir.'; END IF;
   END LOOP;
  END IF;
 END LOOP;
 -- New duration and notice rules apply to new/edited bookings. Accepted times stay intact.
 SELECT timezone INTO tz FROM public.establishments WHERE id=p_establishment_id;
 WITH events AS (
 SELECT start_at AS at,party_size AS delta FROM public.reservations WHERE establishment_id=p_establishment_id AND status IN ('pending','confirmed') AND end_at>now()
 UNION ALL SELECT end_at,-party_size FROM public.reservations WHERE establishment_id=p_establishment_id AND status IN ('pending','confirmed') AND end_at>now()
 ), grouped AS (SELECT at,sum(delta) AS delta FROM events GROUP BY at), running AS (SELECT sum(delta) OVER(ORDER BY at) AS occupied FROM grouped)
 SELECT coalesce(max(occupied),0) INTO peak FROM running;
 IF peak>(p_settings->>'total_capacity')::int THEN RAISE EXCEPTION 'El aforo debe ser al menos % para respetar las reservas aceptadas.',peak; END IF;
 FOR r IN SELECT * FROM public.reservations WHERE establishment_id=p_establishment_id AND status IN ('pending','confirmed') AND end_at>now() LOOP
  fits:=false;
  FOR service_day IN SELECT (r.start_at AT TIME ZONE tz)::date UNION ALL SELECT (r.start_at AT TIME ZONE tz)::date-1 LOOP
   d:=(ARRAY['sunday','monday','tuesday','wednesday','thursday','friday','saturday'])[extract(dow FROM service_day)::int+1];
   s:=p_settings->'schedules'->d;
   IF (s->>'closed')::boolean THEN CONTINUE; END IF;
   FOR part IN SELECT value FROM jsonb_array_elements(s->'services') LOOP
    a:=(part->>'open')::time; b:=(part->>'close')::time;
    IF r.start_at >= ((service_day+a) AT TIME ZONE tz) AND r.end_at <= ((service_day+CASE WHEN b<a THEN 1 ELSE 0 END+b) AT TIME ZONE tz) THEN fits:=true; END IF;
   END LOOP;
  END LOOP;
  IF NOT fits THEN conflicts:=conflicts+1; END IF;
 END LOOP;
 IF conflicts>0 THEN RAISE EXCEPTION 'Este horario deja % reservas aceptadas fuera de apertura. Amplía el horario o reubica esas reservas antes de guardar.',conflicts; END IF;
 INSERT INTO public.reservation_settings VALUES(p_establishment_id,(p_settings->>'total_capacity')::int,(p_settings->>'max_people')::int,
 (p_settings->>'duration_minutes')::int,(p_settings->>'min_notice_minutes')::int,(p_settings->>'max_advance_days')::int,p_settings->'schedules',now())
 ON CONFLICT(establishment_id) DO UPDATE SET total_capacity=excluded.total_capacity,max_people=excluded.max_people,
 duration_minutes=excluded.duration_minutes,min_notice_minutes=excluded.min_notice_minutes,max_advance_days=excluded.max_advance_days,schedules=excluded.schedules,updated_at=now();
END; $$;

CREATE OR REPLACE FUNCTION public.fgv_update_restaurant(p_establishment_id uuid,p_data jsonb,p_expected_revision integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE e public.establishments; c jsonb; mode text; provider text; v_phone text; v_email text; tz text;
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 SELECT * INTO e FROM public.establishments WHERE id=p_establishment_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Restaurante inexistente.'; END IF;
 IF e.settings_revision IS DISTINCT FROM p_expected_revision THEN RAISE EXCEPTION 'Otra persona ha actualizado estos datos. Recarga la página antes de guardar.'; END IF;
 IF jsonb_typeof(p_data) IS DISTINCT FROM 'object' OR length(btrim(coalesce(p_data->>'name',''))) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'Indica el nombre del restaurante.'; END IF;
 IF length(coalesce(p_data->>'address',''))>300 OR length(coalesce(p_data->>'city',''))>120 OR length(coalesce(p_data->>'business_type','')) NOT BETWEEN 1 AND 80 THEN RAISE EXCEPTION 'Revisa los datos del restaurante.'; END IF;
 v_phone:=regexp_replace(coalesce(p_data->>'phone',''),'[\s().-]','','g'); v_email:=btrim(coalesce(p_data->>'email','')); tz:=p_data->>'timezone';
 IF v_phone<>'' AND v_phone !~ '^\+?[0-9]{7,15}$' THEN RAISE EXCEPTION 'Indica un teléfono válido.'; END IF;
 IF v_email<>'' AND (length(v_email)>254 OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') THEN RAISE EXCEPTION 'Indica un correo válido.'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_timezone_names WHERE name=tz) OR tz IS NULL THEN RAISE EXCEPTION 'Zona horaria no válida.'; END IF;
 IF coalesce(p_data->>'language','') NOT IN ('es','en') THEN RAISE EXCEPTION 'Idioma no válido.'; END IF;
 mode:=p_data->>'reservation_type'; provider:=coalesce(p_data->>'reservation_system','');
 IF mode IS NULL OR mode NOT IN ('manual','digital') THEN RAISE EXCEPTION 'Elige cómo gestionar las reservas.'; END IF;
 IF mode='digital' AND provider NOT IN ('covermanager','thefork','google_calendar','other') THEN RAISE EXCEPTION 'Elige tu programa de reservas.'; END IF;
 SELECT config INTO c FROM public.establishment_config WHERE establishment_id=e.id;
 IF (e.timezone IS DISTINCT FROM tz OR c->>'reservation_type' IS DISTINCT FROM mode OR (mode='digital' AND c->>'reservation_system' IS DISTINCT FROM provider)) AND EXISTS(SELECT 1 FROM public.reservations WHERE establishment_id=e.id AND status IN ('pending','confirmed') AND end_at>now()) THEN
  RAISE EXCEPTION 'Hay reservas aceptadas: el cambio de sistema o zona horaria requiere revisar su traslado.';
 END IF;
 UPDATE public.establishments SET name=btrim(p_data->>'name'),business_type=p_data->>'business_type',phone=v_phone,email=v_email,address=btrim(p_data->>'address'),city=btrim(p_data->>'city'),timezone=tz,language=p_data->>'language',settings_revision=settings_revision+1,updated_at=clock_timestamp() WHERE id=e.id RETURNING * INTO e;
 INSERT INTO public.establishment_config(establishment_id,config) VALUES(e.id,jsonb_build_object('reservation_type',mode,'reservation_system',CASE WHEN mode='digital' THEN provider ELSE '' END))
 ON CONFLICT(establishment_id) DO UPDATE SET config=public.establishment_config.config || excluded.config,updated_at=clock_timestamp();
 RETURN to_jsonb(e);
END; $$;
REVOKE ALL ON FUNCTION public.fgv_update_restaurant(uuid,jsonb,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fgv_update_restaurant(uuid,jsonb,integer) TO authenticated,service_role;
NOTIFY pgrst, 'reload schema';
COMMIT;
