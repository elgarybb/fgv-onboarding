/* Shared appearance preference. No account or session data is read here. */
(() => {
  const key='fgv-appearance',system=window.matchMedia('(prefers-color-scheme: dark)');
  let preference;try{preference=localStorage.getItem(key);}catch{}
  const initial=preference==='light'||preference==='dark'?preference:(system.matches?'dark':'light');
  document.documentElement.dataset.theme=initial;
  let button;
  function apply(theme){document.documentElement.dataset.theme=theme;if(button){const dark=theme==='dark';button.innerHTML=`<span aria-hidden="true">${dark?'☾':'☀'}</span><span>${dark?'Oscuro':'Claro'}</span>`;button.setAttribute('aria-label',`Cambiar a modo ${dark?'claro':'oscuro'}`);button.title=`Cambiar a modo ${dark?'claro':'oscuro'}`;}}
  system.addEventListener('change',event=>{if(!preference)apply(event.matches?'dark':'light');});
  window.addEventListener('storage',event=>{if(event.key===key){preference=event.newValue;apply(preference==='light'||preference==='dark'?preference:(system.matches?'dark':'light'));}});
  document.addEventListener('DOMContentLoaded',()=>{button=document.createElement('button');button.type='button';button.className='theme-toggle';button.addEventListener('click',()=>{preference=document.documentElement.dataset.theme==='dark'?'light':'dark';try{localStorage.setItem(key,preference);}catch{}apply(preference);});const header=document.querySelector('.workspace-page header');if(header){header.insertBefore(button,header.querySelector('.logout-button'));}else{const bar=document.createElement('div');bar.className='entry-theme-bar';bar.append(button);document.querySelector('.entry-main')?.prepend(bar);}apply(document.documentElement.dataset.theme);});
})();
