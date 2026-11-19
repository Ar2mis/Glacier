#!/usr/bin/env python3
"""Portable structural guard, NOT evidence of signing, sandbox execution or review."""
from pathlib import Path
import json
import plistlib
import struct
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
def check():
    subprocess.run([sys.executable,str(ROOT/'scripts/generate_xcode_project.py'),'--check'],check=True)
    subprocess.run([sys.executable,str(ROOT/'scripts/render_support_site.py'),'--check'],check=True)
    ent=plistlib.loads((ROOT/'Config/GlacierMac.entitlements').read_bytes())
    required={'com.apple.security.app-sandbox','com.apple.security.device.audio-input','com.apple.security.device.microphone','com.apple.security.network.client','com.apple.security.files.user-selected.read-write','com.apple.security.files.bookmarks.app-scope'}
    assert set(ent)==required and all(ent.values()), 'Sandbox entitlement set changed; review explicitly'
    cfg=(ROOT/'Config/MacStore.xcconfig').read_text()
    assert 'APP_STORE' in cfg and 'ENABLE_APP_SANDBOX = YES' in cfg and 'GLACIER_DISTRIBUTION = store' in cfg
    assert '.dev' in (ROOT/'Config/MacDev.xcconfig').read_text()
    updater=(ROOT/'scripts/sync_and_build_local.sh').read_text()
    assert 'INSTALLED="/Applications/Glacier Dev.app"' in updater
    assert 'INSTALLED=/Applications/Glacier.app' not in updater
    assert '--force' not in updater.replace('worktree remove --force','')
    manifest=plistlib.loads((ROOT/'Resources/PrivacyInfo.xcprivacy').read_bytes())
    assert manifest['NSPrivacyTracking'] is False and manifest['NSPrivacyTrackingDomains']==[]
    assert any(x['NSPrivacyAccessedAPIType']=='NSPrivacyAccessedAPICategoryUserDefaults' and 'CA92.1' in x['NSPrivacyAccessedAPITypeReasons'] for x in manifest['NSPrivacyAccessedAPITypes'])
    asset=ROOT/'Resources/Assets.xcassets/AppIcon.appiconset'
    images=json.loads((asset/'Contents.json').read_text())['images']
    assert len([i for i in images if i['idiom']=='mac'])==10
    for item in images:
        data=(asset/item['filename']).read_bytes()
        assert data[:8]==b'\x89PNG\r\n\x1a\n'
        w,h=struct.unpack('>II',data[16:24]); size=float(item['size'].split('x')[0])*int(item['scale'][0])
        assert w==h==size, item['filename']
        if item['idiom']!='mac': assert data[25]==2, 'iOS icons must be RGB without alpha'
    assert any(i['idiom']=='ios-marketing' and i['size']=='1024x1024' for i in images)
    source=(ROOT/'scripts/make-icon.swift').read_text()
    assert 'Apple Color Emoji' not in source and 'NSAttributedString' not in source
    for platform in ['Mac','iOS']:
        info=plistlib.loads((ROOT/f'Config/{platform}-Info.plist').read_bytes())
        assert info['NSMicrophoneUsageDescription'] and info['NSSpeechRecognitionUsageDescription']
    print('PASS: store target, sandbox configuration, isolated updater, privacy metadata and icon dimensions (portable only)')
if __name__=='__main__': check()
