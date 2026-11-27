/* phone.js — adaptation téléphone de Communicer! (chargé AVANT les scripts communs, qui restent identiques à la version ordinateur).
   Rôle : adresses internes qui restent dans /phone/, liens « # » (balise <base>), écran de démarrage, orientation,
   pleine page, écran maintenu allumé, pont avec l'application Android (window.CMApp, absent dans un navigateur). */
(function(){
'use strict';
var D=document,W=window,APP=W.CMApp||null,ROOT=D.documentElement;
/* la version téléphone n'est pas accessible depuis un ordinateur : retour à la version ordinateur */
(function(){var ua=navigator.userAgent||'',s=Math.min(screen.width,screen.height),coarse=matchMedia('(pointer:coarse)').matches&&!matchMedia('(any-pointer:fine)').matches;
  var phone=/CommunicerApp/.test(ua)||(s<=820&&(coarse||/Android.+Mobile|iPhone|iPod/i.test(ua)));
  if(!phone){ROOT.style.display='none';location.replace(location.pathname.replace(/\/phone(\/[^\/]*)?$/,'/')+location.search+location.hash);throw new Error('phone-only')}})();
W.__PHONE=1;
/* 1) adresses : le site ordinateur utilise /@pseudo ; ici on reste dans /phone/ avec ?u=pseudo */
var PATH=location.pathname;
function fix(u){if(typeof u!=='string')return u;var m=u.match(/\/@([^\/?#]+)(?:[?#].*)?$/);if(m)return PATH+'?u='+m[1];if(/^\/?$/.test(u)||u===W.__PBASE+'/'||u===W.__PBASE)return PATH;return u}
['pushState','replaceState'].forEach(function(k){var o=history[k].bind(history);history[k]=function(s,t,u){return o(s,t,u==null?u:fix(u))}});
/* 2) liens "#" : sans cela <base href="../"> renverrait à la page ordinateur */
D.addEventListener('click',function(e){var a=e.target.closest&&e.target.closest('a[href]');if(a&&a.getAttribute('href').charAt(0)==='#')e.preventDefault()},true);
/* 2b) champs de saisie : le menu de copier/coller du système (appui long) remplace celui du site, pensé pour la souris */
D.addEventListener('contextmenu',function(e){var t=e.target;if(t&&t.closest&&t.closest('textarea,input,[contenteditable=true]'))e.stopImmediatePropagation()},true);
/* 2c) la manette n'apparaît que lorsque le site demande le clavier : un jeu qui enregistre des touches (keydown/keyup sur la fenêtre ou le document) après le chargement */
(function(){
  var booted=false,live=[];
  W.addEventListener('load',function(){booted=true});
  var add=EventTarget.prototype.addEventListener,rem=EventTarget.prototype.removeEventListener;
  function isG(t){return t===W||t===D||t===D.body||t===D.documentElement}
  function cap(o){return o===true||!!(o&&o.capture)}
  function ping(){try{W.dispatchEvent(new Event('phkeys'))}catch(e){}}
  EventTarget.prototype.addEventListener=function(type,fn,opt){
    if(booted&&(type==='keydown'||type==='keyup')&&isG(this)&&fn){live.push({t:this,k:type,f:fn,c:cap(opt)});ping();
      if(opt&&opt.once){var self=this,o=fn;arguments[1]=function(){drop(self,type,o,cap(opt));return typeof o==='function'?o.apply(this,arguments):o.handleEvent(arguments[0])}}}
    return add.apply(this,arguments)};
  function drop(t,k,f,c){for(var i=live.length-1;i>=0;i--){var x=live[i];if(x.t===t&&x.k===k&&x.f===f&&x.c===c){live.splice(i,1);break}}ping()}
  EventTarget.prototype.removeEventListener=function(type,fn,opt){if((type==='keydown'||type==='keyup')&&isG(this))drop(this,type,fn,cap(opt));return rem.apply(this,arguments)};
  W.__phKeysWanted=function(){return live.length>0};
})();
/* 3) orientation + zone utile : classes et variables CSS */
function layout(){
  var vv=W.visualViewport,w=vv?vv.width:W.innerWidth,h=vv?vv.height:W.innerHeight,land=w>h;
  ROOT.classList.toggle('ph-land',land);ROOT.classList.toggle('ph-port',!land);
  ROOT.classList.toggle('ph-short',h<430);
  ROOT.style.setProperty('--vh',h*.01+'px');
  ROOT.style.setProperty('--vw',w*.01+'px');
}
['resize','orientationchange'].forEach(function(ev){W.addEventListener(ev,layout)});
if(W.visualViewport)W.visualViewport.addEventListener('resize',layout);layout();
/* 4) écran de démarrage : disparaît quand l'écran de connexion ou l'application est affiché */
function splashOff(){var s=D.getElementById('splash');if(!s||s._off)return;s._off=1;s.classList.add('off');setTimeout(function(){s.remove()},450);try{APP&&APP.splashDone&&APP.splashDone()}catch(e){}}
D.addEventListener('DOMContentLoaded',function(){
  var els=['auth','app'].map(function(i){return D.getElementById(i)}).filter(Boolean);
  var chk=function(){if(els.some(function(e){return !e.hidden}))setTimeout(splashOff,350)};
  els.forEach(function(e){new MutationObserver(chk).observe(e,{attributes:true,attributeFilter:['hidden']})});chk();
  setTimeout(splashOff,9000);
});
/* 5) écran maintenu allumé : vidéo, image, vocal, appel, jeu (sinon l'écran peut s'éteindre normalement) */
var awake=null,wl=null;
function playing(sel){var l=D.querySelectorAll(sel);for(var i=0;i<l.length;i++){var m=l[i];if(!m.paused&&!m.ended&&m.readyState>2)return true}return false}
function need(){
  if(playing('video,audio'))return 'média';
  if(D.getElementById('callScreen')||D.querySelector('.full'))return 'appel ou jeu';
  var r=D.getElementById('recRow');if(r&&!r.hidden)return 'vocal';
  if(D.querySelector('.modal-back img,.lightbox,.imgview,.viewer'))return 'image';
  return null;
}
async function setAwake(on){
  if(on===awake)return;awake=on;
  try{APP&&APP.keepAwake&&APP.keepAwake(!!on)}catch(e){}
  try{if('wakeLock' in navigator){if(on){wl=await navigator.wakeLock.request('screen')}else if(wl){await wl.release();wl=null}}}catch(e){}
}
var lastBg='';
setInterval(function(){setAwake(!!need());
  try{if(APP&&APP.theme){var c='',qs=['.room','#chatBox .hd','#side .hd','#side','#app','body','html'];
    for(var i=0;i<qs.length&&!c;i++){var el=D.querySelector(qs[i]);if(!el)continue;var v=getComputedStyle(el).backgroundColor,mm=v&&v.match(/[\d.]+/g);if(mm&&(mm.length<4||+mm[3]>0.5))c=v}
    if(c&&c!==lastBg){lastBg=c;var m=c.match(/\d+/g);if(m)APP.theme('#'+m.slice(0,3).map(function(x){return('0'+(+x).toString(16)).slice(-2)}).join(''))}}}catch(e){}
},1500);
D.addEventListener('visibilitychange',function(){if(!D.hidden&&awake){awake=null;setAwake(!!need())}});
/* 6) plein écran vidéo (la barre système se masque côté application) */
D.addEventListener('fullscreenchange',function(){try{APP&&APP.fullscreen&&APP.fullscreen(!!D.fullscreenElement)}catch(e){}});
/* 7) pas de zoom par double-tap ni de menu de sélection sur l'interface */
D.addEventListener('gesturestart',function(e){e.preventDefault()});
})();
