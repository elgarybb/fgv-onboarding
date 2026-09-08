-- Add independent room layouts without changing table identities or accepted bookings.
BEGIN;
UPDATE public.product_plans SET features=features||'{"multiple_rooms":true}'::jsonb WHERE key='pilot';
CREATE TABLE public.restaurant_rooms (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 establishment_id uuid NOT NULL REFERENCES public.establishments(id),
 name text NOT NULL CHECK(length(btrim(name)) BETWEEN 1 AND 80),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(establishment_id,id)
);
CREATE UNIQUE INDEX restaurant_rooms_unique_name ON public.restaurant_rooms(establishment_id,lower(btrim(name)));
ALTER TABLE public.restaurant_rooms ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.restaurant_rooms FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.restaurant_rooms TO authenticated;
GRANT ALL ON public.restaurant_rooms TO service_role;
CREATE POLICY room_read ON public.restaurant_rooms FOR SELECT TO authenticated USING(public.fgv_can_access(establishment_id));
ALTER TABLE public.floor_plan_items ADD COLUMN room_id uuid;
ALTER TABLE public.floor_plan_items ADD FOREIGN KEY(establishment_id,room_id) REFERENCES public.restaurant_rooms(establishment_id,id);
CREATE OR REPLACE FUNCTION public.fgv_get_floor_plan(p_establishment_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 RETURN jsonb_build_object('revision',coalesce((SELECT revision FROM public.floor_plans WHERE establishment_id=p_establishment_id),0),
 'rooms',jsonb_build_array(jsonb_build_object('id',NULL,'name','Sala principal')) || coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'name',name) ORDER BY created_at,id) FROM public.restaurant_rooms WHERE establishment_id=p_establishment_id),'[]'::jsonb),
 'items',coalesce((SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object('table_id',table_id,'x',x,'y',y,'shape',shape,'room_id',room_id)) ORDER BY table_id) FROM public.floor_plan_items WHERE establishment_id=p_establishment_id),'[]'::jsonb));
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
  IF item->>'room_id' IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.restaurant_rooms WHERE establishment_id=p_establishment_id AND id=(item->>'room_id')::uuid) THEN RAISE EXCEPTION 'La sala no pertenece a este restaurante.' USING ERRCODE='42501'; END IF;
  INSERT INTO public.floor_plan_items(establishment_id,table_id,x,y,shape,room_id)
  VALUES(p_establishment_id,(item->>'table_id')::uuid,(item->>'x')::numeric,(item->>'y')::numeric,item->>'shape',(item->>'room_id')::uuid)
  ON CONFLICT(establishment_id,table_id) DO UPDATE SET x=excluded.x,y=excluded.y,shape=excluded.shape,room_id=CASE WHEN item ? 'room_id' THEN excluded.room_id ELSE public.floor_plan_items.room_id END;
 END LOOP;
 UPDATE public.floor_plans SET revision=revision+1,updated_at=clock_timestamp() WHERE establishment_id=p_establishment_id;
 RETURN public.fgv_get_floor_plan(p_establishment_id);
END; $$;
CREATE OR REPLACE FUNCTION public.fgv_save_room(p_establishment_id uuid,p_room_id uuid,p_name text,p_revision integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r integer; clean_name text:=btrim(p_name);
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 PERFORM 1 FROM public.establishments WHERE id=p_establishment_id FOR UPDATE;
 IF NOT coalesce((public.fgv_get_features(p_establishment_id)->>'multiple_rooms')::boolean,false) THEN RAISE EXCEPTION 'La edición de salas no está habilitada para este restaurante.' USING ERRCODE='42501'; END IF;
 SELECT revision INTO r FROM public.floor_plans WHERE establishment_id=p_establishment_id;
 IF coalesce(r,0) IS DISTINCT FROM p_revision THEN RAISE EXCEPTION 'La sala ha cambiado en otro dispositivo. Recarga antes de editar.' USING ERRCODE='40001'; END IF;
 IF clean_name IS NULL OR length(clean_name) NOT BETWEEN 1 AND 80 THEN RAISE EXCEPTION 'Indica un nombre de sala de entre 1 y 80 caracteres.'; END IF;
 IF lower(clean_name)='sala principal' OR EXISTS(SELECT 1 FROM public.restaurant_rooms WHERE establishment_id=p_establishment_id AND lower(name)=lower(clean_name) AND id IS DISTINCT FROM p_room_id) THEN RAISE EXCEPTION 'Ya existe una sala con ese nombre.'; END IF;
 IF p_room_id IS NOT NULL THEN
  IF NOT EXISTS(SELECT 1 FROM public.restaurant_rooms WHERE establishment_id=p_establishment_id AND id=p_room_id) THEN RAISE EXCEPTION 'La sala no pertenece a este restaurante.' USING ERRCODE='42501'; END IF;
  UPDATE public.restaurant_rooms SET name=clean_name WHERE establishment_id=p_establishment_id AND id=p_room_id;
 ELSE
  INSERT INTO public.restaurant_rooms(establishment_id,name) VALUES(p_establishment_id,clean_name);
 END IF;
 INSERT INTO public.floor_plans(establishment_id) VALUES(p_establishment_id) ON CONFLICT DO NOTHING;
 UPDATE public.floor_plans SET revision=revision+1,updated_at=clock_timestamp() WHERE establishment_id=p_establishment_id;
 RETURN public.fgv_get_floor_plan(p_establishment_id);
END; $$;
REVOKE ALL ON FUNCTION public.fgv_save_room(uuid,uuid,text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fgv_save_room(uuid,uuid,text,integer) TO authenticated,service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
