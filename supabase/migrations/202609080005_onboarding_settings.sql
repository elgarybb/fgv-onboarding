-- Complete onboarding supplies operational settings. Tables still require real capacities.
BEGIN;
CREATE OR REPLACE FUNCTION public.fgv_complete_onboarding(p_data jsonb,p_request_key uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE e public.establishments; v_user uuid:=auth.uid(); v_tz text; rules jsonb; engine jsonb; duration integer; advance integer;
BEGIN
 IF v_user IS NULL THEN RAISE EXCEPTION 'Inicia sesión para crear tu restaurante.' USING ERRCODE='42501'; END IF;
 IF p_request_key IS NULL THEN RAISE EXCEPTION 'Falta el identificador de la solicitud.'; END IF;
 -- Serialize retries for the same account, including the first request.
 PERFORM 1 FROM public.profiles WHERE id=v_user FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'No se encuentra tu perfil.'; END IF;
 SELECT * INTO e FROM public.establishments WHERE created_by=v_user AND onboarding_key=p_request_key;
 IF FOUND THEN RETURN to_jsonb(e); END IF;
 IF length(btrim(coalesce(p_data->'establishment'->>'name',''))) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'Indica el nombre del restaurante.'; END IF;
 IF coalesce(p_data->'config'->>'reservation_type','') NOT IN ('manual','digital') THEN RAISE EXCEPTION 'Selecciona el sistema de reservas.'; END IF;
 v_tz:=coalesce(p_data->'establishment'->>'timezone','Europe/Madrid');
 IF NOT EXISTS(SELECT 1 FROM pg_timezone_names WHERE name=v_tz) THEN RAISE EXCEPTION 'Zona horaria inválida.'; END IF;
 IF jsonb_typeof(p_data->'business_rules') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Configura las reglas de reservas.'; END IF;
 IF p_data->'config'->>'reservation_type'='digital' AND coalesce(p_data->'config'->>'reservation_system','') NOT IN ('covermanager','thefork','google_calendar','other') THEN RAISE EXCEPTION 'Elige el programa de reservas.'; END IF;
 INSERT INTO public.establishments(name,business_type,phone,email,address,timezone,language,city,status,active,created_by,onboarding_key)
 VALUES(btrim(p_data->'establishment'->>'name'),coalesce(p_data->'establishment'->>'business_type','restaurant'),p_data->'establishment'->>'phone',p_data->'establishment'->>'email',
 p_data->'establishment'->>'address',v_tz,coalesce(p_data->'establishment'->>'language','es'),p_data->'config'->>'city','active',true,v_user,p_request_key) RETURNING * INTO e;
 INSERT INTO public.establishment_users(establishment_id,user_id,role) VALUES(e.id,v_user,'owner');
 INSERT INTO public.establishment_config(establishment_id,config) VALUES(e.id,p_data->'config');
 INSERT INTO public.business_rules(establishment_id,name,rule_type,rule,active) VALUES(e.id,'Reglas iniciales','general',p_data->'business_rules',true);
 INSERT INTO public.establishment_subscriptions(establishment_id,plan_key) VALUES(e.id,'pilot');
 rules:=p_data->'business_rules';
 -- Translate complete onboarding rules into the same typed settings used by the booking engine.
 -- Legacy callers without complete rules still create an explicitly unconfigured restaurant.
 IF p_data->'config'->>'reservation_type'='manual' AND rules ? 'total_capacity' AND rules ? 'max_people' AND rules ? 'stay_duration' AND rules ? 'booking_advance' AND rules ? 'schedules' THEN
  duration:=CASE WHEN rules->>'stay_duration'='custom' THEN (rules->>'custom_duration')::integer ELSE (rules->>'stay_duration')::integer END;
  advance:=CASE rules->>'booking_advance' WHEN 'same_day' THEN 0 WHEN '1_day' THEN 1 WHEN '7_days' THEN 7 WHEN '30_days' THEN 30 WHEN 'custom' THEN (rules->>'custom_advance')::integer ELSE NULL END;
  engine:=jsonb_build_object('total_capacity',(rules->>'total_capacity')::integer,'max_people',(rules->>'max_people')::integer,'duration_minutes',duration,'min_notice_minutes',0,'max_advance_days',advance,'schedules',rules->'schedules');
  PERFORM public.fgv_save_settings(e.id,engine);
 END IF;
 RETURN to_jsonb(e);
END; $$;
REVOKE ALL ON FUNCTION public.fgv_complete_onboarding(jsonb,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fgv_complete_onboarding(jsonb,uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
