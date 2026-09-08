/* Shared workspace presentation; business writes stay in the authorized RPCs. */
(() => {
  const esc = value => escapeHtml(value ?? '');
  const day = date => new Intl.DateTimeFormat('en-CA',{timeZone:currentEstablishment?.timezone||'Europe/Madrid',year:'numeric',month:'2-digit',day:'2-digit'}).format(date);
  const hour = date => new Intl.DateTimeFormat('es-ES',{timeZone:currentEstablishment?.timezone||'Europe/Madrid',hour:'2-digit',minute:'2-digit'}).format(new Date(date));
  const rpc = async (name,args={}) => {const {data,error}=await supabaseClient.rpc(name,{p_establishment_id:establishmentId,...args});if(error)throw error;return data;};
  window.FGV={esc,day,hour,rpc};
  window.renderReservationMode=()=>{
    const el=document.getElementById('reservationModeContent');
    el.innerHTML=currentEstablishmentConfig.reservation_type==='manual'?'<strong>Motor de reservas incluido</strong><p>Las mesas, el aforo y tus horarios se comprueban al guardar cada reserva.</p>':'<strong>Tu programa de reservas</strong><p>La conexión aún está pendiente. La disponibilidad se consultará en tu programa cuando esté conectado.</p>';
  };
  let homeGeneration=0;
  async function home() {
    const root=document.getElementById('workspaceHome'), generation=++homeGeneration;
    if(!root||!establishmentId)return;
    root.innerHTML='<div class="skeleton" role="status">Preparando el día…</div>';
    try {
      const date=day(new Date());
      const [rows,settings,tables]=await Promise.all([rpc('fgv_list_reservations',{p_day:date}),supabaseClient.from('reservation_settings').select('*').eq('establishment_id',establishmentId).maybeSingle(),supabaseClient.from('restaurant_tables').select('*').eq('establishment_id',establishmentId).eq('active',true)]);
      if(generation!==homeGeneration)return;
      if(settings.error)throw settings.error;if(tables.error)throw tables.error;
      const bookings=rows.filter(r=>['pending','confirmed'].includes(r.status)), now=Date.now();
      const present=bookings.filter(r=>Date.parse(r.start_at)<=now&&Date.parse(r.end_at)>now).reduce((n,r)=>n+r.party_size,0), capacity=settings.data?.total_capacity;
      const upcoming=bookings.filter(r=>Date.parse(r.end_at)>now).slice(0,5);
      const manual=currentEstablishmentConfig.reservation_type==='manual';
      const ready=manual&&settings.data&&tables.data.length;
      root.innerHTML=`<div class="workspace-kicker">${esc(new Intl.DateTimeFormat('es-ES',{dateStyle:'full',timeZone:currentEstablishment.timezone}).format(new Date()))}</div>
      <div class="metric-grid"><article class="metric"><span>Reservas de hoy</span><strong>${manual?bookings.length:'—'}</strong><small>${manual?'Confirmadas y pendientes':'Programa externo pendiente de conexión'}</small></article><article class="metric"><span>Comensales del día</span><strong>${manual?bookings.reduce((n,r)=>n+r.party_size,0):'—'}</strong><small>En las reservas activas</small></article><article class="metric"><span>Ocupación prevista ahora</span><strong>${manual&&capacity?Math.round(present/capacity*100)+'%':'—'}</strong><small>${manual&&capacity?present+' de '+capacity+' plazas':'Configura el motor para calcularla'}</small></article><article class="metric"><span>Mesas activas</span><strong>${tables.data.length}</strong><small>Tu sala, siempre a mano</small></article></div>
      <div class="home-columns"><article class="surface"><div class="surface-heading"><div><div class="workspace-kicker">SERVICIO DE HOY</div><h2>Próximas llegadas</h2></div><button data-go="reservas" class="quiet-button">Ver reservas →</button></div>${upcoming.length?upcoming.map(r=>`<div class="arrival"><span class="arrival-time">${esc(hour(r.start_at))}</span><div><strong>${esc(r.metadata?.guest_name||r.guest_name||'Cliente')}</strong><small>${r.party_size} personas · ${esc(r.table_name||'Mesa pendiente')}</small></div><span class="pill">${r.status==='confirmed'?'Confirmada':'Pendiente'}</span></div>`).join(''):`<div class="calm-empty"><span class="empty-symbol">↗</span><h3>${manual?'Tu próximo servicio empieza aquí':'Conecta tu programa de reservas'}</h3><p>${manual?'Las reservas aparecerán aquí cuando las añadas.':'Conserva tu agenda actual y completa la conexión antes de aceptar reservas automáticas.'}</p><button data-go="${manual?'reservas':'configuracion'}" class="primary-action">${manual?'Gestionar reservas':'Ver configuración'}</button></div>`}</article>
      <article class="surface activation"><div class="workspace-kicker">TU PUESTA EN MARCHA</div><h2>Todo en su sitio.</h2><p>Un paso cada vez para empezar a recibir reservas.</p><div class="setup-line"><span class="step-dot done">✓</span><div><strong>Restaurante creado</strong><small>Datos y acceso al panel</small></div></div><div class="setup-line"><span class="step-dot ${ready?'done':''}">${ready?'✓':'2'}</span><div><strong>${manual?'Configurar sala y horarios':'Conectar programa de reservas'}</strong><small>${ready?'Motor configurado':manual?'Añade tus mesas reales y revisa las reglas':'Pendiente de conexión y prueba'}</small></div></div><div class="setup-line"><span class="step-dot">3</span><div><button type="button" class="quiet-button" data-go="configuracion">Conectar WhatsApp</button><small>Pendiente de conexión y prueba</small></div></div><button data-go="${manual?'sala':'configuracion'}" class="quiet-button">${manual?'Abrir mi sala':'Abrir configuración'} →</button></article></div>`;
      root.querySelectorAll('[data-go]').forEach(b=>b.onclick=()=>showRestaurantSection(b.dataset.go));
    }catch(e){root.innerHTML=`<div class="fgv-message fgv-error">${esc(e.message||'No se pudo cargar el resumen.')}</div>`;}
  }
  document.addEventListener('fgv:section',event=>{
    const section=event.detail;
    document.querySelectorAll('[data-nav]').forEach(b=>{b.classList.toggle('selected',b.dataset.nav===section);if(b.dataset.nav===section)b.setAttribute('aria-current','page');else b.removeAttribute('aria-current');});
    document.getElementById('workspaceRestaurant').textContent=currentEstablishment?.name||'Tu restaurante';
    if(section==='inicio')home();if(section==='sala')window.loadFloorPlan?.();
  });
  document.querySelectorAll('[data-nav]').forEach(b=>b.onclick=()=>showRestaurantSection(b.dataset.nav));
  let clientGeneration=0;
  window.loadCustomers=async()=>{
    const root=document.getElementById('customersContent'), generation=++clientGeneration;root.textContent='Cargando clientes…';
    try {
      const {data,error}=await supabaseClient.from('customers').select('id,name,phone,email,created_at').eq('establishment_id',establishmentId).order('created_at',{ascending:false}).limit(200);if(error)throw error;if(generation!==clientGeneration)return;
      root.innerHTML=`<div class="fgv-toolbar"><label>Buscar clientes<input id="clientSearch" type="search" placeholder="Nombre o teléfono"></label><span class="fgv-muted">${data.length} clientes${data.length===200?' más recientes':''}</span></div><div id="clientList"></div><div id="clientDetail" class="surface" hidden></div>`;
      const render=()=>{const query=document.getElementById('clientSearch').value.toLowerCase().trim(),list=data.filter(c=>(c.name+' '+c.phone).toLowerCase().includes(query));document.getElementById('clientList').innerHTML=list.length?`<div class="customer-grid">${list.map(c=>`<button class="customer-card" data-client="${c.id}"><span class="avatar">${esc((c.name||'?').slice(0,1).toUpperCase())}</span><span><strong>${esc(c.name||'Sin nombre')}</strong><small>${esc(c.phone||c.email||'Sin contacto')}</small></span><span class="chevron">↗</span></button>`).join('')}</div>`:'<div class="empty-state">No hay clientes que coincidan.</div>';root.querySelectorAll('[data-client]').forEach(b=>b.onclick=()=>detail(data.find(c=>c.id===b.dataset.client)));};
      let detailGeneration=0;
      async function detail(client){const ticket=++detailGeneration,box=document.getElementById('clientDetail');box.hidden=false;box.textContent='Cargando historial…';box.scrollIntoView({behavior:'smooth',block:'nearest'});const {data:bookings,error}=await supabaseClient.from('reservations').select('id,start_at,party_size,status,metadata').eq('establishment_id',establishmentId).eq('customer_id',client.id).order('start_at',{ascending:false}).limit(50);if(ticket!==detailGeneration||generation!==clientGeneration)return;box.innerHTML=`<div class="surface-heading"><h2>${esc(client.name||'Cliente')}</h2><button id="closeClient" class="quiet-button">Cerrar</button></div><p class="fgv-muted">${esc(client.phone||'')} · ${esc(client.email||'')}</p>${error?`<p role="alert">${esc(error.message)}</p>`:bookings.length?bookings.map(r=>`<div class="arrival"><div><strong>${esc(new Intl.DateTimeFormat('es-ES',{dateStyle:'medium',timeStyle:'short',timeZone:currentEstablishment.timezone}).format(new Date(r.start_at)))}</strong><small>${r.party_size} personas · ${esc(({confirmed:'Confirmada',pending:'Pendiente',cancelled:'Cancelada',completed:'Finalizada',no_show:'No presentado'})[r.status]||r.status)}</small>${r.metadata?.notes?`<small>${esc(r.metadata.notes)}</small>`:''}</div></div>`).join(''):'<p>Sin reservas registradas.</p>'}`;document.getElementById('closeClient').onclick=()=>{box.hidden=true;detailGeneration++;};}
      document.getElementById('clientSearch').oninput=render;render();
    }catch(e){root.textContent=e.message||'No se pudieron cargar los clientes.';}
  };
})();
