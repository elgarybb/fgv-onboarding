-- Layout is presentation data; table identity, capacity and bookings remain authoritative.
BEGIN;
CREATE TABLE public.product_plans (
 key text PRIMARY KEY, name text NOT NULL, features jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(features)='object')
);
CREATE TABLE public.establishment_subscriptions (
 establishment_id uuid PRIMARY KEY REFERENCES public.establishments(id),
 plan_key text NOT NULL REFERENCES public.product_plans(key),
 status text NOT NULL DEFAULT 'active' CHECK(status IN ('active','paused','cancelled')),
 updated_at timestamptz NOT NULL DEFAULT now()
);
-- Pilot access preserves current functionality. Commercial packages have no assigned prices or features yet.
INSERT INTO public.product_plans(key,name,features) VALUES
 ('pilot','Piloto','{"visual_floor_plan":true}'),('starter','Starter','{}'),('pro','Pro','{}'),('business','Business','{}');
INSERT INTO public.establishment_subscriptions(establishment_id,plan_key) SELECT id,'pilot' FROM public.establishments;
ALTER TABLE public.product_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.establishment_subscriptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.product_plans,public.establishment_subscriptions FROM anon,authenticated;
GRANT ALL ON public.product_plans,public.establishment_subscriptions TO service_role;
CREATE OR REPLACE FUNCTION public.fgv_get_features(p_establishment_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 SELECT CASE WHEN s.status='active' THEN p.features ELSE '{}'::jsonb END INTO result
 FROM public.establishment_subscriptions s JOIN public.product_plans p ON p.key=s.plan_key WHERE s.establishment_id=p_establishment_id;
 RETURN coalesce(result,'{}');
END; $$;
CREATE TABLE public.floor_plans (
 establishment_id uuid PRIMARY KEY REFERENCES public.establishments(id),
 revision integer NOT NULL DEFAULT 0,
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.floor_plan_items (
 establishment_id uuid NOT NULL REFERENCES public.floor_plans(establishment_id),
 table_id uuid NOT NULL,
 x numeric NOT NULL CHECK(x BETWEEN 0 AND 900),
 y numeric NOT NULL CHECK(y BETWEEN 0 AND 620),
 shape text NOT NULL CHECK(shape IN ('round','square','rectangle')),
 PRIMARY KEY(establishment_id,table_id),
 FOREIGN KEY(establishment_id,table_id) REFERENCES public.restaurant_tables(establishment_id,id)
);
ALTER TABLE public.floor_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.floor_plan_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.floor_plans,public.floor_plan_items FROM anon,authenticated;
GRANT SELECT ON public.floor_plans,public.floor_plan_items TO authenticated;
GRANT ALL ON public.floor_plans,public.floor_plan_items TO service_role;
CREATE POLICY floor_read ON public.floor_plans FOR SELECT TO authenticated USING(public.fgv_can_access(establishment_id));
CREATE POLICY floor_items_read ON public.floor_plan_items FOR SELECT TO authenticated USING(public.fgv_can_access(establishment_id));
CREATE OR REPLACE FUNCTION public.fgv_get_floor_plan(p_establishment_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 RETURN jsonb_build_object('revision',coalesce((SELECT revision FROM public.floor_plans WHERE establishment_id=p_establishment_id),0),
 'items',coalesce((SELECT jsonb_agg(jsonb_build_object('table_id',table_id,'x',x,'y',y,'shape',shape) ORDER BY table_id) FROM public.floor_plan_items WHERE establishment_id=p_establishment_id),'[]'::jsonb));
END; $$;
CREATE OR REPLACE FUNCTION public.fgv_save_floor_plan(p_establishment_id uuid,p_revision integer,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r integer; item jsonb;
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 PERFORM 1 FROM public.establishments WHERE id=p_establishment_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Restaurante inexistente.'; END IF;
 IF NOT coalesce((public.fgv_get_features(p_establishment_id)->>'visual_floor_plan')::boolean,false) THEN RAISE EXCEPTION 'La edición del plano no está habilitada para este restaurante.' USING ERRCODE='42501'; END IF;
 SELECT revision INTO r FROM public.floor_plans WHERE establishment_id=p_establishment_id;
 IF coalesce(r,0) IS DISTINCT FROM p_revision THEN RAISE EXCEPTION 'El plano ha cambiado en otro dispositivo. Recarga el plano antes de editar.' USING ERRCODE='40001'; END IF;
 IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Plano no válido.'; END IF;
 IF jsonb_array_length(p_items)>500 THEN RAISE EXCEPTION 'El plano admite hasta 500 mesas.'; END IF;
 IF (SELECT count(*) FROM jsonb_array_elements(p_items)) <> (SELECT count(DISTINCT value->>'table_id') FROM jsonb_array_elements(p_items)) THEN RAISE EXCEPTION 'Cada mesa debe aparecer una sola vez.'; END IF;
 INSERT INTO public.floor_plans(establishment_id) VALUES(p_establishment_id) ON CONFLICT DO NOTHING;
 FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
  IF NOT EXISTS(SELECT 1 FROM public.restaurant_tables WHERE establishment_id=p_establishment_id AND id=(item->>'table_id')::uuid) THEN RAISE EXCEPTION 'Una mesa no pertenece a este restaurante.' USING ERRCODE='42501'; END IF;
  INSERT INTO public.floor_plan_items(establishment_id,table_id,x,y,shape)
  VALUES(p_establishment_id,(item->>'table_id')::uuid,(item->>'x')::numeric,(item->>'y')::numeric,item->>'shape')
  ON CONFLICT(establishment_id,table_id) DO UPDATE SET x=excluded.x,y=excluded.y,shape=excluded.shape;
 END LOOP;
 UPDATE public.floor_plans SET revision=revision+1,updated_at=clock_timestamp() WHERE establishment_id=p_establishment_id;
 RETURN public.fgv_get_floor_plan(p_establishment_id);
END; $$;
REVOKE ALL ON FUNCTION public.fgv_get_features(uuid),public.fgv_get_floor_plan(uuid),public.fgv_save_floor_plan(uuid,integer,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fgv_get_features(uuid),public.fgv_get_floor_plan(uuid),public.fgv_save_floor_plan(uuid,integer,jsonb) TO authenticated,service_role;
NOTIFY pgrst, 'reload schema';
COMMIT;
