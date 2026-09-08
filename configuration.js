/* Owner-editable information. All changes pass through authorized database functions. */
(() => {
  const esc = value => escapeHtml(value ?? '');
  const providers = {covermanager:'CoverManager',thefork:'TheFork',google_calendar:'Google Calendar',other:'Otro programa'};
  let generation = 0;
  window.renderConfiguration = async function () {
    const ticket = ++generation, root = document.getElementById('configurationContent');
    if (!root) return;
    const e = currentEstablishment || {}, c = currentEstablishmentConfig || {};
    const field = (key,label,type='text',max=160) => `<label>${label}<input name="${key}" type="${type}" maxlength="${max}" value="${esc(key==='city'?(e.city??c.city):e[key])}" ${['name','business_type'].includes(key)?'required':''}></label>`;
    root.innerHTML = `<div class="fgv-panel"><h3>Puesta en marcha</h3><p id="fgvReadiness" role="status">Comprobando la configuración…</p><button id="fgvGoReservations" type="button">Ver reservas, horarios y mesas</button><p class="fgv-muted">WhatsApp, notas de voz y llamadas: pendientes de conexión y prueba. Elegir un programa de reservas no lo conecta automáticamente.</p></div>
      <form id="fgvProfile" class="fgv-panel"><h3>Tu restaurante</h3><div class="fgv-grid">${field('name','Nombre')}${field('business_type','Tipo de negocio','text',80)}${field('phone','Teléfono','tel',30)}${field('email','Correo','email',254)}${field('address','Dirección','text',300)}${field('city','Ciudad','text',120)}
      <label>Zona horaria<input name="timezone" value="${esc(e.timezone||'Europe/Madrid')}" required list="fgvTimezones"><datalist id="fgvTimezones"><option value="Europe/Madrid"><option value="Atlantic/Canary"><option value="Europe/Lisbon"></datalist></label>
      <label>Idioma<select name="language"><option value="es">Español</option><option value="en">Inglés</option></select></label></div>
      <h3>Cómo gestionas las reservas</h3><div class="fgv-grid"><label>Sistema<select name="reservation_type"><option value="manual">Usar el motor de reservas incluido</option><option value="digital">Conservar mi programa actual</option></select></label>
      <label id="fgvProviderLabel">Programa<select name="reservation_system"><option value="">Elige un programa</option>${Object.entries(providers).map(([key,label])=>`<option value="${key}">${label}</option>`).join('')}</select></label></div>
      <p id="fgvProviderHelp" class="fgv-muted"></p><p class="fgv-muted">Si hay reservas aceptadas, cambiar de sistema o zona horaria requiere revisar su traslado.</p>
      <button type="submit">Guardar cambios</button><p id="fgvProfileMessage" role="status" aria-live="polite"></p></form>`;
    const form = document.getElementById('fgvProfile'), fields = form.elements;
    fields.language.value = e.language || 'es'; fields.reservation_type.value = c.reservation_type || 'manual'; fields.reservation_system.value = c.reservation_system || '';
    function mode() {
      const external = fields.reservation_type.value === 'digital';
      document.getElementById('fgvProviderLabel').hidden = !external;
      fields.reservation_system.required = external;
      document.getElementById('fgvProviderHelp').textContent = external ? (fields.reservation_system.value === 'google_calendar' ? 'Google Calendar necesita además reglas de capacidad. Conexión pendiente: todavía no se confirman reservas desde aquí.' : 'Tu programa seguirá siendo la referencia de disponibilidad. Conexión pendiente: todavía no se confirman reservas desde aquí.') : 'Configura las plazas de cada mesa, el aforo y los turnos en Reservas.';
    }
    fields.reservation_type.addEventListener('change',mode); fields.reservation_system.addEventListener('change',mode); mode();
    document.getElementById('fgvGoReservations').onclick = () => showRestaurantSection('reservas');
    form.addEventListener('submit',async event => {
      event.preventDefault(); const button=form.querySelector('button[type=submit]'), message=document.getElementById('fgvProfileMessage');
      button.disabled=true; message.textContent='Guardando…';
      try {
        const values=Object.fromEntries(new FormData(form));
        const {data,error}=await supabaseClient.rpc('fgv_update_restaurant',{p_establishment_id:establishmentId,p_data:values,p_expected_revision:currentEstablishment.settings_revision});
        if(error) throw error;
        currentEstablishment=data; currentEstablishmentConfig={...currentEstablishmentConfig,city:data.city,reservation_type:values.reservation_type,reservation_system:values.reservation_type==='digital'?values.reservation_system:''};
        // Refresh summary labels from the saved state on the next page load.
        message.textContent='Cambios guardados.'; message.className='fgv-message'; button.disabled=false;
        document.getElementById('restaurantName').textContent=data.name;
        document.getElementById('workspaceRestaurant').textContent=data.name;
        document.getElementById('restaurantLocation').textContent=[data.city,data.address].filter(Boolean).join(' · ');
        document.getElementById('fgvReadiness').textContent=values.reservation_type==='digital'?'Programa elegido. Falta conectar y probar la integración.':'Datos guardados. Revisa tus mesas y horarios antes del servicio.';

      } catch(error) {message.textContent=error.message||'No se pudo guardar. Puedes volver a intentarlo.'; message.className='fgv-message fgv-error'; button.disabled=false;}
    });
    try {
      if(c.reservation_type==='digital') { document.getElementById('fgvReadiness').textContent=`Programa elegido: ${providers[c.reservation_system]||'pendiente de elegir'}. Falta conectar y probar el programa.`; return; }
      const results=await Promise.all([
        supabaseClient.from('reservation_settings').select('establishment_id').eq('establishment_id',establishmentId).maybeSingle(),
        supabaseClient.from('restaurant_tables').select('id',{count:'exact',head:true}).eq('establishment_id',establishmentId).eq('active',true)
      ]);
      if(ticket!==generation) return;
      for(const result of results) if(result.error) throw result.error;
      document.getElementById('fgvReadiness').textContent=results[0].data && results[1].count>0 ? `Motor configurado con ${results[1].count} mesas activas. Puedes gestionar reservas desde el panel; falta probar los canales de atención.` : 'Falta configurar las reglas y las mesas para empezar a reservar.';
    } catch(error) { if(ticket===generation) document.getElementById('fgvReadiness').textContent='No se pudo comprobar la configuración. Recarga para volver a intentarlo.'; }
  };
})();
