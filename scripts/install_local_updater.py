#!/usr/bin/env python3
"""Install a per-user LaunchAgent; no root privileges or embedded API credentials."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import os
ROOT = Path(__file__).resolve().parents[1]
STATE = Path.home() / 'Library/Application Support/Glacier/Updater'
LABEL = 'com.ar2mis.glacier.local-updater'
STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
# Bootstrap outside Documents so launchd can start and log even if macOS denies
# Documents access. The source checkout is never moved or duplicated silently.
helper = STATE / 'sync_and_build_local.sh'
shutil.copy2(ROOT / 'scripts/sync_and_build_local.sh', helper)
plist = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
plist.parent.mkdir(parents=True, exist_ok=True)
settings = {'Label': LABEL, 'ProgramArguments': ['/bin/bash', str(helper), '--repo', str(ROOT), '--state', str(STATE), '--scheduled'],
            'StartCalendarInterval': {'Hour': 13, 'Minute': 0}, 'StartInterval': 3600, 'RunAtLoad': True,
            'ProcessType': 'Background', 'LowPriorityIO': True, 'Nice': 10,
            'StandardOutPath': str(STATE / 'update.log'), 'StandardErrorPath': str(STATE / 'update-error.log'),
            'EnvironmentVariables': {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin'}}
with plist.open('wb') as stream: plistlib.dump(settings, stream)
plist.chmod(0o600)
domain = f'gui/{os.getuid()}'
subprocess.run(['launchctl','bootout',domain,str(plist)], capture_output=True)
subprocess.run(['launchctl','bootstrap',domain,str(plist)], check=True)
print(f'Installed {LABEL}: 1 PM local calendar + hourly retries gated to after 1 PM America/New_York; logs: {STATE}')
