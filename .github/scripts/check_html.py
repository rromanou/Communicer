#!/usr/bin/env python3
"""Vérifie les pages HTML : doctype, lang, title, balises équilibrées, et que chaque src/href local existe."""
import os,re,sys
from html.parser import HTMLParser
R=os.path.abspath(os.path.join(os.path.dirname(__file__),'..','..'))
VOID={'meta','link','img','input','br','hr','source','track','area','base','col','embed','wbr','param'}
class P(HTMLParser):
    def __init__(s):super().__init__();s.st=[];s.refs=[];s.err=[];s.title=False;s.lang=False;s.doctype=False
    def handle_decl(s,d):
        if d.lower().startswith('doctype'):s.doctype=True
    def handle_starttag(s,t,a):
        a=dict(a)
        if t=='html' and a.get('lang'):s.lang=True
        if t=='title':s.title=True
        for k in ('src','href'):
            v=a.get(k)
            if v and not re.match(r'(https?:|data:|mailto:|#|javascript:|blob:)',v):s.refs.append(v.split('#')[0].split('?')[0])
        if t not in VOID:s.st.append((t,s.getpos()[0]))
    def handle_endtag(s,t):
        if t in VOID:return
        if s.st and s.st[-1][0]==t:s.st.pop()
        else:s.err.append(f'ligne {s.getpos()[0]} : </{t}> inattendu (ouvert : {s.st[-1] if s.st else None})')
bad=0
for root in ('app','phone'):
    d=os.path.join(R,root)
    if not os.path.isdir(d):continue
    for f in sorted(os.listdir(d)):
        if not f.endswith('.html'):continue
        p=os.path.join(d,f);s=open(p,encoding='utf-8').read();h=P();h.feed(s)
        e=list(h.err)+[f'balise non fermée <{t}> ligne {n}' for t,n in h.st]
        if not h.doctype:e.append('doctype absent')
        if not h.lang:e.append('attribut lang absent')
        if not h.title:e.append('title absent')
        base=R  # les pages sont servies à plat : les chemins relatifs partent de la racine du site
        for r in h.refs:
            cands=[os.path.join(R,r.lstrip('/')),os.path.join(d,r)]
            if root=='phone':cands.append(os.path.join(R,'phone',r))
            if not any(os.path.exists(c) for c in cands) and r not in ('sw.js',) :e.append('ressource introuvable : '+r)
        for x in e:print(f'::error file={root}/{f}::{x}');bad+=1
        print(f'{root}/{f} : {"OK" if not e else str(len(e))+" problème(s)"}')
sys.exit(1 if bad else 0)
