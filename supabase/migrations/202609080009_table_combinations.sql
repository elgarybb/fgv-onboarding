-- Explicit combinations reserve every physical table; adjacency alone never changes capacity.
BEGIN;
UPDATE public.product_plans SET features=features||'{"table_combinations":true}'::jsonb WHERE key='pilot';
ALTER TABLE public.reservations ADD COLUMN allocated_table_ids uuid[] NOT NULL DEFAULT '{}';
UPDATE public.reservations SET allocated_table_ids=ARRAY[table_id] WHERE table_id IS NOT NULL;
CREATE INDEX reservation_allocated_tables ON public.reservations USING gin(allocated_table_ids) WHERE status IN ('pending','confirmed');
CREATE TABLE public.table_groups (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 establishment_id uuid NOT NULL REFERENCES public.establishments(id),
 table_ids uuid[] NOT NULL CHECK(cardinality(table_ids) BETWEEN 2 AND 50),
 capacity integer NOT NULL CHECK(capacity BETWEEN 1 AND 100)
);
ALTER TABLE public.table_groups ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.table_groups FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.table_groups TO authenticated;
GRANT ALL ON public.table_groups TO service_role;
CREATE POLICY group_read ON public.table_groups FOR SELECT TO authenticated USING(public.fgv_can_access(establishment_id));
CREATE OR REPLACE FUNCTION fgv_private.availability(p_id uuid,p_local timestamp,p_people integer,p_exclude uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE cfg public.reservation_settings; tz text; starts timestamptz; finishes timestamptz; day_date date; day_key text;
 part jsonb; day_cfg jsonb; opens timestamptz; closes timestamptz; close_date date; allowed boolean:=false; table_result uuid; table_name text; peak integer; chosen_tables uuid[];
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
 WITH candidates AS (
  SELECT ARRAY[t.id] AS ids,t.capacity,t.name AS label FROM public.restaurant_tables t WHERE t.establishment_id=p_id AND t.active AND t.capacity>=p_people
  UNION ALL
  SELECT g.table_ids,g.capacity,(SELECT string_agg(t.name,' + ' ORDER BY t.name,t.id) FROM public.restaurant_tables t WHERE t.establishment_id=p_id AND t.id=ANY(g.table_ids))
  FROM public.table_groups g WHERE g.establishment_id=p_id AND g.capacity>=p_people
  AND NOT EXISTS(SELECT 1 FROM public.restaurant_tables t WHERE t.establishment_id=p_id AND t.id=ANY(g.table_ids) AND NOT t.active)
 ), free AS (
 SELECT * FROM candidates c WHERE NOT EXISTS(
 SELECT 1 FROM public.reservations r WHERE r.establishment_id=p_id AND r.status IN ('pending','confirmed') AND r.id IS DISTINCT FROM p_exclude AND r.start_at<finishes AND r.end_at>starts AND (r.allocated_table_ids&&c.ids OR r.table_id=ANY(c.ids)))
 ) SELECT f.ids,f.ids[1],f.label INTO chosen_tables,table_result,table_name FROM free f ORDER BY f.capacity,cardinality(f.ids),f.label,f.ids LIMIT 1;
 IF table_result IS NULL THEN RETURN jsonb_build_object('available',false,'reason','No queda una mesa adecuada para ese horario.'); END IF;
 RETURN jsonb_build_object('available',true,'table_id',table_result,'table_ids',chosen_tables,'table_name',table_name,'start_at',starts,'end_at',finishes,'timezone',tz);
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
  INSERT INTO public.reservations(establishment_id,customer_id,reservation_type,start_at,end_at,party_size,status,table_id,request_key,request_fingerprint,allocated_table_ids,metadata)
  VALUES(p_establishment_id,customer,'manual',(slot->>'start_at')::timestamptz,(slot->>'end_at')::timestamptz,p_people,'confirmed',(slot->>'table_id')::uuid,p_request_key,fingerprint,ARRAY(SELECT value::uuid FROM jsonb_array_elements_text(slot->'table_ids')),
   jsonb_build_object('guest_name',btrim(p_name),'guest_phone',phone_clean,'notes',coalesce(p_notes,''),'source','fgv_engine')) RETURNING * INTO result;
 ELSE
  UPDATE public.reservations SET customer_id=customer,start_at=(slot->>'start_at')::timestamptz,end_at=(slot->>'end_at')::timestamptz,party_size=p_people,
   table_id=(slot->>'table_id')::uuid,allocated_table_ids=ARRAY(SELECT value::uuid FROM jsonb_array_elements_text(slot->'table_ids')),metadata=metadata||jsonb_build_object('guest_name',btrim(p_name),'guest_phone',phone_clean,'notes',coalesce(p_notes,'')),revision=revision+1,updated_at=clock_timestamp()
  WHERE id=p_reservation_id AND establishment_id=p_establishment_id RETURNING * INTO result;
 END IF;
 RETURN to_jsonb(result);
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
  IF EXISTS(SELECT 1 FROM public.reservations r WHERE (r.table_id=p_table_id OR p_table_id=ANY(r.allocated_table_ids)) AND r.establishment_id=p_establishment_id AND r.status IN ('pending','confirmed') AND r.end_at>now() AND (NOT p_active OR r.party_size>coalesce((SELECT sum(CASE WHEN t.id=p_table_id THEN p_capacity ELSE t.capacity END) FROM public.restaurant_tables t WHERE t.establishment_id=p_establishment_id AND t.id=ANY(CASE WHEN cardinality(r.allocated_table_ids)>0 THEN r.allocated_table_ids ELSE ARRAY[r.table_id] END)),0))) THEN
   RAISE EXCEPTION 'La mesa tiene reservas futuras que no encajan con este cambio.';
  END IF;
  UPDATE public.restaurant_tables SET name=btrim(p_name),capacity=p_capacity,active=p_active WHERE id=p_table_id AND establishment_id=p_establishment_id RETURNING id INTO result;
  IF result IS NULL THEN RAISE EXCEPTION 'Mesa inexistente.'; END IF;
 END IF;
 UPDATE public.table_groups g SET capacity=least(g.capacity,(SELECT sum(t.capacity)::integer FROM public.restaurant_tables t WHERE t.establishment_id=p_establishment_id AND t.id=ANY(g.table_ids))) WHERE g.establishment_id=p_establishment_id AND result=ANY(g.table_ids);
 RETURN result;
END; $$;

CREATE OR REPLACE FUNCTION public.fgv_list_reservations(p_establishment_id uuid,p_day date)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE tz text; result jsonb;
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 IF p_day IS NULL THEN RAISE EXCEPTION 'Selecciona un día.'; END IF;
 SELECT timezone INTO tz FROM public.establishments WHERE id=p_establishment_id;
 SELECT coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('table_name',coalesce((SELECT string_agg(t2.name,' + ' ORDER BY t2.name,t2.id) FROM public.restaurant_tables t2 WHERE t2.establishment_id=p_establishment_id AND t2.id=ANY(r.allocated_table_ids)),t.name),'guest_name',c.name,'guest_phone',c.phone) ORDER BY r.start_at,r.id),'[]'::jsonb)
 INTO result FROM public.reservations r LEFT JOIN public.restaurant_tables t ON t.id=r.table_id AND t.establishment_id=r.establishment_id
 LEFT JOIN public.customers c ON c.id=r.customer_id AND c.establishment_id=r.establishment_id
 WHERE r.establishment_id=p_establishment_id AND r.start_at >= (p_day::timestamp AT TIME ZONE tz) AND r.start_at < ((p_day+1)::timestamp AT TIME ZONE tz);
 RETURN result;
END; $$;

CREATE OR REPLACE FUNCTION public.fgv_get_floor_plan(p_establishment_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 RETURN jsonb_build_object('revision',coalesce((SELECT revision FROM public.floor_plans WHERE establishment_id=p_establishment_id),0),
 'groups',coalesce((SELECT jsonb_agg(to_jsonb(g)-'establishment_id' ORDER BY id) FROM public.table_groups g WHERE establishment_id=p_establishment_id),'[]'::jsonb),
 'objects',coalesce((SELECT jsonb_agg(to_jsonb(o)-'establishment_id' ORDER BY id) FROM public.floor_objects o WHERE establishment_id=p_establishment_id),'[]'::jsonb),
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
 IF EXISTS(SELECT 1 FROM public.table_groups g WHERE g.establishment_id=p_establishment_id AND (SELECT count(DISTINCT coalesce(f.room_id::text,'principal')) FROM unnest(g.table_ids) AS m(id) LEFT JOIN public.floor_plan_items f ON f.establishment_id=p_establishment_id AND f.table_id=m.id)>1) THEN RAISE EXCEPTION 'Descombina las mesas antes de trasladarlas a salas diferentes.'; END IF;
 UPDATE public.floor_plans SET revision=revision+1,updated_at=clock_timestamp() WHERE establishment_id=p_establishment_id;
 RETURN public.fgv_get_floor_plan(p_establishment_id);
END; $$;
CREATE OR REPLACE FUNCTION public.fgv_save_table_group(p_establishment_id uuid,p_revision integer,p_table_ids uuid[],p_capacity integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r integer; seats integer;
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 PERFORM 1 FROM public.establishments WHERE id=p_establishment_id FOR UPDATE;
 IF NOT coalesce((public.fgv_get_features(p_establishment_id)->>'table_combinations')::boolean,false) THEN RAISE EXCEPTION 'Las mesas combinadas no están incluidas en tu plan.' USING ERRCODE='42501'; END IF;
 SELECT revision INTO r FROM public.floor_plans WHERE establishment_id=p_establishment_id;
 IF coalesce(r,0) IS DISTINCT FROM p_revision THEN RAISE EXCEPTION 'El plano ha cambiado en otro dispositivo. Recarga antes de combinar mesas.' USING ERRCODE='40001'; END IF;
 IF p_table_ids IS NULL OR cardinality(p_table_ids) NOT BETWEEN 2 AND 50 OR cardinality(p_table_ids)<>(SELECT count(DISTINCT id) FROM unnest(p_table_ids) AS m(id)) THEN RAISE EXCEPTION 'Selecciona al menos dos mesas diferentes.'; END IF;
 IF cardinality(p_table_ids)<>(SELECT count(*) FROM public.restaurant_tables WHERE establishment_id=p_establishment_id AND active AND id=ANY(p_table_ids)) THEN RAISE EXCEPTION 'Las mesas deben estar activas y pertenecer al restaurante.' USING ERRCODE='42501'; END IF;
 IF (SELECT count(DISTINCT coalesce(f.room_id::text,'principal')) FROM unnest(p_table_ids) AS m(id) LEFT JOIN public.floor_plan_items f ON f.establishment_id=p_establishment_id AND f.table_id=m.id)>1 THEN RAISE EXCEPTION 'Las mesas combinadas deben estar en la misma sala.'; END IF;
 SELECT sum(capacity) INTO seats FROM public.restaurant_tables WHERE establishment_id=p_establishment_id AND id=ANY(p_table_ids);
 IF p_capacity IS NULL OR p_capacity NOT BETWEEN 1 AND least(seats,100) THEN RAISE EXCEPTION 'Las plazas conjuntas no pueden superar las plazas reales de las mesas.'; END IF;
 IF EXISTS(SELECT 1 FROM public.table_groups WHERE establishment_id=p_establishment_id AND table_ids&&p_table_ids AND NOT table_ids<@p_table_ids) THEN RAISE EXCEPTION 'Selecciona todas las mesas de la combinación anterior.'; END IF;
 DELETE FROM public.table_groups WHERE establishment_id=p_establishment_id AND table_ids&&p_table_ids;
 INSERT INTO public.table_groups(establishment_id,table_ids,capacity) VALUES(p_establishment_id,p_table_ids,p_capacity);
 INSERT INTO public.floor_plans(establishment_id) VALUES(p_establishment_id) ON CONFLICT DO NOTHING;
 UPDATE public.floor_plans SET revision=revision+1,updated_at=clock_timestamp() WHERE establishment_id=p_establishment_id;
 RETURN public.fgv_get_floor_plan(p_establishment_id);
END; $$;
CREATE OR REPLACE FUNCTION public.fgv_remove_table_group(p_establishment_id uuid,p_revision integer,p_group_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r integer;
BEGIN
 PERFORM fgv_private.authorize(p_establishment_id);
 PERFORM 1 FROM public.establishments WHERE id=p_establishment_id FOR UPDATE;
 IF NOT coalesce((public.fgv_get_features(p_establishment_id)->>'table_combinations')::boolean,false) THEN RAISE EXCEPTION 'Las mesas combinadas no están incluidas en tu plan.' USING ERRCODE='42501'; END IF;
 SELECT revision INTO r FROM public.floor_plans WHERE establishment_id=p_establishment_id;
 IF coalesce(r,0) IS DISTINCT FROM p_revision THEN RAISE EXCEPTION 'El plano ha cambiado. Recarga antes de descombinar.' USING ERRCODE='40001'; END IF;
 DELETE FROM public.table_groups WHERE establishment_id=p_establishment_id AND id=p_group_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Combinación inexistente.'; END IF;
 UPDATE public.floor_plans SET revision=revision+1,updated_at=clock_timestamp() WHERE establishment_id=p_establishment_id;
 RETURN public.fgv_get_floor_plan(p_establishment_id);
END; $$;
REVOKE ALL ON FUNCTION public.fgv_save_table_group(uuid,integer,uuid[],integer),public.fgv_remove_table_group(uuid,integer,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fgv_save_table_group(uuid,integer,uuid[],integer),public.fgv_remove_table_group(uuid,integer,uuid) TO authenticated,service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
