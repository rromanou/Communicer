/* phone-ui.js — adaptation tactile, chargé APRÈS les scripts communs (qui ne sont pas modifiés).
   1) textes pensés pour le clavier/la souris réécrits pour le toucher  2) réglages réservés à l'ordinateur masqués
   3) manette à l'écran (croix, actions, touches de modification) qui envoie des touches aux jeux. */
(function(){
'use strict';
var D=document;
/* ---------- 1) textes ---------- */
var RULES=[
 [/CTRL inhaler · ALT expirer · ALT \+ MAJ \+ n° trick · 1 à 4 vitesse · X avaler · Tab \+ # quitter/g,'Manette : INHALER · EXPIRER · tricks 1 à 4 · AVALER · Quitter'],
 [/Maintenir la tête \(ou CTRL\) pour inhaler · ALT pour expirer · clic droit maintenu : déplacer/g,'Maintenir la tête pour inhaler · bouton EXPIRER pour expirer · appui long : déplacer'],
 [/Maintenez votre tête, CTRL ou TAB pour inhaler ; relâchez dans la zone dorée, ALT pour expirer, ALT \+ MAJ \+ n° pour un trick\./g,'Maintenez votre tête pour inhaler ; relâchez dans la zone dorée, bouton EXPIRER pour expirer, puis un numéro de trick.'],
 [/CTRL ou TAB \(maintenir\)/g,'Maintenir la tête'],
 [/Inhaler : au choix CTRL, TAB ou les deux \(réglage ci-dessous\), ou maintenir la tête du personnage/g,'Inhaler : maintenir la tête du personnage (ou le bouton INHALER de la manette)'],
 [/Relâcher la touche/g,'Relâcher'],
 [/Personnage déplaçable \(clic droit maintenu, ou glisser\)/g,'Personnage déplaçable (glisser)'],
 [/Touchez, cliquez ou appuyez sur Espace pour battre des ailes/g,'Touchez pour battre des ailes'],
 [/Flèches ou ZQSD pour bouger, Espace pour tirer/g,'Joystick pour bouger, Tir pour tirer'],
 [/\(flèches, WASD ou ZQSD\)/g,'(joystick ou manette à l’écran)'],
 [/N’ouvrez pas la console\. N’utilisez pas Ctrl\+F, Ctrl\+C, Ctrl\+V, Ctrl\+A et ne sélectionnez pas de texte\./g,'Ne copiez pas de texte, ne prenez pas de capture et ne quittez pas l’application pendant l’épreuve.'],
 [/Ctrl\+F est interdit pendant la partie/g,'La recherche dans la page est interdite pendant la partie'],
 [/Collage refusé par le navigateur : utilisez Ctrl\+V/g,'Collage refusé : appuyez longuement dans le champ puis choisissez Coller'],
 [/clic droit maintenu/gi,'appui long'],[/clic droit/gi,'appui long'],
 [/\bCliquez\b/g,'Touchez'],[/\bcliquez\b/g,'touchez'],[/\bCliquer\b/g,'Toucher'],[/\bcliquer\b/g,'toucher'],
 [/\bsurvolez\b/gi,'touchez'],[/\bmolette\b/gi,'glisser']
];
function fix(s){var o=s;for(var i=0;i<RULES.length;i++)s=s.replace(RULES[i][0],RULES[i][1]);return s===o?null:s}
function walk(n){
  if(n.nodeType===3){var t=fix(n.nodeValue);if(t!==null)n.nodeValue=t;return}
  if(n.nodeType!==1||/^(SCRIPT|STYLE|TEXTAREA)$/.test(n.tagName))return;
  ['title','placeholder','aria-label'].forEach(function(a){var v=n.getAttribute&&n.getAttribute(a);if(v){var t=fix(v);if(t!==null)n.setAttribute(a,t)}});
  for(var c=n.firstChild;c;c=c.nextSibling)walk(c);
}
/* ---------- 2) réglages de l'ordinateur ---------- */
function hideDesktop(root){
  var labs=root.querySelectorAll?root.querySelectorAll('label'):[];
  for(var i=0;i<labs.length;i++){var l=labs[i],tx=l.textContent||'';
    if(/^Touche rapide/.test(tx)&&!l.dataset.ph){l.dataset.ph=1;var e=l;l.style.display='none';
      while((e=e.nextElementSibling)){e.style.display='none';if(e.querySelector&&e.querySelector('#pSave'))break}}
    else if(/^Touche pour inhaler/.test(tx)&&!l.dataset.ph){l.dataset.ph=1;l.style.display='none';if(l.nextElementSibling)l.nextElementSibling.style.display='none'}}
}
var q=false;
function pass(){q=false;walk(D.body);hideDesktop(D.body);pad.refresh()}
function later(){if(!q){q=true;requestAnimationFrame(pass)}}
/* ---------- 3) manette à l'écran ---------- */
var CODES={ArrowUp:38,ArrowDown:40,ArrowLeft:37,ArrowRight:39,' ':32,Control:17,Alt:18,Shift:16,Tab:9,x:88,X:88,Enter:13,Escape:27,'1':49,'2':50,'3':51,'4':52};
var CODE_NAME={ArrowUp:'ArrowUp',ArrowDown:'ArrowDown',ArrowLeft:'ArrowLeft',ArrowRight:'ArrowRight',' ':'Space',Control:'ControlLeft',Alt:'AltLeft',Shift:'ShiftLeft',Tab:'Tab',x:'KeyX',X:'KeyX',Enter:'Enter',Escape:'Escape','1':'Digit1','2':'Digit2','3':'Digit3','4':'Digit4'};
var mods={Control:false,Alt:false,Shift:false};
function send(type,key,rep){
  var e=new KeyboardEvent(type,{key:key,code:CODE_NAME[key]||'',bubbles:true,cancelable:true,repeat:!!rep,ctrlKey:mods.Control||key==='Control',altKey:mods.Alt||key==='Alt',shiftKey:mods.Shift||key==='Shift'});
  try{Object.defineProperty(e,'keyCode',{get:function(){return CODES[key]||0}});Object.defineProperty(e,'which',{get:function(){return CODES[key]||0}})}catch(x){}
  (D.body||D).dispatchEvent(e);
}
var pad={el:null,btn:null,open:false,
  build:function(){
    var b=D.createElement('button');b.id='phPadBtn';b.type='button';b.textContent='Manette';b.hidden=true;b.onclick=function(){pad.open=!pad.open;pad.refresh()};D.body.appendChild(b);pad.btn=b;
    var p=D.createElement('div');p.id='phPad';p.hidden=true;
    p.innerHTML='<div class="phDp"><i data-k="ArrowUp" class="u"></i><i data-k="ArrowLeft" class="l"></i><i data-k="ArrowRight" class="r"></i><i data-k="ArrowDown" class="d"></i></div>'
      +'<div class="phAc"><button data-k=" ">A</button><button data-k="Enter">B</button><button data-k="Escape">Retour</button></div>'
      +'<div class="phSm" hidden><button data-m="Control">INHALER</button><button data-m="Alt">EXPIRER</button><button data-m="Shift">MAJ</button><button data-k="x">AVALER</button><button data-k="1">1</button><button data-k="2">2</button><button data-k="3">3</button><button data-k="4">4</button></div>';
    D.body.appendChild(p);pad.el=p;
    var held={};
    function down(el,ev){var k=el.dataset.k,m=el.dataset.m;ev.preventDefault();
      if(m){mods[m]=!mods[m];el.classList.toggle('on',mods[m]);send(mods[m]?'keydown':'keyup',m);return}
      if(!k||held[k])return;held[k]=setTimeout(function(){held[k]=setInterval(function(){send('keydown',k,true)},60)},300);el.classList.add('on');send('keydown',k)}
    function up(el){var k=el.dataset.k;if(!k||!held[k])return;clearTimeout(held[k]);clearInterval(held[k]);held[k]=0;el.classList.remove('on');send('keyup',k)}
    p.addEventListener('pointerdown',function(e){var t=e.target.closest('[data-k],[data-m]');if(!t)return;try{t.setPointerCapture(e.pointerId)}catch(x){}down(t,e)});
    ['pointerup','pointercancel','lostpointercapture'].forEach(function(n){p.addEventListener(n,function(e){var t=e.target.closest('[data-k]');if(t)up(t)})});
    p.addEventListener('contextmenu',function(e){e.preventDefault()});
  },
  refresh:function(){
    if(!pad.el)return;
    var smoke=!!D.getElementById('fxHead'),game=smoke||!!(window.__phKeysWanted&&window.__phKeysWanted());
    pad.btn.hidden=!game;if(!game)pad.open=false;
    pad.el.hidden=!(game&&pad.open);pad.btn.classList.toggle('on',pad.open);
    pad.el.querySelector('.phSm').hidden=!smoke;
  }};
function init(){
  window.addEventListener('phkeys',function(){later()});
  pad.build();walk(D.body);hideDesktop(D.body);
  new MutationObserver(later).observe(D.body,{childList:true,subtree:true,characterData:true});
}
if(D.readyState==='loading')D.addEventListener('DOMContentLoaded',init);else init();
})();
