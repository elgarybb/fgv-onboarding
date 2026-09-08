-- User-authorized demonstration for Fernando Prueba only. Never use for a customer restaurant.
-- The transaction refuses existing reservations/layout and preserves a private snapshot.
BEGIN;
CREATE TABLE IF NOT EXISTS fgv_private.demo_backups(establishment_id uuid PRIMARY KEY,saved_at timestamptz DEFAULT now(),snapshot jsonb NOT NULL);
ALTER TABLE fgv_private.demo_backups ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON fgv_private.demo_backups FROM PUBLIC,anon,authenticated;
DO $$
DECLARE eid uuid:='6518ce17-8012-4338-9026-14d7e0853bcf'; e public.establishments; plan jsonb; cfg jsonb; table_ids uuid[]; room_terrace uuid; room_patio uuid; tid uuid; item jsonb; items jsonb:='[]'; objects jsonb:='[]'; rev integer; n integer; capacity integer; label text; room uuid; x integer; y integer; b jsonb; d date:=(now() AT TIME ZONE 'Europe/Madrid')::date; start_time timestamp; counter integer:=0; daykey text;
BEGIN
 SELECT * INTO e FROM public.establishments WHERE id=eid FOR UPDATE;
 IF e.name IS DISTINCT FROM 'Fernando Prueba' THEN RAISE EXCEPTION 'La demostración solo corresponde a Fernando Prueba.'; END IF;
 IF EXISTS(SELECT 1 FROM public.reservations WHERE establishment_id=eid) OR EXISTS(SELECT 1 FROM public.restaurant_rooms WHERE establishment_id=eid) OR EXISTS(SELECT 1 FROM public.floor_objects WHERE establishment_id=eid) OR EXISTS(SELECT 1 FROM public.table_groups WHERE establishment_id=eid) THEN RAISE EXCEPTION 'Hay reservas o un diseño previo. Revisar antes de preparar la demostración.'; END IF;
 IF (SELECT count(*) FROM public.restaurant_tables WHERE establishment_id=eid)<>15 THEN RAISE EXCEPTION 'La distribución inicial ha cambiado. Revisar antes de continuar.'; END IF;
 IF (now() AT TIME ZONE 'Europe/Madrid')::time>=time '19:00' THEN d:=d+1; END IF;
 INSERT INTO fgv_private.demo_backups(establishment_id,snapshot) VALUES(eid,jsonb_build_object('establishment',to_jsonb(e),'config',(SELECT to_jsonb(c) FROM public.establishment_config c WHERE establishment_id=eid),'settings',(SELECT to_jsonb(s) FROM public.reservation_settings s WHERE establishment_id=eid),'tables',(SELECT jsonb_agg(to_jsonb(t)) FROM public.restaurant_tables t WHERE establishment_id=eid),'floor',public.fgv_get_floor_plan(eid))) ON CONFLICT DO NOTHING;
 SELECT to_jsonb(s)-'establishment_id'-'updated_at' INTO cfg FROM public.reservation_settings s WHERE establishment_id=eid;
 daykey:=(ARRAY['sunday','monday','tuesday','wednesday','thursday','friday','saturday'])[extract(dow FROM d)::int+1];
 cfg:=cfg||jsonb_build_object('total_capacity',80,'max_people',8,'duration_minutes',120,'min_notice_minutes',0,'max_advance_days',7);
 cfg:=jsonb_set(cfg,ARRAY['schedules',daykey],'{"closed":false,"services":[{"open":"12:00","close":"00:00"}]}');
 PERFORM public.fgv_save_settings(eid,cfg);
 plan:=public.fgv_get_floor_plan(eid);
 plan:=public.fgv_save_room(eid,null,'Terraza',(plan->>'revision')::int);
 SELECT (value->>'id')::uuid INTO room_terrace FROM jsonb_array_elements(plan->'rooms') WHERE value->>'name'='Terraza';
 plan:=public.fgv_save_room(eid,null,'Patio',(plan->>'revision')::int);
 SELECT (value->>'id')::uuid INTO room_patio FROM jsonb_array_elements(plan->'rooms') WHERE value->>'name'='Patio';
 SELECT array_agg(id ORDER BY name,id) INTO table_ids FROM public.restaurant_tables WHERE establishment_id=eid;
 FOR n IN 1..15 LOOP PERFORM public.fgv_save_table(eid,table_ids[n],'DEMO temporal '||n,2,true); END LOOP;
 FOR n IN 1..18 LOOP
  IF n<=8 THEN room:=null;label:='I'||lpad(n::text,2,'0');capacity:=CASE WHEN n<=2 THEN 2 WHEN n<=6 THEN 4 ELSE 6 END;
   x:=CASE n WHEN 1 THEN 100 WHEN 2 THEN 330 WHEN 3 THEN 100 WHEN 4 THEN 330 WHEN 5 THEN 100 WHEN 6 THEN 330 ELSE 565 END;
   y:=CASE n WHEN 1 THEN 130 WHEN 2 THEN 130 WHEN 3 THEN 310 WHEN 4 THEN 310 WHEN 5 THEN 500 WHEN 6 THEN 500 WHEN 7 THEN 150 ELSE 430 END;
  ELSIF n<=14 THEN room:=room_terrace;label:='T'||lpad((n-8)::text,2,'0');capacity:=CASE WHEN n<=10 THEN 2 WHEN n<=13 THEN 4 ELSE 6 END;
   x:=CASE n WHEN 9 THEN 120 WHEN 10 THEN 380 WHEN 11 THEN 120 WHEN 12 THEN 380 ELSE 690 END;y:=CASE WHEN n IN(9,10,14) THEN 170 ELSE 420 END;
  ELSE room:=room_patio;label:='P'||lpad((n-14)::text,2,'0');capacity:=CASE n WHEN 15 THEN 4 WHEN 16 THEN 6 ELSE 8 END;x:=CASE WHEN n IN(15,17) THEN 170 ELSE 580 END;y:=CASE WHEN n<=16 THEN 180 ELSE 430 END;
  END IF;
  tid:=public.fgv_save_table(eid,CASE WHEN n<=15 THEN table_ids[n] ELSE null END,label,capacity,true);
  items:=items||jsonb_build_array(jsonb_build_object('table_id',tid,'room_id',room,'x',x,'y',y,'shape',CASE WHEN capacity=2 THEN 'round' WHEN capacity=4 THEN 'square' ELSE 'rectangle' END));
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(jsonb_build_array(
  jsonb_build_object('room_id',null,'kind','wall','label','Muro norte','x',35,'y',70,'width',900,'height',12),
  jsonb_build_object('room_id',null,'kind','wall','label','Muro oeste','x',35,'y',70,'width',12,'height',580),
  jsonb_build_object('room_id',null,'kind','wall','label','Muro este','x',948,'y',70,'width',12,'height',580),
  jsonb_build_object('room_id',null,'kind','wall','label','Separación barra','x',765,'y',70,'width',12,'height',365),
  jsonb_build_object('room_id',null,'kind','bar','label','BARRA','x',815,'y',160,'width',95,'height',340),
  jsonb_build_object('room_id',null,'kind','label','label','INTERIOR · SALA PRINCIPAL','x',100,'y',22,'width',500,'height',30),
  jsonb_build_object('room_id',null,'kind','label','label','ENTRADA ↑','x',380,'y',652,'width',220,'height',32),
  jsonb_build_object('room_id',null,'kind','label','label','PASO A TERRAZA →','x',700,'y',590,'width',245,'height',35),
  jsonb_build_object('room_id',room_terrace,'kind','bar','label','JARDINERA','x',60,'y',65,'width',860,'height',40),
  jsonb_build_object('room_id',room_terrace,'kind','wall','label','Separación lateral','x',50,'y',65,'width',12,'height',535),
  jsonb_build_object('room_id',room_terrace,'kind','label','label','TERRAZA · AIRE LIBRE','x',180,'y',25,'width',500,'height',30),
  jsonb_build_object('room_id',room_terrace,'kind','label','label','← INTERIOR     PASO A PATIO →','x',230,'y',620,'width',600,'height',40),
  jsonb_build_object('room_id',room_patio,'kind','wall','label','Muro patio','x',65,'y',70,'width',870,'height',12),
  jsonb_build_object('room_id',room_patio,'kind','wall','label','Muro lateral','x',65,'y',70,'width',12,'height',535),
  jsonb_build_object('room_id',room_patio,'kind','label','label','PATIO · ZONA TRANQUILA','x',150,'y',25,'width',650,'height',30),
  jsonb_build_object('room_id',room_patio,'kind','bar','label','JARDÍN','x',860,'y',130,'width',60,'height',425),
  jsonb_build_object('room_id',room_patio,'kind','label','label','← TERRAZA','x',300,'y',635,'width',300,'height',35)
 )) LOOP objects:=objects||jsonb_build_array(item||jsonb_build_object('id',gen_random_uuid())); END LOOP;
 PERFORM public.fgv_save_room_layout(eid,(plan->>'revision')::int,items,objects);
 -- Four two-seat tables; the first one becomes free at 21:30. Other occupied tables free at 22:00.
 FOR n IN 1..17 LOOP
  capacity:=CASE WHEN n<=4 THEN 2 WHEN n<=12 THEN 4 WHEN n<=15 THEN 6 ELSE 8 END;
  start_time:=d+CASE WHEN n=1 THEN time '19:30' ELSE time '20:00' END;
  b:=public.fgv_save_reservation(eid,start_time,capacity,'DEMO · Grupo '||lpad(n::text,2,'0'),'+34000000'||lpad(n::text,3,'0'),'RESERVA FICTICIA · Escenario de demostración. No contactar.',gen_random_uuid());
  UPDATE public.reservations SET metadata=metadata||'{"demo":true,"demo_scenario":"busy_evening_20260908"}' WHERE id=(b->>'id')::uuid;
 END LOOP;
 UPDATE public.establishment_config SET config=config||jsonb_build_object('demo_scenario',jsonb_build_object('date',d,'name','Noche con alta ocupación','requested_time','21:00','alternative_time','21:30')),updated_at=clock_timestamp() WHERE establishment_id=eid;
 b:=public.fgv_reservation_options(eid,d+time '21:00',2);
 IF (b->'requested'->>'table_capacity')::int<>6 OR (b->'alternatives'->0->>'table_capacity')::int<>2 OR (b->'alternatives'->0->>'wait_minutes')::int<>30 THEN RAISE EXCEPTION 'El escenario no produce la alternativa esperada: %',b; END IF;
END $$;
SELECT 'Demostración creada: 3 salas, 18 mesas, 80 plazas y 17 reservas ficticias. A las 21:00 queda una mesa de 6; a las 21:30, una de 2.' AS resultado;
COMMIT;
