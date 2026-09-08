-- Commercial records and audit are administrator-only; they never alter reservations.
BEGIN;
CREATE TABLE public.admin_accounts (
 establishment_id uuid PRIMARY KEY REFERENCES public.establishments(id),
 stage text NOT NULL DEFAULT 'trial' CHECK(stage IN ('prospect','trial','contracted','paused','archived')),
 contact_name text NOT NULL DEFAULT '', contact_email text NOT NULL DEFAULT '', contact_phone text NOT NULL DEFAULT '',
 notes text NOT NULL DEFAULT '', next_follow_up date, revision integer NOT NULL DEFAULT 1,
 updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid
);
CREATE TABLE public.admin_account_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), establishment_id uuid NOT NULL REFERENCES public.establishments(id),
 actor_id uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), before_data jsonb NOT NULL, after_data jsonb NOT NULL
);
ALTER TABLE public.admin_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_account_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.admin_accounts,public.admin_account_events FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.admin_accounts,public.admin_account_events TO service_role;
CREATE FUNCTION fgv_private.authorize_admin() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND role='superadmin') THEN RAISE EXCEPTION 'Solo el administrador puede acceder a esta sección.' USING ERRCODE='42501'; END IF;
END; $$;
REVOKE ALL ON FUNCTION fgv_private.authorize_admin() FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.fgv_admin_overview() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM fgv_private.authorize_admin();
 RETURN jsonb_build_object('restaurants',coalesce((SELECT jsonb_agg(jsonb_build_object(
 'id',e.id,'name',e.name,'city',coalesce(nullif(e.city,''),c.config->>'city',''),'address',e.address,'email',e.email,'phone',e.phone,'active',e.active,'created_at',e.created_at,
 'stage',coalesce(a.stage,CASE WHEN s.plan_key='pilot' THEN 'trial' ELSE 'prospect' END),'revision',coalesce(a.revision,0),
 'contact_name',coalesce(a.contact_name,''),'contact_email',coalesce(a.contact_email,''),'contact_phone',coalesce(a.contact_phone,''),'notes',coalesce(a.notes,''),'next_follow_up',a.next_follow_up,
 'plan_key',s.plan_key,'plan_name',p.name,'subscription_status',s.status,
 'reservation_type',c.config->>'reservation_type','reservation_system',c.config->>'reservation_system',
 'has_settings',EXISTS(SELECT 1 FROM public.reservation_settings rs WHERE rs.establishment_id=e.id),
 'tables',(SELECT count(*) FROM public.restaurant_tables t WHERE t.establishment_id=e.id AND t.active),
 'whatsapp_status',coalesce(c.config->'channel_setup'->'whatsapp'->>'status','not_configured'),
 'voice_status',coalesce(c.config->'channel_setup'->'voice'->>'status','not_configured')
 ) ORDER BY e.created_at DESC,e.id) FROM public.establishments e LEFT JOIN public.establishment_config c ON c.establishment_id=e.id LEFT JOIN public.establishment_subscriptions s ON s.establishment_id=e.id LEFT JOIN public.product_plans p ON p.key=s.plan_key LEFT JOIN public.admin_accounts a ON a.establishment_id=e.id),'[]'::jsonb),
 'plans',coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY key) FROM public.product_plans p),'[]'::jsonb),
 'activity',coalesce((SELECT jsonb_agg(row_data ORDER BY created_at DESC) FROM (SELECT ev.created_at,jsonb_build_object('restaurant',e.name,'created_at',ev.created_at,'previous_stage',ev.before_data->>'stage','stage',ev.after_data->>'stage') row_data FROM public.admin_account_events ev JOIN public.establishments e ON e.id=ev.establishment_id ORDER BY ev.created_at DESC LIMIT 30) recent),'[]'::jsonb));
END; $$;
CREATE FUNCTION public.fgv_admin_save_account(p_establishment_id uuid,p_revision integer,p_account jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE old public.admin_accounts; saved public.admin_accounts; stage_value text:=p_account->>'stage';
BEGIN
 PERFORM fgv_private.authorize_admin();
 PERFORM 1 FROM public.establishments WHERE id=p_establishment_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Restaurante inexistente.'; END IF;
 SELECT * INTO old FROM public.admin_accounts WHERE establishment_id=p_establishment_id;
 IF coalesce(old.revision,0) IS DISTINCT FROM p_revision THEN RAISE EXCEPTION 'La ficha ha cambiado. Actualiza antes de guardar.' USING ERRCODE='40001'; END IF;
 IF stage_value IS NULL OR stage_value NOT IN ('prospect','trial','contracted','paused','archived') THEN RAISE EXCEPTION 'Selecciona una fase comercial válida.'; END IF;
 IF length(coalesce(p_account->>'contact_name',''))>120 OR length(coalesce(p_account->>'contact_email',''))>254 OR length(coalesce(p_account->>'contact_phone',''))>40 OR length(coalesce(p_account->>'notes',''))>4000 THEN RAISE EXCEPTION 'Los datos de contacto o las notas son demasiado largos.'; END IF;
 IF coalesce(p_account->>'contact_email','')<>'' AND p_account->>'contact_email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN RAISE EXCEPTION 'Revisa el correo de contacto.'; END IF;
 INSERT INTO public.admin_accounts(establishment_id,stage,contact_name,contact_email,contact_phone,notes,next_follow_up,revision,updated_by)
 VALUES(p_establishment_id,stage_value,btrim(coalesce(p_account->>'contact_name','')),btrim(coalesce(p_account->>'contact_email','')),btrim(coalesce(p_account->>'contact_phone','')),coalesce(p_account->>'notes',''),nullif(p_account->>'next_follow_up','')::date,coalesce(old.revision,0)+1,auth.uid())
 ON CONFLICT(establishment_id) DO UPDATE SET stage=excluded.stage,contact_name=excluded.contact_name,contact_email=excluded.contact_email,contact_phone=excluded.contact_phone,notes=excluded.notes,next_follow_up=excluded.next_follow_up,revision=excluded.revision,updated_at=clock_timestamp(),updated_by=excluded.updated_by RETURNING * INTO saved;
 INSERT INTO public.admin_account_events(establishment_id,actor_id,before_data,after_data) VALUES(p_establishment_id,auth.uid(),coalesce(to_jsonb(old),'{}'),to_jsonb(saved));
 RETURN to_jsonb(saved);
END; $$;
REVOKE ALL ON FUNCTION public.fgv_admin_overview(),public.fgv_admin_save_account(uuid,integer,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fgv_admin_overview(),public.fgv_admin_save_account(uuid,integer,jsonb) TO authenticated;
CREATE FUNCTION public.fgv_admin_create_restaurant(p_data jsonb,p_request_key uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb; eid uuid; existing public.establishments; selected_plan text:=coalesce(p_data->>'plan_key','pilot');
BEGIN
 PERFORM fgv_private.authorize_admin();
 PERFORM 1 FROM public.profiles WHERE id=auth.uid() FOR UPDATE;
 SELECT * INTO existing FROM public.establishments WHERE created_by=auth.uid() AND onboarding_key=p_request_key;
 IF FOUND THEN RETURN jsonb_build_object('id',existing.id,'name',existing.name); END IF;
 IF NOT EXISTS(SELECT 1 FROM public.product_plans WHERE key=selected_plan) THEN RAISE EXCEPTION 'Elige un plan válido.'; END IF;
 IF length(coalesce(p_data->>'city',''))>120 OR length(coalesce(p_data->>'phone',''))>40 THEN RAISE EXCEPTION 'Revisa la ciudad y el teléfono.'; END IF;
 e:=public.fgv_complete_onboarding(jsonb_build_object('establishment',jsonb_build_object('name',p_data->>'name','business_type','restaurant','phone',p_data->>'phone','email',p_data->>'email','timezone','Europe/Madrid','language','es'),'config',jsonb_build_object('city',coalesce(p_data->>'city',''),'reservation_type',p_data->>'reservation_type','reservation_system',p_data->>'reservation_system'),'business_rules','{}'::jsonb),p_request_key);
 eid:=(e->>'id')::uuid;
 -- A sales record grants no access to the contact email and sends no invitation.
 PERFORM public.fgv_admin_save_account(eid,0,jsonb_build_object('stage',coalesce(p_data->>'stage','trial'),'contact_name',coalesce(p_data->>'contact_name',''),'contact_email',coalesce(p_data->>'email',''),'contact_phone',coalesce(p_data->>'phone',''),'notes','Alta desde administración. Acceso del cliente pendiente de vincular.'));
 UPDATE public.establishment_subscriptions SET plan_key=selected_plan,updated_at=clock_timestamp() WHERE establishment_id=eid;
 RETURN jsonb_build_object('id',eid,'name',e->>'name');
END; $$;
REVOKE ALL ON FUNCTION public.fgv_admin_create_restaurant(jsonb,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fgv_admin_create_restaurant(jsonb,uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
