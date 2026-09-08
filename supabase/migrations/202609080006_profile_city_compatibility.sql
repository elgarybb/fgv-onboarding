-- Keep the legacy onboarding configuration aligned with the editable profile.
BEGIN;
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
 INSERT INTO public.establishment_config(establishment_id,config) VALUES(e.id,jsonb_build_object('city',e.city,'reservation_type',mode,'reservation_system',CASE WHEN mode='digital' THEN provider ELSE '' END))
 ON CONFLICT(establishment_id) DO UPDATE SET config=public.establishment_config.config || excluded.config,updated_at=clock_timestamp();
 RETURN to_jsonb(e);
END; $$;
REVOKE ALL ON FUNCTION public.fgv_update_restaurant(uuid,jsonb,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fgv_update_restaurant(uuid,jsonb,integer) TO authenticated,service_role;
NOTIFY pgrst, 'reload schema';
COMMIT;
