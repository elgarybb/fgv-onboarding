-- FGV reservation engine. Apply together with the matching web release.
-- Existing rows are preserved. New bookings require explicit room configuration.
BEGIN;
CREATE SCHEMA IF NOT EXISTS fgv_private;
REVOKE ALL ON SCHEMA fgv_private FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fgv_can_access(p_establishment_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT auth.uid() IS NOT NULL AND (
 EXISTS (SELECT 1 FROM public.establishment_users WHERE user_id=auth.uid() AND establishment_id=p_establishment_id)
 OR EXISTS (SELECT 1 FROM public.profiles WHERE id=auth.uid() AND role='superadmin'));
$$;
CREATE OR REPLACE FUNCTION fgv_private.authorize(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF NOT coalesce(public.fgv_can_access(p_id),false) AND coalesce(auth.role(),'') <> 'service_role' THEN
  RAISE EXCEPTION 'No tienes acceso a este restaurante.' USING ERRCODE='42501';
 END IF;
END; $$;

CREATE TABLE public.restaurant_tables (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 establishment_id uuid NOT NULL REFERENCES public.establishments(id),
 name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
 capacity integer NOT NULL CHECK (capacity BETWEEN 1 AND 100),
 active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(establishment_id,name), UNIQUE(establishment_id,id)
);
CREATE TABLE public.reservation_settings (
 establishment_id uuid PRIMARY KEY REFERENCES public.establishments(id),
 total_capacity integer NOT NULL CHECK(total_capacity BETWEEN 1 AND 10000),
 max_people integer NOT NULL CHECK(max_people BETWEEN 1 AND 100),
 duration_minutes integer NOT NULL CHECK(duration_minutes BETWEEN 15 AND 720),
 min_notice_minutes integer NOT NULL CHECK(min_notice_minutes BETWEEN 0 AND 525600),
 max_advance_days integer NOT NULL CHECK(max_advance_days BETWEEN 0 AND 730),
 schedules jsonb NOT NULL CHECK(jsonb_typeof(schedules)='object'),
 updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.reservations ADD COLUMN table_id uuid,
 ADD COLUMN revision integer NOT NULL DEFAULT 1,
 ADD COLUMN request_key uuid,
 ADD COLUMN request_fingerprint text,
 ADD CONSTRAINT fgv_table_belongs_to_restaurant FOREIGN KEY(establishment_id,table_id)
 REFERENCES public.restaurant_tables(establishment_id,id);
CREATE UNIQUE INDEX fgv_booking_request ON public.reservations(establishment_id,request_key) WHERE request_key IS NOT NULL;
CREATE INDEX fgv_reservation_times ON public.reservations(establishment_id,start_at,end_at) WHERE status IN ('pending','confirmed');
CREATE INDEX fgv_customers_phone ON public.customers(establishment_id,phone);
ALTER TABLE public.restaurant_tables ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reservation_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY fgv_tables_read ON public.restaurant_tables FOR SELECT TO authenticated USING(public.fgv_can_access(establishment_id));
CREATE POLICY fgv_settings_read ON public.reservation_settings FOR SELECT TO authenticated USING(public.fgv_can_access(establishment_id));
GRANT SELECT ON public.restaurant_tables,public.reservation_settings TO authenticated;
REVOKE INSERT,UPDATE,DELETE ON public.restaurant_tables,public.reservation_settings,public.reservations,public.customers FROM anon,authenticated;

CREATE OR REPLACE FUNCTION public.fgv_save_settings(p_establishment_id uuid,p_settings jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE d text; s jsonb; part jsonb; a time; b time;
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
 -- Avoid invalidating accepted reservations when changing capacity.
 IF EXISTS (SELECT 1 FROM public.reservations WHERE establishment_id=p_establishment_id AND status IN ('pending','confirmed') AND end_at>now()) THEN
  RAISE EXCEPTION 'Hay reservas futuras. Revisa o cancela esas reservas antes de cambiar las reglas.';
 END IF;
 INSERT INTO public.reservation_settings VALUES(p_establishment_id,(p_settings->>'total_capacity')::int,(p_settings->>'max_people')::int,
 (p_settings->>'duration_minutes')::int,(p_settings->>'min_notice_minutes')::int,(p_settings->>'max_advance_days')::int,p_settings->'schedules',now())
 ON CONFLICT(establishment_id) DO UPDATE SET total_capacity=excluded.total_capacity,max_people=excluded.max_people,
 duration_minutes=excluded.duration_minutes,min_notice_minutes=excluded.min_notice_minutes,max_advance_days=excluded.max_advance_days,schedules=excluded.schedules,updated_at=now();
END; $$;

CREATE OR REPLACE FUNCTION public.fgv_save_table(p_establishment_id uuid,p_table_id uuid,p_name text,p_capacity integer,p_active boolean)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result uuid;
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 PERFORM 1 FROM public.establishments WHERE id=p_establishment_id FOR UPDATE;
 IF p_active IS NULL THEN RAISE EXCEPTION 'Indica si la mesa está activa.'; END IF;
 IF p_table_id IS NULL THEN
  INSERT INTO public.restaurant_tables(establishment_id,name,capacity,active) VALUES(p_establishment_id,btrim(p_name),p_capacity,p_active) RETURNING id INTO result;
 ELSE
  IF EXISTS(SELECT 1 FROM public.reservations WHERE table_id=p_table_id AND establishment_id=p_establishment_id AND status IN ('pending','confirmed') AND end_at>now() AND (NOT p_active OR party_size>p_capacity)) THEN
   RAISE EXCEPTION 'La mesa tiene reservas futuras que no encajan con este cambio.';
  END IF;
  UPDATE public.restaurant_tables SET name=btrim(p_name),capacity=p_capacity,active=p_active WHERE id=p_table_id AND establishment_id=p_establishment_id RETURNING id INTO result;
  IF result IS NULL THEN RAISE EXCEPTION 'Mesa inexistente.'; END IF;
 END IF;
 RETURN result;
END; $$;

CREATE OR REPLACE FUNCTION fgv_private.availability(p_id uuid,p_local timestamp,p_people integer,p_exclude uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE cfg public.reservation_settings; tz text; starts timestamptz; finishes timestamptz; day_date date; day_key text;
 part jsonb; day_cfg jsonb; opens timestamptz; closes timestamptz; close_date date; allowed boolean:=false; table_result uuid; table_name text; peak integer;
BEGIN
 SELECT timezone INTO tz FROM public.establishments WHERE id=p_id AND active=true;
 IF tz IS NULL THEN RAISE EXCEPTION 'El restaurante no está activo.'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.establishment_config WHERE establishment_id=p_id AND config->>'reservation_type'='manual') THEN
  RAISE EXCEPTION 'Este restaurante no utiliza el motor propio de FGV.';
 END IF;
 SELECT * INTO cfg FROM public.reservation_settings WHERE establishment_id=p_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Configura primero las reglas y mesas del restaurante.'; END IF;
 IF p_local IS NULL OR p_people IS NULL OR p_people<1 OR p_people>cfg.max_people OR p_people>cfg.total_capacity THEN RAISE EXCEPTION 'Número de personas o fecha no válidos.'; END IF;
 starts:=p_local AT TIME ZONE tz;
 -- Reject nonexistent local times during the spring clock change.
 IF starts AT TIME ZONE tz <> p_local THEN RAISE EXCEPTION 'Esta hora no existe por el cambio de horario.'; END IF;
 -- A repeated local time is ambiguous: require a different slot for this MVP.
 IF (starts-interval '1 hour') AT TIME ZONE tz=p_local OR (starts+interval '1 hour') AT TIME ZONE tz=p_local THEN RAISE EXCEPTION 'Esta hora se repite por el cambio de horario. Elige otra hora.'; END IF;
 finishes:=starts+make_interval(mins=>cfg.duration_minutes);
 IF starts<now()+make_interval(mins=>cfg.min_notice_minutes) THEN RETURN jsonb_build_object('available',false,'reason','No se cumple la antelación mínima.'); END IF;
 IF p_local::date>(now() AT TIME ZONE tz)::date+cfg.max_advance_days THEN RETURN jsonb_build_object('available',false,'reason','La fecha supera la antelación máxima.'); END IF;
 -- Include yesterday's evening service when a booking is after midnight.
 FOR day_date IN SELECT p_local::date UNION ALL SELECT p_local::date-1 LOOP
  day_key:=(ARRAY['sunday','monday','tuesday','wednesday','thursday','friday','saturday'])[extract(dow FROM day_date)::int+1];
  day_cfg:=cfg.schedules->day_key;
  IF coalesce((day_cfg->>'closed')::boolean,true) THEN CONTINUE; END IF;
  FOR part IN SELECT value FROM jsonb_array_elements(day_cfg->'services') LOOP
   close_date:=day_date+CASE WHEN (part->>'close')::time<(part->>'open')::time THEN 1 ELSE 0 END;
   opens:=(day_date+(part->>'open')::time) AT TIME ZONE tz;
   closes:=(close_date+(part->>'close')::time) AT TIME ZONE tz;
   IF starts>=opens AND finishes<=closes THEN allowed:=true; END IF;
  END LOOP;
 END LOOP;
 IF NOT allowed THEN RETURN jsonb_build_object('available',false,'reason','La reserva completa debe estar dentro de un turno de apertura.'); END IF;
 IF EXISTS(SELECT 1 FROM public.reservations WHERE establishment_id=p_id AND status IN ('pending','confirmed') AND id IS DISTINCT FROM p_exclude AND (start_at IS NULL OR end_at IS NULL OR party_size IS NULL OR end_at<=start_at OR party_size<1)) THEN
  RAISE EXCEPTION 'Hay reservas antiguas incompletas. Revísalas antes de aceptar nuevas reservas.';
 END IF;
 -- Peak simultaneous occupancy; adjacent reservations do not overlap.
 WITH events AS (
 SELECT greatest(start_at,starts) AS at,party_size AS delta FROM public.reservations WHERE establishment_id=p_id AND status IN ('pending','confirmed') AND id IS DISTINCT FROM p_exclude AND start_at<finishes AND end_at>starts
 UNION ALL
 SELECT least(end_at,finishes),-party_size FROM public.reservations WHERE establishment_id=p_id AND status IN ('pending','confirmed') AND id IS DISTINCT FROM p_exclude AND start_at<finishes AND end_at>starts
 ), grouped AS (SELECT at,sum(delta) AS delta FROM events GROUP BY at), running AS (SELECT sum(delta) OVER(ORDER BY at) AS occupied FROM grouped)
 SELECT coalesce(max(occupied),0) INTO peak FROM running;
 IF peak+p_people>cfg.total_capacity THEN RETURN jsonb_build_object('available',false,'reason','No queda aforo disponible para ese horario.'); END IF;
 IF EXISTS(SELECT 1 FROM public.reservations WHERE establishment_id=p_id AND status IN ('pending','confirmed') AND id IS DISTINCT FROM p_exclude AND table_id IS NULL AND start_at<finishes AND end_at>starts) THEN
  RETURN jsonb_build_object('available',false,'reason','Hay una reserva sin mesa asignada en ese horario. Modifícala para asignarle una mesa.');
 END IF;
 SELECT t.id,t.name INTO table_result,table_name FROM public.restaurant_tables t WHERE t.establishment_id=p_id AND t.active AND t.capacity>=p_people AND NOT EXISTS(
 SELECT 1 FROM public.reservations r WHERE r.establishment_id=p_id AND r.table_id=t.id AND r.status IN ('pending','confirmed') AND r.id IS DISTINCT FROM p_exclude AND r.start_at<finishes AND r.end_at>starts)
 ORDER BY t.capacity,t.name,t.id LIMIT 1;
 IF table_result IS NULL THEN RETURN jsonb_build_object('available',false,'reason','No queda una mesa adecuada para ese horario.'); END IF;
 RETURN jsonb_build_object('available',true,'table_id',table_result,'table_name',table_name,'start_at',starts,'end_at',finishes,'timezone',tz);
END; $$;

CREATE OR REPLACE FUNCTION public.fgv_check_availability(p_establishment_id uuid,p_local_start timestamp,p_people integer,p_exclude uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 RETURN fgv_private.availability(p_establishment_id,p_local_start,p_people,p_exclude);
END; $$;

CREATE OR REPLACE FUNCTION public.fgv_save_reservation(p_establishment_id uuid,p_local_start timestamp,p_people integer,p_name text,p_phone text,p_notes text,p_request_key uuid,p_reservation_id uuid DEFAULT NULL,p_revision integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE slot jsonb; result public.reservations; existing public.reservations; customer uuid; phone_clean text; fingerprint text;
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 PERFORM 1 FROM public.establishments WHERE id=p_establishment_id FOR UPDATE;
 IF length(btrim(coalesce(p_name,''))) NOT BETWEEN 1 AND 120 OR length(coalesce(p_notes,''))>2000 THEN RAISE EXCEPTION 'Indica un nombre válido y notas de hasta 2000 caracteres.'; END IF;
 phone_clean:=regexp_replace(coalesce(p_phone,''),'[\s().-]','','g');
 IF phone_clean !~ '^\+?[0-9]{7,15}$' THEN RAISE EXCEPTION 'Indica un teléfono válido (con prefijo internacional si procede).'; END IF;
 IF p_reservation_id IS NULL AND p_request_key IS NULL THEN RAISE EXCEPTION 'Falta el identificador de la solicitud.'; END IF;
 fingerprint:=md5(jsonb_build_array(p_local_start,p_people,btrim(p_name),phone_clean,coalesce(p_notes,''))::text);
 IF p_reservation_id IS NULL THEN
  SELECT * INTO existing FROM public.reservations WHERE establishment_id=p_establishment_id AND request_key=p_request_key;
  IF FOUND THEN
   IF existing.request_fingerprint IS DISTINCT FROM fingerprint THEN RAISE EXCEPTION 'La solicitud ya se utilizó con otros datos.'; END IF;
   RETURN to_jsonb(existing);
  END IF;
 ELSE
  SELECT * INTO existing FROM public.reservations WHERE id=p_reservation_id AND establishment_id=p_establishment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reserva inexistente.'; END IF;
  IF existing.revision IS DISTINCT FROM p_revision THEN RAISE EXCEPTION 'La reserva ha cambiado. Actualiza la lista antes de editarla.'; END IF;
  IF existing.status NOT IN ('pending','confirmed') THEN RAISE EXCEPTION 'Solo se pueden modificar reservas activas.'; END IF;
 END IF;
 slot:=fgv_private.availability(p_establishment_id,p_local_start,p_people,p_reservation_id);
 IF NOT (slot->>'available')::boolean THEN RAISE EXCEPTION '%',slot->>'reason'; END IF;
 SELECT id INTO customer FROM public.customers WHERE establishment_id=p_establishment_id AND phone=phone_clean ORDER BY created_at,id LIMIT 1;
 IF customer IS NULL THEN INSERT INTO public.customers(establishment_id,name,phone) VALUES(p_establishment_id,btrim(p_name),phone_clean) RETURNING id INTO customer; END IF;
 IF p_reservation_id IS NULL THEN
  INSERT INTO public.reservations(establishment_id,customer_id,reservation_type,start_at,end_at,party_size,status,table_id,request_key,request_fingerprint,metadata)
  VALUES(p_establishment_id,customer,'manual',(slot->>'start_at')::timestamptz,(slot->>'end_at')::timestamptz,p_people,'confirmed',(slot->>'table_id')::uuid,p_request_key,fingerprint,
   jsonb_build_object('guest_name',btrim(p_name),'guest_phone',phone_clean,'notes',coalesce(p_notes,''),'source','fgv_engine')) RETURNING * INTO result;
 ELSE
  UPDATE public.reservations SET customer_id=customer,start_at=(slot->>'start_at')::timestamptz,end_at=(slot->>'end_at')::timestamptz,party_size=p_people,
   table_id=(slot->>'table_id')::uuid,metadata=metadata||jsonb_build_object('guest_name',btrim(p_name),'guest_phone',phone_clean,'notes',coalesce(p_notes,'')),revision=revision+1,updated_at=clock_timestamp()
  WHERE id=p_reservation_id AND establishment_id=p_establishment_id RETURNING * INTO result;
 END IF;
 RETURN to_jsonb(result);
END; $$;

CREATE OR REPLACE FUNCTION public.fgv_cancel_reservation(p_establishment_id uuid,p_reservation_id uuid,p_revision integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.reservations;
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 PERFORM 1 FROM public.establishments WHERE id=p_establishment_id FOR UPDATE;
 SELECT * INTO r FROM public.reservations WHERE id=p_reservation_id AND establishment_id=p_establishment_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Reserva inexistente.'; END IF;
 IF r.status='cancelled' THEN RETURN; END IF;
 IF r.revision IS DISTINCT FROM p_revision THEN RAISE EXCEPTION 'La reserva ha cambiado. Actualiza la lista.'; END IF;
 IF r.status NOT IN ('pending','confirmed') THEN RAISE EXCEPTION 'Esta reserva ya está cerrada.'; END IF;
 UPDATE public.reservations SET status='cancelled',revision=revision+1,updated_at=clock_timestamp() WHERE id=r.id;
END; $$;

CREATE OR REPLACE FUNCTION public.fgv_list_reservations(p_establishment_id uuid,p_day date)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE tz text; result jsonb;
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 IF p_day IS NULL THEN RAISE EXCEPTION 'Selecciona un día.'; END IF;
 SELECT timezone INTO tz FROM public.establishments WHERE id=p_establishment_id;
 SELECT coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('table_name',t.name,'guest_name',c.name,'guest_phone',c.phone) ORDER BY r.start_at,r.id),'[]'::jsonb)
 INTO result FROM public.reservations r LEFT JOIN public.restaurant_tables t ON t.id=r.table_id AND t.establishment_id=r.establishment_id
 LEFT JOIN public.customers c ON c.id=r.customer_id AND c.establishment_id=r.establishment_id
 WHERE r.establishment_id=p_establishment_id AND r.start_at >= (p_day::timestamp AT TIME ZONE tz) AND r.start_at < ((p_day+1)::timestamp AT TIME ZONE tz);
 RETURN result;
END; $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA fgv_private FROM PUBLIC,anon,authenticated;
DO $$ DECLARE f record; BEGIN
 FOR f IN SELECT oid::regprocedure AS signature FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname LIKE 'fgv_%' LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',f.signature);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated,service_role',f.signature);
 END LOOP;
END; $$;
COMMIT;
