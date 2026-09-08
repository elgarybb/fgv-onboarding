-- Remove public reads and self-service membership claims; preserve existing rows.
BEGIN;
ALTER TABLE public.establishments ADD COLUMN created_by uuid REFERENCES public.profiles(id), ADD COLUMN onboarding_key uuid;
CREATE UNIQUE INDEX fgv_onboarding_request ON public.establishments(created_by,onboarding_key) WHERE onboarding_key IS NOT NULL;

CREATE OR REPLACE FUNCTION public.fgv_complete_onboarding(p_data jsonb,p_request_key uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE e public.establishments; v_user uuid:=auth.uid(); v_tz text;
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
 INSERT INTO public.establishments(name,business_type,phone,email,address,timezone,language,city,status,active,created_by,onboarding_key)
 VALUES(btrim(p_data->'establishment'->>'name'),coalesce(p_data->'establishment'->>'business_type','restaurant'),p_data->'establishment'->>'phone',p_data->'establishment'->>'email',
 p_data->'establishment'->>'address',v_tz,coalesce(p_data->'establishment'->>'language','es'),p_data->'config'->>'city','active',true,v_user,p_request_key) RETURNING * INTO e;
 INSERT INTO public.establishment_users(establishment_id,user_id,role) VALUES(e.id,v_user,'owner');
 INSERT INTO public.establishment_config(establishment_id,config) VALUES(e.id,p_data->'config');
 INSERT INTO public.business_rules(establishment_id,name,rule_type,rule,active) VALUES(e.id,'Reglas iniciales','general',p_data->'business_rules',true);
 RETURN to_jsonb(e);
END; $$;
REVOKE ALL ON FUNCTION public.fgv_complete_onboarding(jsonb,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fgv_complete_onboarding(jsonb,uuid) TO authenticated;

ALTER TABLE public.establishments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow public read establishments" ON public.establishments;
DROP POLICY IF EXISTS allow_onboarding_insert_establishments ON public.establishments;
DROP POLICY IF EXISTS "Allow public insert on establishment_config" ON public.establishment_config;
DROP POLICY IF EXISTS "Allow public read establishment config" ON public.establishment_config;
DROP POLICY IF EXISTS users_can_insert_own_establishment_membership ON public.establishment_users;
REVOKE INSERT,UPDATE,DELETE ON public.establishments,public.establishment_users,public.establishment_config,public.business_rules,public.profiles FROM anon,authenticated;
REVOKE ALL ON public.establishments,public.establishment_config FROM anon;
CREATE POLICY fgv_establishments_read ON public.establishments FOR SELECT TO authenticated USING(public.fgv_can_access(id));
CREATE POLICY fgv_config_read ON public.establishment_config FOR SELECT TO authenticated USING(public.fgv_can_access(establishment_id));
CREATE POLICY fgv_rules_read ON public.business_rules FOR SELECT TO authenticated USING(public.fgv_can_access(establishment_id));
CREATE POLICY fgv_bookings_read ON public.reservations FOR SELECT TO authenticated USING(public.fgv_can_access(establishment_id));
CREATE POLICY fgv_customers_read ON public.customers FOR SELECT TO authenticated USING(public.fgv_can_access(establishment_id));

-- Legacy CORE helpers bypass RLS and have no caller checks. Keep them server-only.
DO $$ DECLARE f record; BEGIN
 FOR f IN SELECT oid::regprocedure AS signature FROM pg_proc WHERE pronamespace='public'::regnamespace
 AND proname IN ('get_establishment','get_conversation','get_customer','get_reservations','get_business_rules','user_belongs_to_establishment','get_establishment_config','get_active_prompt','get_active_business_rules','get_active_services','get_active_integrations','get_messages','create_message','create_conversation','get_conversation_with_messages','get_or_create_conversation','conversation_data','get_ai_context','get_or_create_customer','handle_new_user') LOOP
  EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC,anon,authenticated',f.signature);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',f.signature);
 END LOOP;
END; $$;
NOTIFY pgrst, 'reload schema';
COMMIT;
