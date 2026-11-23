#!/usr/bin/env python3
"""Cohérence SQL : exe.txt (ordre d'exécution) ↔ fichiers, dépendances annoncées, sécurité de base."""
import os,re,sys
R=os.path.abspath(os.path.join(os.path.dirname(__file__),'..','..'))
D=os.path.join(R,'database');mode=sys.argv[1] if len(sys.argv)>1 else 'all'
err=0;warn=0
def E(m,f=''):
    global err;err+=1;print(f'::error file={f}::{m}')
def W(m,f=''):
    global warn;warn+=1;print(f'::warning file={f}::{m}')
lst=[l.strip() for l in open(os.path.join(D,'exe.txt'),encoding='utf-8') if l.strip() and not l.startswith('#')]
files=sorted('sql/'+f for f in os.listdir(os.path.join(D,'sql')) if f.endswith('.sql'))
if mode in('all','consistency'):
    for f in lst:
        if not os.path.exists(os.path.join(D,f)):E('listé dans exe.txt mais absent',f)
    if len(set(lst))!=len(lst):E('doublon dans exe.txt','database/exe.txt')
    commented=set(re.findall(r'#.*?(patch_[a-z0-9_]+\.sql)',open(os.path.join(D,'exe.txt'),encoding='utf-8').read()))
    for f in files:
        if f not in lst and os.path.basename(f) not in commented:E('fichier SQL absent de exe.txt',f)
    pos={os.path.basename(f):i for i,f in enumerate(lst)}
    for f in lst:
        p=os.path.join(D,f)
        if not os.path.exists(p):continue
        head='\n'.join(open(p,encoding='utf-8').read().split('\n')[:8])
        for m in re.finditer(r'(?:Dépend de|après|APRÈS|Dépend)\s+((?:patch_[a-z0-9_]+(?:\.sql)?(?:[ ,/]+|\s+et\s+)?)+)',head):
            for d in re.findall(r'patch_[a-z0-9_]+',m.group(1)):
                d+='.sql'
                if d in pos and pos[d]>pos[os.path.basename(f)]:E(f'dépendance {d} exécutée APRÈS ce fichier dans exe.txt',f)
if mode in('all','lint'):
    for f in files:
        s=open(os.path.join(D,f),encoding='utf-8').read()
        if s.count('$$')%2:E('nombre impair de $$ (bloc non fermé)',f)
        t=re.sub(r"--[^\n]*","",re.sub(r"\$([a-z]*)\$.*?\$\1\$","''",s,flags=re.S));t=re.sub(r"'(?:[^']|'')*'","''",t)
        if t.count('(')!=t.count(')'):W('parenthèses déséquilibrées (heuristique)',f)
        for m in re.finditer(r'\b(drop\s+table|drop\s+column|truncate\s+table)\b',t,re.I):
            ln=t[:m.start()].count('\n')+1
            W(f'instruction destructive "{m.group(1)}" (ligne approx. {ln}) : les patchs doivent rester additifs',f)
if mode in('all','security'):
    for f in files:
        s=open(os.path.join(D,f),encoding='utf-8').read()
        if re.search(r'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}',s):E('jeton JWT en clair',f)
        if re.search(r'sk_(live|test)_[A-Za-z0-9]{10,}|whsec_[A-Za-z0-9]{10,}',s):E('clé Stripe en clair',f)
        for m in re.finditer(r'create\s+(?:or\s+replace\s+)?function\s+([\w.]+)\s*\((.*?)\$(\w*)\$',s,re.I|re.S):
            hdr=m.group(0)
            if re.search(r'security\s+definer',hdr,re.I) and not re.search(r'set\s+search_path',hdr,re.I):
                W(f'fonction SECURITY DEFINER sans search_path : {m.group(1)}',f)
print(f'sql[{mode}] : {err} erreur(s), {warn} avertissement(s)')
sys.exit(1 if err else 0)
