/* FGV dashboard: the database is authoritative for availability and writes. */
(() => {
  const days = [['monday','Lunes'],['tuesday','Martes'],['wednesday','Miércoles'],['thursday','Jueves'],['friday','Viernes'],['saturday','Sábado'],['sunday','Domingo']];
  const state = {date:'', rows:[], tables:[], settings:null, editing:null, requestKey:null, loading:0, optionsGeneration:0, settingsDirty:false, tableDirty:false};
  const esc = value => escapeHtml(value ?? '');
  const $ = id => document.getElementById(id);
  const tz = () => currentEstablishment?.timezone || 'Europe/Madrid';
  const localDate = value => new Intl.DateTimeFormat('en-CA',{timeZone:tz(),year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(value));
  const localInput = value => {
    const parts = new Intl.DateTimeFormat('en-CA',{timeZone:tz(),year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(new Date(value));
    const p = Object.fromEntries(parts.map(x=>[x.type,x.value]));
    return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}`;
  };
  const time = value => new Intl.DateTimeFormat('es-ES',{timeZone:tz(),hour:'2-digit',minute:'2-digit'}).format(new Date(value));
  const rpc = async (name,args) => {
    const {data,error} = await supabaseClient.rpc(name,{p_establishment_id:establishmentId,...args});
    if(error) throw error;
    return data;
  };
  const notify = (message,error=false) => {
    const el=$('fgvMessage'); if(!el) return;
    el.textContent=message; el.className=error?'fgv-message fgv-error':'fgv-message'; el.hidden=false;
  };
  async function busy(form,action) {
    const buttons=[...form.querySelectorAll('button')]; buttons.forEach(b=>b.disabled=true);
    try {await action();} catch(e) {notify(e.message||'No se pudo completar la operación. Inténtalo de nuevo.',true);}
    finally {buttons.forEach(b=>b.disabled=false);}
  }
  function base() {
    if($('fgvRoot')) return;
    $('reservationsSummary').innerHTML='';
    $('reservationsContent').innerHTML=`<div id="fgvRoot">
      <div class="fgv-toolbar"><label>Día <input id="fgvDate" type="date" required></label><button id="fgvRefresh" type="button">Actualizar</button><button id="fgvNew" type="button">Nueva reserva</button></div>
      <p id="fgvMessage" class="fgv-message" role="status" aria-live="polite" hidden></p>
      <p class="fgv-muted">Horas del restaurante: ${esc(tz())}. La disponibilidad se vuelve a comprobar al guardar.</p>
      <form id="fgvBooking" class="fgv-panel" hidden>
       <h3 id="fgvFormTitle">Nueva reserva</h3><div class="fgv-grid">
       <label>Nombre<input id="fgvName" required maxlength="120" autocomplete="name"></label>
       <label>Teléfono<input id="fgvPhone" required type="tel" maxlength="30" autocomplete="tel" placeholder="+34 600 000 000"></label>
       <label>Fecha y hora<input id="fgvStart" required type="datetime-local" step="60"></label>
       <label>Personas<input id="fgvPeople" required type="number" min="1" max="100" value="2"></label></div>
       <label>Notas<textarea id="fgvNotes" maxlength="2000" rows="2"></textarea></label>
       <div class="fgv-toolbar"><button type="button" id="fgvCheck">Comprobar disponibilidad</button><button type="submit">Guardar reserva</button><button type="button" id="fgvClose">Cerrar</button></div>
       <div id="fgvOptions" class="reservation-options" aria-live="polite" hidden></div>
      </form>
      <div class="filter-strip"><label>Buscar reservas<input id="fgvSearch" type="search" placeholder="Nombre, teléfono o mesa"></label><label>Estado<select id="fgvStatusFilter"><option value="">Todos</option><option value="confirmed">Confirmadas</option><option value="pending">Pendientes</option><option value="cancelled">Canceladas</option></select></label></div>
      <div id="fgvList" aria-live="polite"></div>
      <details class="fgv-panel" id="fgvSetup"><summary>Configurar reglas y mesas</summary><p class="fgv-muted">Configura el aforo y cada mesa real antes de aceptar reservas. Los cambios se aplican a reservas nuevas y modificadas. Las ya aceptadas conservan su duración. El aforo y los horarios deben seguir admitiéndolas.</p>
       <form id="fgvSettings"><div class="fgv-grid">
        <label>Aforo total<input name="total_capacity" type="number" required min="1" max="10000"></label>
        <label>Máximo por reserva<input name="max_people" type="number" required min="1" max="100"></label>
        <label>Duración (minutos)<input name="duration_minutes" type="number" required min="15" max="720"></label>
        <label>Antelación mínima (minutos)<input name="min_notice_minutes" type="number" required min="0" max="525600"></label>
        <label>Antelación máxima (días)<input name="max_advance_days" type="number" required min="0" max="730"></label>
       </div><div id="fgvSchedule"></div><button type="submit">Guardar reglas</button></form>
       <h3>Mesas</h3><div id="fgvTables"></div>
       <form id="fgvTableForm" class="fgv-toolbar"><input id="fgvTableId" type="hidden"><label>Nombre de mesa<input id="fgvTableName" maxlength="80" required placeholder="Mesa 1"></label><label>Plazas<input id="fgvTableCapacity" type="number" min="1" max="100" required></label><label><input id="fgvTableActive" type="checkbox" checked> Activa</label><button type="submit">Guardar mesa</button><button id="fgvTableReset" type="button">Nueva mesa</button></form>
      </details></div>`;
    state.date ||= currentEstablishmentConfig.demo_scenario?.date||localDate(new Date()); $('fgvDate').value=state.date;
    $('fgvDate').onchange=()=>{if(!$('fgvDate').value)return;state.date=$('fgvDate').value; refresh();};
    $('fgvSearch').oninput=renderRows; $('fgvStatusFilter').onchange=renderRows;
    $('fgvRefresh').onclick=refresh; $('fgvNew').onclick=()=>edit(null);
    $('fgvClose').onclick=()=>{$('fgvBooking').hidden=true;};
    $('fgvBooking').onsubmit=e=>{e.preventDefault();busy(e.currentTarget,saveBooking);};
    for(const id of ['fgvStart','fgvPeople'])$(id).addEventListener('input',()=>{state.optionsGeneration++;$('fgvOptions').hidden=true;});
    $('fgvCheck').onclick=()=>busy($('fgvBooking'),async()=>{
      if(!$('fgvStart').reportValidity()||!$('fgvPeople').reportValidity())return;
      const ticket=++state.optionsGeneration,requested=$('fgvStart').value,people=Number($('fgvPeople').value);
      $('fgvOptions').hidden=true;
      const result=await rpc('fgv_reservation_options',{p_local_start:requested,p_people:people,p_exclude:state.editing?.id||null});
      if(ticket!==state.optionsGeneration)return;
      const now=result.requested,options=result.alternatives;
      notify(now.available?`Disponible a las ${time(now.start_at)}: ${now.table_name}, ${now.table_capacity} plazas. Se comprobará de nuevo al guardar.`:now.reason,!now.available);
      const root=$('fgvOptions');
      if(options.length){root.innerHTML=`<h3>${now.available?'También puedes esperar a una mesa más ajustada':'Otros horarios disponibles'}</h3><p class="fgv-muted">${now.available?`Para ${people} personas hay a esa hora una mesa de ${now.table_capacity} plazas. Puedes mantener esa hora o elegir una opción posterior.`:'Estas opciones respetan las mesas, el aforo y la duración de la reserva.'}</p><div class="reservation-option-grid">${options.map((o,i)=>`<button type="button" class="quiet-button reservation-option" data-option="${i}"><strong>${esc(time(o.start_at))} · ${o.table_capacity} plazas</strong><span>${esc(o.table_name)}</span><small>Esperar ${o.wait_minutes} min · Elegir hora</small></button>`).join('')}</div><small class="fgv-muted">Consultar no bloquea mesas. Elegir una hora tampoco guarda la reserva.</small>`;root.hidden=false;root.querySelectorAll('[data-option]').forEach(b=>b.onclick=()=>{if(ticket!==state.optionsGeneration)return;const option=options[Number(b.dataset.option)];$('fgvStart').value=localInput(option.start_at);state.optionsGeneration++;root.hidden=true;notify(`Hora elegida: ${time(option.start_at)}. Completa los datos y pulsa Guardar reserva para confirmar.`);});}
      else if(!now.available){root.innerHTML='<p class="fgv-muted">No se han encontrado alternativas en las tres horas siguientes. Prueba otra fecha o servicio.</p>';root.hidden=false;}
    });
    $('fgvSettings').oninput=()=>{state.settingsDirty=true;};
    $('fgvTableForm').oninput=()=>{state.tableDirty=true;};
    $('fgvSettings').onsubmit=e=>{e.preventDefault();busy(e.currentTarget,saveSettings);};
    $('fgvTableForm').onsubmit=e=>{e.preventDefault();busy(e.currentTarget,async()=>{
      await rpc('fgv_save_table',{p_table_id:$('fgvTableId').value||null,p_name:$('fgvTableName').value,p_capacity:Number($('fgvTableCapacity').value),p_active:$('fgvTableActive').checked});
      $('fgvTableForm').reset(); $('fgvTableId').value=''; state.tableDirty=false; await refresh(); notify('Mesa guardada.');
    });};
    $('fgvTableReset').onclick=()=>{$('fgvTableForm').reset();$('fgvTableId').value='';};
  }
  function edit(row) {
    state.editing=row; state.requestKey=crypto.randomUUID();state.optionsGeneration++;$('fgvOptions').hidden=true;
    $('fgvFormTitle').textContent=row?'Modificar reserva':'Nueva reserva';
    $('fgvName').value=row?.metadata?.guest_name||row?.guest_name||'';
    $('fgvPhone').value=row?.metadata?.guest_phone||row?.guest_phone||'';
    $('fgvStart').value=row?localInput(row.start_at):`${state.date}T${currentEstablishmentConfig.demo_scenario?'21:00':'13:00'}`;
    $('fgvPeople').value=row?.party_size||2; $('fgvNotes').value=row?.metadata?.notes||'';
    $('fgvPeople').max=state.settings?.max_people||100;
    $('fgvBooking').hidden=false; $('fgvName').focus();
  }
  async function saveBooking() {
    const row=await rpc('fgv_save_reservation',{p_local_start:$('fgvStart').value,p_people:Number($('fgvPeople').value),p_name:$('fgvName').value,p_phone:$('fgvPhone').value,p_notes:$('fgvNotes').value,p_request_key:state.requestKey,p_reservation_id:state.editing?.id||null,p_revision:state.editing?.revision||null});
    state.date=localDate(row.start_at); $('fgvDate').value=state.date; $('fgvBooking').hidden=true;
    await refresh(); notify('Reserva guardada y mesa asignada.');
  }
  function renderSettings() {
    const old=currentBusinessRules||{};
    const advance={same_day:0,'1_day':1,'7_days':7,'30_days':30}[old.booking_advance];
    const s=state.settings||{total_capacity:old.total_capacity,max_people:old.max_people,duration_minutes:old.stay_duration==='custom'?'':old.stay_duration,min_notice_minutes:0,max_advance_days:advance,schedules:old.schedules||{}};
    for(const key of ['total_capacity','max_people','duration_minutes','min_notice_minutes','max_advance_days']) $('fgvSettings').elements[key].value=s[key]??'';
    $('fgvSchedule').innerHTML=days.map(([key,label])=>{
      const d=s.schedules?.[key]||{closed:true,services:[]}; const a=d.services?.[0]||{}; const b=d.services?.[1]||{};
      return `<fieldset class="fgv-day"><legend>${label}</legend><label><input type="checkbox" id="fgvClosed_${key}" ${d.closed?'checked':''}> Cerrado</label><label>Apertura<input type="time" id="fgvOpen_${key}" value="${esc(a.open)}"></label><label>Cierre<input type="time" id="fgvEnd_${key}" value="${esc(a.close)}"></label><label>2ª apertura (opcional)<input type="time" id="fgvOpen2_${key}" value="${esc(b.open)}"></label><label>2º cierre<input type="time" id="fgvEnd2_${key}" value="${esc(b.close)}"></label></fieldset>`;
    }).join('');
    $('fgvTables').innerHTML=state.tables.length?state.tables.map(t=>`<div class="fgv-toolbar"><strong>${esc(t.name)}</strong><span>${t.capacity} plazas · ${t.active?'Activa':'Inactiva'}</span><button type="button" data-table="${t.id}">Editar</button></div>`).join(''):'<p>No hay mesas configuradas. Añade las mesas reales y sus plazas.</p>';
    $('fgvTables').querySelectorAll('[data-table]').forEach(b=>b.onclick=()=>{
      const t=state.tables.find(t=>t.id===b.dataset.table);$('fgvTableId').value=t.id;$('fgvTableName').value=t.name;$('fgvTableCapacity').value=t.capacity;$('fgvTableActive').checked=t.active;
    });
  }
  async function saveSettings() {
    const settings={schedules:{}};
    for(const key of ['total_capacity','max_people','duration_minutes','min_notice_minutes','max_advance_days']) settings[key]=Number($('fgvSettings').elements[key].value);
    for(const [key] of days) {
      const closed=$(`fgvClosed_${key}`).checked; const services=[];
      if(!closed) {
        const open=$(`fgvOpen_${key}`).value, close=$(`fgvEnd_${key}`).value;
        if(!open||!close)throw new Error('Completa la apertura y el cierre de cada día abierto.');
        services.push({open,close});
        const open2=$(`fgvOpen2_${key}`).value, close2=$(`fgvEnd2_${key}`).value;
        if(open2||close2){if(!open2||!close2)throw new Error('Completa las dos horas del segundo turno.');services.push({open:open2,close:close2});}
      }
      settings.schedules[key]={closed,services,type:closed?'closed':services.length===2?'split':'continuous'};
    }
    await rpc('fgv_save_settings',{p_settings:settings});state.settingsDirty=false;await refresh();notify('Reglas guardadas.');
  }
  async function refresh() {
    const generation=++state.loading;
    $('fgvList').textContent='Cargando reservas…';
    try {
      const results=await Promise.all([
        rpc('fgv_list_reservations',{p_day:state.date}),
        supabaseClient.from('restaurant_tables').select('*').eq('establishment_id',establishmentId).order('name'),
        supabaseClient.from('reservation_settings').select('*').eq('establishment_id',establishmentId).maybeSingle()
      ]);
      if(generation!==state.loading)return;
      for(const r of results.slice(1))if(r.error)throw r.error;
      state.rows=results[0]||[];state.tables=results[1].data||[];state.settings=results[2].data;
      if(state.settings)currentBusinessRules={...currentBusinessRules,...state.settings,tables_count:state.tables.filter(t=>t.active).length,stay_duration:state.settings.duration_minutes + " minutos",booking_advance:`Entre ${state.settings.min_notice_minutes} minutos y ${state.settings.max_advance_days} días`};
      if(!state.settingsDirty)renderSettings();
      const ready=state.settings&&state.tables.some(t=>t.active);
      $('fgvNew').disabled=!ready;
      if(!ready){$('fgvSetup').open=true;notify('Antes de crear reservas, guarda las reglas y añade al menos una mesa.',true);}
      const active=state.rows.filter(r=>['pending','confirmed'].includes(r.status));
      $('reservationsSummary').textContent=`${active.length} reservas activas · ${active.reduce((n,r)=>n+(r.party_size||0),0)} comensales en el día`;
      renderRows();
    } catch(e) {if(generation!==state.loading)return;$('fgvList').textContent='No se pudieron cargar las reservas.';$('fgvNew').disabled=true;notify(e.message,true);}
  }
  function renderRows(){
      const query=($('fgvSearch')?.value||'').toLowerCase().trim(),status=$('fgvStatusFilter')?.value||'';
      const rows=state.rows.filter(r=>(!status||r.status===status)&&(!query||[r.metadata?.guest_name,r.guest_name,r.metadata?.guest_phone,r.guest_phone,r.table_name].join(' ').toLowerCase().includes(query)));
      if(!rows.length){$('fgvList').innerHTML='<div class="empty-state">No hay reservas que mostrar con esta fecha y estos filtros.</div>';return;}
      const labels={pending:'Pendiente',confirmed:'Confirmada',cancelled:'Cancelada',completed:'Finalizada',no_show:'No presentado'};
      $('fgvList').innerHTML=`<div class="fgv-scroll"><table class="fgv-bookings"><thead><tr><th>Hora</th><th>Cliente</th><th>Personas</th><th>Mesa</th><th>Estado</th><th>Acciones</th></tr></thead><tbody>${rows.map(r=>`<tr><td>${esc(time(r.start_at))}–${esc(time(r.end_at))}</td><td>${esc(r.metadata?.guest_name||r.guest_name||'Sin nombre')}<small>${esc(r.metadata?.guest_phone||r.guest_phone||'')}</small></td><td>${esc(r.party_size)}</td><td>${esc(r.table_name||'Sin asignar')}</td><td>${esc(labels[r.status]||r.status)}</td><td>${['pending','confirmed'].includes(r.status)?`<button type="button" data-edit="${r.id}">Modificar</button> <button type="button" data-cancel="${r.id}">Cancelar</button>`:''}</td></tr>`).join('')}</tbody></table></div>`;
      $('fgvList').querySelectorAll('[data-edit]').forEach(b=>b.onclick=()=>edit(state.rows.find(r=>r.id===b.dataset.edit)));
      $('fgvList').querySelectorAll('[data-cancel]').forEach(b=>b.onclick=async()=>{
        const r=state.rows.find(r=>r.id===b.dataset.cancel);
        if(!confirm(`¿Cancelar la reserva de ${r.metadata?.guest_name||r.guest_name||'este cliente'} a las ${time(r.start_at)}?`))return;
        b.disabled=true;
        try{await rpc('fgv_cancel_reservation',{p_reservation_id:r.id,p_revision:r.revision});await refresh();notify('Reserva cancelada. La mesa vuelve a estar disponible.');}catch(e){notify(e.message,true);b.disabled=false;}
      });
  }
  window.reservationHasUnsavedChanges=()=>state.settingsDirty||state.tableDirty;
  window.loadReservations=async()=>{
    if(!establishmentId)return;
    if(currentEstablishmentConfig.reservation_type!=='manual'){
      $('reservationsSummary').textContent='';$('reservationsContent').innerHTML='<div class="empty-state">La conexión con el proveedor externo todavía no está activada. No se puede consultar ni confirmar disponibilidad desde FGV.</div>';return;
    }
    base();await refresh();
  };
})();
