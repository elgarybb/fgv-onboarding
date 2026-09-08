-- Room architecture is visual data and does not consume seats or capacity.
BEGIN;
UPDATE public.product_plans SET features=features||'{"floor_designer":true}'::jsonb WHERE key='pilot';
CREATE TABLE public.floor_objects (
 id uuid PRIMARY KEY,
 establishment_id uuid NOT NULL REFERENCES public.establishments(id),
 room_id uuid,
 kind text NOT NULL CHECK(kind IN ('wall','bar','label')),
 label text NOT NULL DEFAULT '' CHECK(length(label)<=80),
 x numeric NOT NULL CHECK(x>=0), y numeric NOT NULL CHECK(y>=0),
 width numeric NOT NULL CHECK(width BETWEEN 10 AND 900), height numeric NOT NULL CHECK(height BETWEEN 10 AND 620),
 CHECK(x+width<=1000 AND y+height<=720),
 FOREIGN KEY(establishment_id,room_id) REFERENCES public.restaurant_rooms(establishment_id,id)
);
ALTER TABLE public.floor_objects ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.floor_objects FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.floor_objects TO authenticated;
GRANT ALL ON public.floor_objects TO service_role;
CREATE POLICY object_read ON public.floor_objects FOR SELECT TO authenticated USING(public.fgv_can_access(establishment_id));
CREATE OR REPLACE FUNCTION public.fgv_get_floor_plan(p_establishment_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 RETURN jsonb_build_object('revision',coalesce((SELECT revision FROM public.floor_plans WHERE establishment_id=p_establishment_id),0),
 'objects',coalesce((SELECT jsonb_agg(to_jsonb(o)-'establishment_id' ORDER BY id) FROM public.floor_objects o WHERE establishment_id=p_establishment_id),'[]'::jsonb),
 'rooms',jsonb_build_array(jsonb_build_object('id',NULL,'name','Sala principal')) || coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'name',name) ORDER BY created_at,id) FROM public.restaurant_rooms WHERE establishment_id=p_establishment_id),'[]'::jsonb),
 'items',coalesce((SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object('table_id',table_id,'x',x,'y',y,'shape',shape,'room_id',room_id)) ORDER BY table_id) FROM public.floor_plan_items WHERE establishment_id=p_establishment_id),'[]'::jsonb));
END; $$;
CREATE OR REPLACE FUNCTION public.fgv_save_room_layout(p_establishment_id uuid,p_revision integer,p_items jsonb,p_objects jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE item jsonb;
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 PERFORM 1 FROM public.establishments WHERE id=p_establishment_id FOR UPDATE;
 IF NOT coalesce((public.fgv_get_features(p_establishment_id)->>'floor_designer')::boolean,false) THEN RAISE EXCEPTION 'El editor avanzado no está incluido en tu plan.' USING ERRCODE='42501'; END IF;
 IF jsonb_typeof(p_objects) IS DISTINCT FROM 'array' OR jsonb_array_length(p_objects)>500 THEN RAISE EXCEPTION 'Elementos del plano no válidos.'; END IF;
 IF (SELECT count(*) FROM jsonb_array_elements(p_objects)) <> (SELECT count(DISTINCT value->>'id') FROM jsonb_array_elements(p_objects)) THEN RAISE EXCEPTION 'Cada elemento debe aparecer una sola vez.'; END IF;
 -- The existing version lock covers tables, rooms and architecture in the same transaction.
 PERFORM public.fgv_save_floor_plan(p_establishment_id,p_revision,p_items);
 FOR item IN SELECT value FROM jsonb_array_elements(p_objects) LOOP
  IF EXISTS(SELECT 1 FROM public.floor_objects WHERE id=(item->>'id')::uuid AND establishment_id<>p_establishment_id) THEN RAISE EXCEPTION 'El elemento no pertenece a este restaurante.' USING ERRCODE='42501'; END IF;
  IF item->>'room_id' IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.restaurant_rooms WHERE establishment_id=p_establishment_id AND id=(item->>'room_id')::uuid) THEN RAISE EXCEPTION 'La sala no pertenece a este restaurante.' USING ERRCODE='42501'; END IF;
  INSERT INTO public.floor_objects(id,establishment_id,room_id,kind,label,x,y,width,height)
  VALUES((item->>'id')::uuid,p_establishment_id,(item->>'room_id')::uuid,item->>'kind',coalesce(item->>'label',''),(item->>'x')::numeric,(item->>'y')::numeric,(item->>'width')::numeric,(item->>'height')::numeric)
  ON CONFLICT(id) DO UPDATE SET room_id=excluded.room_id,kind=excluded.kind,label=excluded.label,x=excluded.x,y=excluded.y,width=excluded.width,height=excluded.height;
 END LOOP;
 DELETE FROM public.floor_objects WHERE establishment_id=p_establishment_id AND id NOT IN (SELECT (value->>'id')::uuid FROM jsonb_array_elements(p_objects));
 RETURN public.fgv_get_floor_plan(p_establishment_id);
END; $$;
REVOKE ALL ON FUNCTION public.fgv_save_room_layout(uuid,integer,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fgv_save_room_layout(uuid,integer,jsonb,jsonb) TO authenticated,service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
