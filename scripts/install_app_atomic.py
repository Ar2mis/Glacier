#!/usr/bin/env python3
"""Swap a verified Glacier bundle on the same filesystem, retaining the old one."""
import ctypes
import os
from pathlib import Path
import plistlib
import sys

def install(stage, destination):
    stage, destination = Path(stage), Path(destination)
    for app in [stage, destination] if destination.exists() else [stage]:
        if app.is_symlink(): raise ValueError('Refusing a symlink app destination')
        with (app / 'Contents/Info.plist').open('rb') as stream:
            if plistlib.load(stream).get('CFBundleIdentifier') != 'local.ar2mis.lecturecaptions':
                raise ValueError('Refusing to replace a different application')
    if not destination.exists():
        os.rename(stage, destination)
        return
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    swap = libc.renamex_np
    swap.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    swap.restype = ctypes.c_int
    if swap(os.fsencode(stage), os.fsencode(destination), 2) != 0:  # RENAME_SWAP, stdio.h
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))

if __name__ == '__main__': install(sys.argv[1], sys.argv[2])
