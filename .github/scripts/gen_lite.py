#!/usr/bin/env python3
"""Génère app/communicer-lite.html à partir de app/index.html (même code, drapeau Lite activé)."""
import os,re
R=os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..')
s=open(os.path.join(R,'app','index.html'),encoding='utf-8').read()
L=s.split('\n')
L.insert(3,'<script>window.__LITE=1</script>')
s='\n'.join(L).replace('<title>Communicer!</title>','<title>Communicer Lite</title>',1)
open(os.path.join(R,'app','communicer-lite.html'),'w',encoding='utf-8').write(s)
print('lite ok')
