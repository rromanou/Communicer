var LOOK_C={vert:['#16a34a','#ecf7ef'],bleu:null,jaune:['#ca8a04','#fbf7e4'],rouge:['#e5484d','#fbeeee'],orange:['#f97316','#fcf1e7']};
function lookGet(){try{return JSON.parse(localStorage.getItem('cm_look')||'{}')}catch(e){return{}}}
function lookApply(){var l=lookGet(),m=l.mode||'light',d=m==='dark'||(m==='auto'&&window.matchMedia&&matchMedia('(prefers-color-scheme:dark)').matches),r=document.documentElement,c=LOOK_C[l.color];
 r.dataset.mode=d?'dark':'light';
 ['--accent','--bg','--bg2','--card2'].forEach(function(k){r.style.removeProperty(k)});
 if(c){r.style.setProperty('--accent',c[0]);r.style.setProperty('--bg',c[1]);r.style.setProperty('--bg2',c[1])}}
lookApply();
try{matchMedia('(prefers-color-scheme:dark)').addEventListener('change',lookApply)}catch(e){}
