#!/usr/bin/env python3
"""Migrate only a literal OPENAI_API_KEY; never execute shell files or print values."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import tempfile


def literal_key(path):
    if not path.is_file():
        return None
    try:
        lines = path.read_text().splitlines()
    except (OSError, UnicodeError):
        return None
    value = None
    for line in lines:
        match = re.fullmatch(r'\s*(?:export\s+)?OPENAI_API_KEY\s*=\s*(.*?)\s*', line)
        if not match or '$' in match[1] or '`' in match[1]:
            continue
        try:
            tokens = shlex.split(match[1], comments=True)
        except ValueError:
            continue
        if len(tokens) == 1 and valid(tokens[0]):
            value = tokens[0]
    return value


def valid(value):
    return isinstance(value, str) and 0 < len(value) < 4096 and not any(c.isspace() for c in value)


def seed(repo, home, environment, dev=False):
    folder = home / 'Library/Application Support' / ('Glacier Dev' if dev else 'Glacier')
    path = folder / 'config.json'
    if folder.is_symlink() or path.is_symlink():
        raise ValueError('Credential storage must not be a symlink')
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    folder.chmod(0o700)
    fd = os.open(folder / '.config.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = json.loads(path.read_text()) if path.exists() else {'version': 1, 'credentials': {}}
        if not isinstance(data, dict) or not isinstance(data.get('credentials'), dict) or not all(isinstance(v,str) for v in data['credentials'].values()) or not isinstance(data.get('disabled', []), list) or not all(isinstance(v,str) for v in data.get('disabled', [])):
            raise ValueError('Invalid credential config; preserved without replacement')
        if path.exists():
            path.chmod(0o600)
        if data['credentials'].get('openai'):
            return 'Existing saved key preserved.'
        if 'openai' in data.get('disabled', []):
            return 'Key was explicitly removed; automatic migration skipped.'
        # One-time migration into the isolated Dev app; never touch a sandbox container.
        legacy_key = None
        legacy = home / 'Library/Application Support/Glacier/config.json'
        if dev and legacy.is_file() and not legacy.is_symlink() and not legacy.parent.is_symlink():
            try:
                prior = json.loads(legacy.read_text())
                if isinstance(prior, dict) and isinstance(prior.get('credentials'), dict) and 'openai' not in prior.get('disabled', []):
                    candidate = prior['credentials'].get('openai')
                    if valid(candidate): legacy_key = candidate
            except (OSError, ValueError, TypeError): pass
        key = legacy_key or environment.get('OPENAI_API_KEY', '').strip()
        if not valid(key):
            key = next((value for candidate in [home/'.zshenv', home/'.zprofile', home/'.zshrc', repo/'.env']
                        if (value := literal_key(candidate))), None)
        if not key:
            return 'No literal shell/.env key found; use Settings to save or migrate the existing Keychain key.'
        data['credentials']['openai'] = key
        fd, temp = tempfile.mkstemp(prefix='.config-', dir=folder)
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(data, stream, indent=2, sort_keys=True)
                stream.flush(); os.fsync(stream.fileno())
            os.chmod(temp, 0o600)
            os.replace(temp, path)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
        return 'OpenAI key migrated to private app config; value withheld.'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dev', action='store_true', help='Seed the isolated development app only')
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        print(seed(args.repo, Path.home(), os.environ, dev=args.dev))
    except (OSError, ValueError, TypeError):
        # Never include parser/source errors: they can contain credentials.
        print('Credential migration could not complete; existing config was preserved. Check Glacier Settings.')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
