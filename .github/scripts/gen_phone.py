#!/usr/bin/env python3
"""Génère phone/index.html à partir de app/index.html : mêmes scripts, entête et habillage adaptés au téléphone."""
import os,re
R=os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..')
s=open(os.path.join(R,'app','index.html'),encoding='utf-8').read()
def rep(a,b,n=1):
    global s
    assert s.count(a)>=1,a[:50];s=s.replace(a,b,n)
rep('<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">',
    '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content">\n'
    '<meta name="theme-color" content="#2f6bff">\n<meta name="mobile-web-app-capable" content="yes">\n<meta name="format-detection" content="telephone=no">\n'
    '<base href="../">\n<script>window.__PHONE=1;window.__PBASE=location.pathname.replace(/\\/phone(\\/[^\\/]*)?$/,"").replace(/\\/+$/,"")</script>\n'
    '<script src="phone/phone.js"></script>')
s=re.sub(r'<!--DEVICE-->\n<script>.*?</script>\n','',s,flags=re.S)
rep('<link rel="stylesheet" href="style/style.css">','<link rel="stylesheet" href="style/style.css">\n<link rel="stylesheet" href="phone/phone.css">')
rep('<body>','<body>\n<div id="splash" aria-hidden="true"><img src="assets/images/icon.svg" alt="" width="112" height="112"><b>Communicer</b><i></i></div>')
rep('<script src="scripts/app.js"></script>','<script src="scripts/app.js"></script>\n<script src="phone/phone-ui.js"></script>')
open(os.path.join(R,'phone','index.html'),'w',encoding='utf-8').write(s)
print('phone ok')
