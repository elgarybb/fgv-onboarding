-- Run through the Supabase SQL Editor as postgres. All fixture changes roll back.
BEGIN;


INSERT INTO public.establishments(id,name,business_type,timezone,active,status) VALUES('ffffeeee-dddd-4ccc-8bbb-aaaaaaaaaaaa','FGV prueba aislada ajena','restaurant','Europe/Madrid',true,'active');
SET LOCAL request.jwt.claim.sub='REPLACE_WITH_EXISTING_OWNER_UUID';
SET LOCAL request.jwt.claim.role='authenticated';
SET LOCAL ROLE authenticated;
DO $$
DECLARE e jsonb; e2 jsonb; b jsonb; retry jsonb; slot jsonb; settings jsonb; eid uuid; rid uuid; k uuid:=gen_random_uuid(); bk uuid:=gen_random_uuid(); start_local timestamp:=((now() AT TIME ZONE 'Europe/Madrid')::date+1)+time '13:00';
BEGIN
 e:=public.fgv_complete_onboarding('{"establishment":{"name":"FGV prueba temporal","timezone":"Europe/Madrid"},"config":{"reservation_type":"manual"},"business_rules":{}}'::jsonb,k);
 eid:=(e->>'id')::uuid;
 e2:=public.fgv_complete_onboarding('{"establishment":{"name":"FGV prueba temporal","timezone":"Europe/Madrid"},"config":{"reservation_type":"manual"},"business_rules":{}}'::jsonb,k);
 IF e2->>'id' IS DISTINCT FROM e->>'id' THEN RAISE EXCEPTION 'Onboarding duplicado'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.establishments WHERE id=eid) THEN RAISE EXCEPTION 'No puede leer su restaurante'; END IF;

 SELECT jsonb_build_object('total_capacity',2,'max_people',2,'duration_minutes',90,'min_notice_minutes',0,'max_advance_days',7,'schedules',jsonb_object_agg(d,jsonb_build_object('closed',false,'services',jsonb_build_array(jsonb_build_object('open','12:00','close','23:00'))))) INTO settings FROM unnest(ARRAY['monday','tuesday','wednesday','thursday','friday','saturday','sunday']) d;
 PERFORM public.fgv_save_settings(eid,settings);
 PERFORM public.fgv_save_table(eid,null,'Mesa temporal',2,true);
 slot:=public.fgv_check_availability(eid,start_local,2);
 IF NOT (slot->>'available')::boolean THEN RAISE EXCEPTION 'Disponibilidad inicial'; END IF;
 b:=public.fgv_save_reservation(eid,start_local,2,'Prueba FGV','+34900000000','Prueba temporal',bk);
 rid:=(b->>'id')::uuid;
 retry:=public.fgv_save_reservation(eid,start_local,2,'Prueba FGV','+34900000000','Prueba temporal',bk);
 IF retry->>'id' IS DISTINCT FROM b->>'id' THEN RAISE EXCEPTION 'Reserva duplicada'; END IF;

 slot:=public.fgv_check_availability(eid,start_local,2);
 IF (slot->>'available')::boolean THEN RAISE EXCEPTION 'Sobreventa'; END IF;
 BEGIN
  PERFORM public.fgv_save_reservation(eid,start_local,2,'Otra prueba','+34900000001','',gen_random_uuid());
  RAISE EXCEPTION 'FALLO: aceptada doble reserva';
 EXCEPTION WHEN raise_exception THEN
  IF SQLERRM LIKE 'FALLO:%' THEN RAISE; END IF;
  IF SQLERRM NOT LIKE 'No queda%' THEN RAISE; END IF;
 END;

 b:=public.fgv_save_reservation(eid,start_local+interval '2 hours',2,'Prueba modificada','+34900000000','Modificada',bk,rid,(b->>'revision')::int);
 IF (b->>'revision')::int<>2 THEN RAISE EXCEPTION 'Revision incorrecta'; END IF;
 PERFORM public.fgv_cancel_reservation(eid,rid,2);
 PERFORM public.fgv_cancel_reservation(eid,rid,2);
 slot:=public.fgv_check_availability(eid,start_local+interval '2 hours',2);
 IF NOT (slot->>'available')::boolean THEN RAISE EXCEPTION 'Cancelacion no libera mesa'; END IF;
 IF jsonb_array_length(public.fgv_list_reservations(eid,start_local::date))<>1 THEN RAISE EXCEPTION 'Listado incorrecto'; END IF;

 IF EXISTS(SELECT 1 FROM public.establishments WHERE id='ffffeeee-dddd-4ccc-8bbb-aaaaaaaaaaaa') THEN RAISE EXCEPTION 'Acceso a restaurante ajeno'; END IF;
 BEGIN
  PERFORM public.fgv_list_reservations('ffffeeee-dddd-4ccc-8bbb-aaaaaaaaaaaa',start_local::date);
  RAISE EXCEPTION 'FALLO: acceso a motor ajeno';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN
  INSERT INTO public.establishment_users(establishment_id,user_id,role) VALUES('ffffeeee-dddd-4ccc-8bbb-aaaaaaaaaaaa',auth.uid(),'owner');
  RAISE EXCEPTION 'FALLO: vinculacion indebida';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN
  UPDATE public.profiles SET role='superadmin' WHERE id=auth.uid();
  RAISE EXCEPTION 'FALLO: escalada de rol';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;

END $$;
SELECT 'OK: onboarding, reglas, mesas, alta, reintento, sobreventa, modificación, cancelación y aislamiento' AS pruebas;
ROLLBACK;
