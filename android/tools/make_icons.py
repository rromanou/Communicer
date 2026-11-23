#!/usr/bin/env python3
"""Convertit android/src/data/img.ico en icônes Android (mipmap-*, rondes, logo de démarrage). Usage : python3 android/tools/make_icons.py"""
import os,sys
from PIL import Image,ImageDraw
R=os.path.abspath(os.path.join(os.path.dirname(__file__),'..'))
ico=os.path.join(R,'src','data','img.ico')
if not os.path.exists(ico):sys.exit('img.ico introuvable : '+ico)
im=Image.open(ico)
sizes=im.ico.sizes() if hasattr(im,'ico') else {im.size}
im.size=max(sizes);im.load();src=im.convert('RGBA')
res=os.path.join(R,'app','src','main','res')
for d,px in {'mdpi':48,'hdpi':72,'xhdpi':96,'xxhdpi':144,'xxxhdpi':192}.items():
    o=os.path.join(res,'mipmap-'+d);os.makedirs(o,exist_ok=True)
    a=src.resize((px,px),Image.LANCZOS);a.save(os.path.join(o,'ic_launcher.png'))
    m=Image.new('L',(px*4,px*4),0);ImageDraw.Draw(m).ellipse((0,0,px*4-1,px*4-1),fill=255);m=m.resize((px,px),Image.LANCZOS)
    r=a.copy();r.putalpha(Image.composite(a.getchannel('A'),Image.new('L',(px,px),0),m));r.save(os.path.join(o,'ic_launcher_round.png'))
o=os.path.join(res,'drawable-nodpi');os.makedirs(o,exist_ok=True)
src.resize((512,512),Image.LANCZOS).save(os.path.join(o,'splash_logo.png'))
print('icônes générées depuis',ico,max(sizes))
