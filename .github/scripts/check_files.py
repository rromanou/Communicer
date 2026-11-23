#!/usr/bin/env python3
"""Taille des fichiers + doublons. Usage : check_files.py size|dup"""
import os,sys,hashlib,collections
R=os.path.abspath(os.path.join(os.path.dirname(__file__),'..','..'));mode=sys.argv[1]
SKIP={'.git','node_modules','_site','.gradle','build'}
fs=[]
for d,ds,ns in os.walk(R):
    ds[:]=[x for x in ds if x not in SKIP]
    for n in ns:fs.append(os.path.join(d,n))
bad=0
if mode=='size':
    for f in fs:
        z=os.path.getsize(f);r=os.path.relpath(f,R)
        if z>25*2**20:print(f'::error file={r}::{z/2**20:.1f} Mo (> 25 Mo)');bad+=1
        elif z>2*2**20:print(f'::warning file={r}::{z/2**20:.1f} Mo (> 2 Mo)')
else:
    h=collections.defaultdict(list)
    for f in fs:
        if os.path.getsize(f)<64 or os.path.basename(f) in('.gitkeep',):continue
        h[hashlib.sha256(open(f,'rb').read()).hexdigest()].append(os.path.relpath(f,R))
    for k,v in h.items():
        if len(v)>1:print(f'::error::fichiers identiques : {", ".join(v)}');bad+=1
print('terminé,',bad,'problème(s)');sys.exit(1 if bad else 0)
