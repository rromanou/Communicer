/* Communicer! — bots hors-ligne pour les jeux en équipe.
   Téléchargé avec les jeux (option « Jouer hors ligne »). Tout reste sur l'appareil. */
(function(){
'use strict';
const R=n=>Math.floor(Math.random()*n);
const pk=a=>a[R(a.length)];
const NAMES=['Alex','Sam','Charlie','Robin','Morgan','Jules','Camille'];
const IDS=['tag','ttt','rps','bj','uno','dam','chess','ludo','back','hang','poker','c4','rev','yams'];

function make(M){
  const P={};
  /* Chaque politique renvoie une liste d'actions candidates (la première acceptée est jouée). */

  P.ttt=(st,hp,b)=>{
    if(st.w||st.sym[b]!==st.t)return null;
    const me=st.sym[b],op=me==='X'?'O':'X',L=M.TTT.LINES,B=st.b;
    const need=(s)=>{for(const l of L){const v=l.map(i=>B[i]);if(v.filter(x=>x===s).length===2&&v.includes(''))return l[v.indexOf('')]}return -1};
    let i=need(me);if(i<0)i=need(op);
    if(i<0&&!B[4])i=4;
    if(i<0){const e=B.map((x,k)=>x?-1:k).filter(k=>k>=0);i=pk(e)}
    return [{t:'play',i}];
  };

  P.rps=(st,hp,b)=>{
    if(st.win)return null;
    if(st.last)return [{t:'next',r:st.round}];
    if(st.got[b])return null;
    return [{t:'pick',c:pk(['r','p','s'])}];
  };

  P.bj=(st,hp,b)=>{
    if(st.over)return null;
    if(st.ph==='done')return [{t:'next'}];
    if(st.ph!=='play'||st.pl[st.turn]!==b)return null;
    const t=M.BJ.total(st.hands[b]);
    return [{t:t<16||(t===16&&R(3)===0)?'hit':'stand'},{t:'stand'}];
  };

  P.uno=(st,hp,b)=>{
    if(st.over)return null;
    const U=M.UNO,hand=(hp.hands&&hp.hands[b])||[];
    if(st.n[b]===1&&!st.uno[b]&&R(4)>0)return [{t:'uno'}];
    if(st.pl[st.t]!==b)return null;
    const best=cs=>{
      const nw=cs.filter(c=>!U.wild(c)),w=cs.filter(c=>U.wild(c));
      const c=nw.length?pk(nw):w[0];
      const cnt={};hand.forEach(x=>{if(!U.wild(x))cnt[x[0]]=(cnt[x[0]]||0)+1});
      const col=Object.keys(cnt).sort((x,y)=>cnt[y]-cnt[x])[0]||pk(U.COLS);
      return {t:'play',c,col};
    };
    if(st.drew)return U.playable(st,st.drew)?[{t:'play',c:st.drew,col:best([st.drew]).col},{t:'pass'}]:[{t:'pass'}];
    const ok=hand.filter(c=>U.playable(st,c));
    if(ok.length)return [best(ok)];
    return [{t:'draw'}];
  };

  P.dam=(st,hp,b)=>{
    if(st.win||st.draw||st.pl[st.t]!==b)return null;
    const ms=M.DAM.legal(st);if(!ms.length)return null;
    const sc=m=>m.caps.length*10+(M.DAM.isK(st.b[m.f])?0:((st.t===0?(st.n-1-((m.path[m.path.length-1]/st.n)|0)):((m.path[m.path.length-1]/st.n)|0))))+R(3);
    ms.sort((x,y)=>sc(y)-sc(x));
    return ms.slice(0,3).map(m=>({t:'move',f:m.f,path:m.path}));
  };

  const CV={p:1,n:3,b:3,r:5,q:9,k:0};
  P.chess=(st,hp,b)=>{
    const col=st.pl.w===b?'w':st.pl.b===b?'b':null;
    if(!col||st.over||st.pos.t!==col)return null;
    const ms=M.CHESS.legal(st.pos);if(!ms.length)return null;
    const val=m=>{const x=st.pos.b[m.t];let v=x?(CV[String(x).toLowerCase()]||0)*10:0;
      if(m.p)v+=80;if(m.fl==='ep')v+=10;
      try{const n=M.CHESS.apply(st.pos,m);if(M.CHESS.inCheck(n))v+=6;
        const rep=M.CHESS.legal(n);let worst=0;
        for(const r of rep){const y=n.b[r.t];if(y&&r.t===m.t)worst=Math.max(worst,(CV[String(y).toLowerCase()]||0)*10)}
        v-=worst>0?Math.min(worst,(CV[String(st.pos.b[m.f]).toLowerCase()]||0)*10):0}catch(_){}
      return v+R(5)};
    const sc=ms.map(m=>[val(m),m]).sort((a,c)=>c[0]-a[0]);
    return sc.slice(0,4).map(([,m])=>({t:'move',f:m.f,to:m.t,p:m.p||undefined}));
  };

  P.ludo=(st,hp,b)=>{
    if(st.win||st.pl[st.t]!==b)return null;
    if(st.d===null)return [{t:'roll'}];
    const c=(st.can||[]).slice();if(!c.length)return null;
    const pos=i=>st.pc[b][i];
    c.sort((x,y)=>(pos(y)+(pos(y)===-1?60:0)*0)-(pos(x))+R(3)-1);
    const first=c.find(i=>pos(i)===-1&&st.d===6);
    return (first!==undefined?[first].concat(c):c).map(p=>({t:'move',p}));
  };

  P.back=(st,hp,b)=>{
    if(st.win||st.pl[st.t==='w'?0:1]!==b)return null;
    if(!st.rem.length)return [{t:'roll'}];
    const ms=M.BACK.legal(st);if(!ms.length)return null;
    const sc=m=>(m.hit?8:0)+(m.to===undefined?0:0)+R(6);
    ms.sort((x,y)=>sc(y)-sc(x));
    return ms.slice(0,4).map(m=>({t:'move',f:m.f,d:m.d,to:m.to}));
  };

  const FREQ='ESAINTRULODCMPVQGFBHJXYZKW';
  P.hang=(st,hp,b)=>{
    if(st.over)return null;
    if(st.ph==='end')return [{t:'next'}];
    if(st.ph==='set'&&st.setter===b){
      const w=(M.MOTS_FR&&M.MOTS_FR.length?pk(M.MOTS_FR):'COMMUNICATION');
      return [{t:'word',w:String(w)}];
    }
    if(st.ph==='guess'&&M.HANG.turn(st)===b){
      const l=FREQ.split('').filter(x=>!st.used.includes(x));
      const k=Math.min(l.length-1,R(3));
      return l.length?[{t:'guess',l:l[k]}]:null;
    }
    return null;
  };

  P.poker=(st,hp,b)=>{
    if(st.over)return null;
    if(st.ph==='show')return [{t:'next'}];
    const i=st.pl.indexOf(b);if(i<0||st.turn!==i)return null;
    const h=(hp.holes&&hp.holes[b])||[],RK='23456789TJQKA';
    const v=h.map(c=>RK.indexOf(c[0])+2);
    let s=v.length?(Math.max(...v)+Math.min(...v))/2:8;
    if(v.length===2&&v[0]===v[1])s+=8;
    if(h.length===2&&h[0][1]===h[1][1])s+=2;
    if(st.board&&st.board.length&&h.length){
      try{const cs=h.concat(st.board);const r=M.POKER.best?M.POKER.best(cs):null;
        const cat=Array.isArray(r)?(Array.isArray(r[0])?r[0][0]:r[0]):0;if(typeof cat==='number')s+=cat*4}catch(_){}
    }
    const toCall=st.cur-st.bet[b],ch=st.chips[b];
    s+=R(5)-2;
    if(toCall<=0){
      if(s>=17&&R(2)===0)return [{t:'raise',to:st.cur+Math.max(st.minr,st.bb)},{t:'check'}];
      return [{t:'check'}];
    }
    const big=toCall>ch*0.35;
    if(s>=19&&R(3)===0)return [{t:'raise',to:st.cur+st.minr},{t:'call'},{t:'fold'}];
    if(s>=(big?15:10))return [{t:'call'},{t:'fold'}];
    return [{t:'fold'},{t:'call'}];
  };


  P.c4=(st,hp,b)=>{
    if(st.w||st.pl[st.t]!==b)return null;
    const C=M.C4,me=st.t+1,op=3-me,sc=[];
    for(let c=0;c<7;c++){
      const i=C.drop(st.b,c);if(i<0)continue;let v=3-Math.abs(3-c)+Math.random();
      const t=st.b.slice();t[i]=me;if(C.win(t,i)){v+=1000}
      else{
        const t2=st.b.slice();t2[i]=op;if(C.win(t2,i))v+=500;
        const j=i-7;if(j>=0){const t3=t.slice();t3[j]=op;if(C.win(t3,j))v-=400;const t4=t.slice();t4[j]=me;if(C.win(t4,j))v+=2}
      }
      sc.push([v,c]);
    }
    sc.sort((a,c)=>c[0]-a[0]);
    return sc.map(x=>({t:'drop',c:x[1]}));
  };

  P.rev=(st,hp,b)=>{
    if(st.w||st.pl[st.t]!==b)return null;
    const ms=M.REV.moves(st.b,st.t+1);if(!ms.length)return null;
    const corner=i=>i===0||i===7||i===56||i===63;
    const nearC=i=>[1,8,9,6,14,15,48,49,57,54,55,62].includes(i);
    const edge=i=>{const r=(i/8)|0,c=i%8;return r===0||r===7||c===0||c===7};
    const val=([i,f])=>f.length+(corner(i)?25:0)-(nearC(i)?7:0)+(edge(i)?3:0)+Math.random()*2;
    return ms.map(m=>[val(m),m[0]]).sort((a,c)=>c[0]-a[0]).slice(0,4).map(x=>({t:'put',i:x[1]}));
  };

  P.yams=(st,hp,b)=>{
    if(st.over||st.pl[st.t]!==b)return null;
    if(st.rolls===0)return [{t:'roll'}];
    const Y=M.YAMS,d=st.dice,open=Y.CATS.filter(c=>st.sheet[b][c]===undefined);
    const best=open.map(c=>[Y.score(c,d)-Y.EXP[c],c]).sort((x,y)=>y[0]-x[0])[0];
    const sc=Y.score(best[1],d);
    const big=['yams','gstr','pstr','full'].includes(best[1])&&sc>=25;
    if(big||st.rolls>=3)return [{t:'score',c:best[1]}];
    const cnt={};d.forEach(v=>cnt[v]=(cnt[v]||0)+1);
    const tv=+Object.keys(cnt).sort((x,y)=>cnt[y]-cnt[x]||y-x)[0];
    const h=d.map(v=>v===tv);
    if(st.held.some((x,i)=>x!==h[i]))return [{t:'holds',h}];
    return [{t:'roll'}];
  };

  return {pick(id,st,hp,bot){const f=P[id];return f?f(st,hp,bot):null}};
}

window.OFFBOT={v:1,ids:IDS,names:NAMES,make};
})();
