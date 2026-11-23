#!/usr/bin/env python3
"""Droits : chaque workflow déclare permissions:, pas de pull_request_target, pas de secret affiché ; manifeste Android = liste attendue."""
import os,re,sys,glob
R=os.path.abspath(os.path.join(os.path.dirname(__file__),'..','..'));bad=0
for f in sorted(glob.glob(R+'/.github/workflows/*.yml')):
    s=open(f,encoding='utf-8').read();n=os.path.relpath(f,R)
    if not re.search(r'^permissions:',s,re.M):print(f'::error file={n}::bloc permissions: absent (droits minimaux requis)');bad+=1
    if 'pull_request_target' in s:print(f'::error file={n}::pull_request_target interdit');bad+=1
    if re.search(r'echo\s+.*\$\{\{\s*secrets\.',s):print(f'::error file={n}::secret passé à echo');bad+=1
    if re.search(r'uses:\s*[\w./-]+@(main|master)\b',s):print(f'::error file={n}::action non épinglée (@main/@master)');bad+=1
OK={'INTERNET','ACCESS_NETWORK_STATE','CAMERA','RECORD_AUDIO','MODIFY_AUDIO_SETTINGS','ACCESS_FINE_LOCATION','ACCESS_COARSE_LOCATION','READ_MEDIA_IMAGES','READ_MEDIA_VIDEO','READ_MEDIA_AUDIO','READ_EXTERNAL_STORAGE','WRITE_EXTERNAL_STORAGE','WAKE_LOCK','VIBRATE','POST_NOTIFICATIONS'}
m=R+'/android/app/src/main/AndroidManifest.xml'
if os.path.exists(m):
    for p in re.findall(r'uses-permission[^>]*android:name="android\.permission\.(\w+)"',open(m).read()):
        if p not in OK:print(f'::error file=android/app/src/main/AndroidManifest.xml::permission non prévue : {p}');bad+=1
print('terminé,',bad,'problème(s)');sys.exit(1 if bad else 0)
