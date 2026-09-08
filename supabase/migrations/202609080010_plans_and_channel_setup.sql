-- Draft commercial catalogue. Entitlement is separate from provider authorization and activation.
BEGIN;
UPDATE public.product_plans SET name='Básico',features='{"whatsapp_reservations":true,"reservation_engine":true,"integrations":true,"visual_floor_plan":false}' WHERE key='starter';
UPDATE public.product_plans SET name='Pro',features='{"whatsapp_reservations":true,"reservation_engine":true,"integrations":true,"visual_floor_plan":true,"multiple_rooms":true,"floor_designer":true,"table_combinations":true,"voice_messages":true}' WHERE key='pro';
UPDATE public.product_plans SET name='Business',features='{"whatsapp_reservations":true,"reservation_engine":true,"integrations":true,"visual_floor_plan":true,"multiple_rooms":true,"floor_designer":true,"table_combinations":true,"voice_messages":true,"voice_agent":true,"multi_location":true}' WHERE key='business';
UPDATE public.product_plans SET features=features||'{"whatsapp_reservations":true,"voice_messages":true,"voice_agent":true,"reservation_engine":true,"integrations":true}'::jsonb WHERE key='pilot';
CREATE OR REPLACE FUNCTION public.fgv_get_commercial_setup(p_establishment_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 RETURN jsonb_build_object('catalog',coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY CASE key WHEN 'starter' THEN 1 WHEN 'pro' THEN 2 ELSE 3 END) FROM public.product_plans p WHERE key<>'pilot'),'[]'::jsonb),'plan',(SELECT p.name FROM public.establishment_subscriptions s JOIN public.product_plans p ON p.key=s.plan_key WHERE s.establishment_id=p_establishment_id),'features',public.fgv_get_features(p_establishment_id),'channels',coalesce((SELECT config->'channel_setup' FROM public.establishment_config WHERE establishment_id=p_establishment_id),'{}'::jsonb));
END; $$;
CREATE OR REPLACE FUNCTION public.fgv_request_channel_setup(p_establishment_id uuid,p_channel text,p_phone text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE clean text:=regexp_replace(coalesce(p_phone,''),'[\s().-]','','g'); entry jsonb; feature text;
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 PERFORM 1 FROM public.establishments WHERE id=p_establishment_id FOR UPDATE;
 IF p_channel IS NULL OR p_channel NOT IN ('whatsapp','voice') THEN RAISE EXCEPTION 'Elige WhatsApp o llamadas.'; END IF;
 feature:=CASE WHEN p_channel='whatsapp' THEN 'whatsapp_reservations' ELSE 'voice_agent' END;
 IF NOT coalesce((public.fgv_get_features(p_establishment_id)->>feature)::boolean,false) THEN RAISE EXCEPTION 'Este canal no está incluido en tu plan.' USING ERRCODE='42501'; END IF;
 IF clean !~ '^\+[1-9][0-9]{6,14}$' THEN RAISE EXCEPTION 'Indica el número con prefijo internacional, por ejemplo +34.'; END IF;
 entry:=jsonb_build_object('phone',clean,'status','pending_authorization','updated_at',clock_timestamp());
 UPDATE public.establishment_config SET config=jsonb_set(config,'{channel_setup}',coalesce(config->'channel_setup','{}')||jsonb_build_object(p_channel,entry)),updated_at=clock_timestamp() WHERE establishment_id=p_establishment_id;
 RETURN entry;
END; $$;
REVOKE ALL ON FUNCTION public.fgv_get_commercial_setup(uuid),public.fgv_request_channel_setup(uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fgv_get_commercial_setup(uuid),public.fgv_request_channel_setup(uuid,text,text) TO authenticated,service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
