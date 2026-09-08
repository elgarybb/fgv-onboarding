/* Logical 1000×720 room. Pointer movement is visual; operational edits use fgv_save_table. */
(() => {
  let state={loaded:null,tables:[],items:[],revision:0,selected:null,editable:false,dirty:false,saving:false,failed:false,generation:0};
  const $=id=>document.getElementById(id), esc=value=>FGV.esc(value);
  const position=(table,index)=>state.items.find(p=>p.table_id===table.id)||{table_id:table.id,x:60+(index%5)*185,y:Math.min(620,70+Math.floor(index/5)*145),shape:table.capacity<=2?'round':table.capacity<=4?'square':'rectangle'};
  function status(message,error=false){const el=$('floorStatus');if(el){el.textContent=message;el.className=error?'floor-status error':'floor-status';}$('floorRetry')?.toggleAttribute('hidden',!error);}
  function setItem(id,patch){let item=state.items.find(p=>p.table_id===id);if(!item){item=position(state.tables.find(t=>t.id===id),state.tables.findIndex(t=>t.id===id));state.items.push(item);}Object.assign(item,patch);state.dirty=true;state.failed=false;status('Cambios pendientes');}
  function paintPosition(button,item){button.style.left=(item.x/10)+'%';button.style.top=(item.y/7.2)+'%';button.dataset.shape=item.shape;}
  async function persist(){
    if(state.saving||!state.dirty||!state.editable)return;
    state.saving=true;state.failed=false;state.dirty=false;status('Guardando…');
    const snapshot=state.items.map(item=>({...item}));
    try{const result=await FGV.rpc('fgv_save_floor_plan',{p_revision:state.revision,p_items:snapshot});state.revision=result.revision;status(state.dirty?'Guardando…':'Guardado');}
    catch(e){state.dirty=true;state.failed=true;status(e.message||'No se pudo guardar. Reintenta antes de salir.',true);}
    finally{state.saving=false;if(state.dirty&&!state.failed)persist();}
  }
  function select(id){state.selected=id;$('floorCanvas').querySelectorAll('[data-table]').forEach(b=>{b.classList.toggle('is-selected',b.dataset.table===id);b.setAttribute('aria-pressed',b.dataset.table===id?'true':'false');});editor();}
  function editor(){
    const table=state.tables.find(t=>t.id===state.selected),root=$('floorEditor');
    if(!table){root.innerHTML='<div class="editor-empty"><span class="empty-symbol">⌘</span><h3>Tu sala, a tu manera.</h3><p>Selecciona una mesa para ver sus plazas y editarla.</p><small>En modo edición puedes arrastrar o usar las flechas del teclado.</small></div>';return;}
    const item=position(table,state.tables.indexOf(table));
    root.innerHTML=`<div class="workspace-kicker">MESA SELECCIONADA</div><h2>${esc(table.name)}</h2><p class="fgv-muted">${table.capacity} plazas · ${table.active?'Activa':'Inactiva'}</p><form id="floorTableForm"><label>Nombre<input name="name" required maxlength="80" value="${esc(table.name)}"></label><label>Plazas<input name="capacity" type="number" required min="1" max="100" value="${table.capacity}"></label><label>Forma<select name="shape"><option value="round">Redonda</option><option value="square">Cuadrada</option><option value="rectangle">Rectangular</option></select></label><label class="check-label"><input name="active" type="checkbox" ${table.active?'checked':''}>Disponible para reservas</label><button type="submit" class="primary-action">Guardar mesa</button><p id="floorTableMessage" role="status" class="fgv-muted"></p></form><p class="fgv-muted">Cambiar las plazas o desactivar una mesa no puede perjudicar reservas aceptadas.</p>`;
    const form=$('floorTableForm');form.elements.shape.value=item.shape;form.querySelectorAll('input,select,button').forEach(el=>el.disabled=!state.editable);
    form.onsubmit=async event=>{event.preventDefault();const button=form.querySelector('button'),message=$('floorTableMessage');button.disabled=true;message.textContent='Guardando…';try{await FGV.rpc('fgv_save_table',{p_table_id:table.id,p_name:form.elements.name.value,p_capacity:Number(form.elements.capacity.value),p_active:form.elements.active.checked});table.name=form.elements.name.value.trim();table.capacity=Number(form.elements.capacity.value);table.active=form.elements.active.checked;setItem(table.id,{shape:form.elements.shape.value});await persist();renderCanvas();message.textContent='Mesa guardada.';}catch(e){message.textContent=e.message||'No se pudo guardar.';}finally{button.disabled=!state.editable;}};
  }
  function renderCanvas(){
    const canvas=$('floorCanvas'),editing=$('floorEditMode').checked&&state.editable;
    const active=state.tables.filter(t=>t.active);canvas.classList.toggle('is-editing',editing);
    canvas.innerHTML=active.map((table,index)=>{const p=position(table,index);return `<button type="button" class="floor-table ${table.id===state.selected?'is-selected':''}" data-table="${table.id}" data-shape="${p.shape}" aria-label="${esc(table.name)}, ${table.capacity} plazas" aria-pressed="${table.id===state.selected}" style="left:${p.x/10}%;top:${p.y/7.2}%"><span class="table-seats" aria-hidden="true"></span><strong>${esc(table.name)}</strong><small>${table.capacity} plazas</small></button>`;}).join('');
    if(!active.length)canvas.innerHTML='<div class="floor-empty"><h3>Imagina tu próximo servicio.</h3><p>Añade la primera mesa para empezar a dibujar tu sala.</p></div>';
    $('floorCount').textContent=`${active.length} mesas · ${active.reduce((n,t)=>n+t.capacity,0)} plazas en mesas`;
    $('floorInactive').innerHTML=state.tables.some(t=>!t.active)?`<details><summary>Mesas inactivas (${state.tables.filter(t=>!t.active).length})</summary>${state.tables.filter(t=>!t.active).map(t=>`<button class="quiet-button" data-inactive="${t.id}">${esc(t.name)} · ${t.capacity} plazas</button>`).join('')}</details>`:'';
    $('floorInactive').querySelectorAll('[data-inactive]').forEach(b=>b.onclick=()=>select(b.dataset.inactive));
    canvas.querySelectorAll('[data-table]').forEach(button=>{
      const id=button.dataset.table;let drag=null;
      button.onclick=()=>select(id);
      button.onpointerdown=event=>{if(event.button!==0||!editing)return;const table=state.tables.find(t=>t.id===id),item=position(table,state.tables.filter(t=>t.active).findIndex(t=>t.id===id));select(id);drag={pointer:event.pointerId,startX:event.clientX,startY:event.clientY,x:item.x,y:item.y,lastX:item.x,lastY:item.y,moved:false};button.setPointerCapture(event.pointerId);button.classList.add('dragging');};
      button.onpointermove=event=>{if(!drag||drag.pointer!==event.pointerId)return;const rect=canvas.getBoundingClientRect(),dx=(event.clientX-drag.startX)/rect.width*1000,dy=(event.clientY-drag.startY)/rect.height*720;if(Math.abs(dx)+Math.abs(dy)>3)drag.moved=true;drag.lastX=Math.max(0,Math.min(870,Math.round((drag.x+dx)/5)*5));drag.lastY=Math.max(0,Math.min(620,Math.round((drag.y+dy)/5)*5));paintPosition(button,{...position(state.tables.find(t=>t.id===id),0),x:drag.lastX,y:drag.lastY});};
      const finish=event=>{if(!drag||event.pointerId!==drag.pointer)return;if(drag.moved){setItem(id,{x:drag.lastX,y:drag.lastY});persist();}drag=null;button.classList.remove('dragging');};
      button.onpointerup=finish;button.onpointercancel=finish;
      button.onkeydown=event=>{if(!editing||!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(event.key))return;event.preventDefault();const item=position(state.tables.find(t=>t.id===id),active.findIndex(t=>t.id===id)),step=event.shiftKey?25:5;setItem(id,{x:Math.max(0,Math.min(870,item.x+(event.key==='ArrowRight'?step:event.key==='ArrowLeft'?-step:0))),y:Math.max(0,Math.min(620,item.y+(event.key==='ArrowDown'?step:event.key==='ArrowUp'?-step:0)))});paintPosition(button,state.items.find(p=>p.table_id===id));persist();};
    });
  }
  window.floorHasUnsavedChanges=()=>state.dirty||state.saving;
  window.addEventListener('beforeunload',event=>{if(window.floorHasUnsavedChanges()){event.preventDefault();event.returnValue='';}});
  window.loadFloorPlan=async()=>{
    const root=$('floorContent');if(state.loaded===establishmentId&&(state.dirty||state.saving))return;
    const generation=++state.generation;root.innerHTML='<div class="skeleton" role="status">Preparando tu sala…</div>';
    try{
      const [tables,plan,features]=await Promise.all([supabaseClient.from('restaurant_tables').select('*').eq('establishment_id',establishmentId).order('name'),FGV.rpc('fgv_get_floor_plan'),FGV.rpc('fgv_get_features')]);if(tables.error)throw tables.error;if(generation!==state.generation)return;
      state={...state,loaded:establishmentId,tables:tables.data,items:plan.items,revision:plan.revision,editable:features.visual_floor_plan===true,dirty:false,failed:false,selected:null};
      // Deterministic initial placement is not persisted until the owner moves or edits a table.
      state.tables.filter(t=>t.active).forEach((table,index)=>{if(!state.items.some(p=>p.table_id===table.id))state.items.push(position(table,index));});
      root.innerHTML=`<div class="floor-toolbar"><div><span class="room-tab">Sala principal <span class="pill">V1</span></span><p id="floorCount" class="fgv-muted"></p></div><div class="floor-actions"><span id="floorStatus" class="floor-status" role="status">${plan.revision?'Guardado':'Listo para organizar'}</span><button id="floorRetry" class="quiet-button" hidden>Reintentar</button><button id="floorReload" class="quiet-button">Recargar</button><label class="edit-toggle"><input type="checkbox" id="floorEditMode" ${state.editable?'':'disabled'}>Editar plano</label><button id="floorAdd" class="primary-action" ${state.editable?'':'disabled'}>+ Añadir mesa</button></div></div>
      ${state.editable?'':'<p class="fgv-message">Puedes consultar la sala. La edición no está habilitada para este restaurante.</p>'}
      <div class="floor-workspace"><div class="floor-surface"><div class="floor-scroll"><div id="floorCanvas" class="floor-canvas" role="group" aria-label="Plano de Sala principal"></div></div><div class="floor-footnote"><span>PLANO DE DISTRIBUCIÓN</span><span>Las posiciones no representan disponibilidad.</span></div><div id="floorInactive"></div></div><aside id="floorEditor" class="surface floor-editor" aria-label="Editar mesa"></aside></div>
      <dialog id="floorAddDialog" class="app-dialog"><form id="floorAddForm"><div class="workspace-kicker">AMPLÍA TU SALA</div><h2>Nueva mesa</h2><p class="fgv-muted">Indica las plazas reales para calcular la disponibilidad.</p><label>Nombre<input name="name" required maxlength="80" placeholder="Mesa 16"></label><label>Plazas<input name="capacity" type="number" min="1" max="100" value="4" required></label><div class="fgv-toolbar"><button type="submit" class="primary-action">Crear mesa</button><button type="button" id="floorAddClose" class="quiet-button">Cancelar</button></div><p id="floorAddMessage" role="status"></p></form></dialog>`;
      $('floorEditMode').onchange=renderCanvas;$('floorRetry').onclick=persist;$('floorReload').onclick=()=>{if(state.saving)return;if(state.dirty&&!confirm('Hay posiciones sin guardar. ¿Descartar esos cambios y cargar el plano guardado?'))return;state.dirty=false;window.loadFloorPlan();};
      $('floorAdd').onclick=()=>{$('floorAddDialog').showModal();$('floorAddForm').elements.name.focus();};$('floorAddClose').onclick=()=>$('floorAddDialog').close();
      $('floorAddForm').onsubmit=async event=>{event.preventDefault();const form=event.currentTarget,button=form.querySelector('[type=submit]');button.disabled=true;try{const name=form.elements.name.value.trim(),capacity=Number(form.elements.capacity.value),id=await FGV.rpc('fgv_save_table',{p_table_id:null,p_name:name,p_capacity:capacity,p_active:true});state.tables.push({id,name,capacity,active:true});const i=state.tables.filter(t=>t.active).length-1;setItem(id,{x:Math.min(870,60+(i%5)*185),y:Math.min(620,70+Math.floor(i/5)*145),shape:capacity<=2?'round':capacity<=4?'square':'rectangle'});await persist();$('floorAddDialog').close();form.reset();renderCanvas();select(id);}catch(e){$('floorAddMessage').textContent=e.message||'No se pudo crear la mesa.';}finally{button.disabled=false;}};
      renderCanvas();editor();
    }catch(e){root.innerHTML=`<div class="fgv-message fgv-error" role="alert">${esc(e.message||'No se pudo cargar la sala.')}<p>Vuelve a abrir Sala para reintentar.</p></div>`;}
  };
})();
