#!/usr/bin/env python3
"""Compile and exercise the native app with isolated data; no physical output."""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
build = ROOT / ('.build/finder/arm64-apple-macosx/release' if '--finder' in sys.argv else '.build/arm64-apple-macosx/release')
assert build.exists(), 'Build the release app first'
with tempfile.TemporaryDirectory(prefix='perifit-app-check-') as directory:
    binary = Path(directory) / 'perifit-smoke'
    sources = sorted((ROOT/'Sources/PerifitApp').glob('*.swift')) + [ROOT/'Tools/Smoke.swift']
    objects = sorted((build/'PerifitCore.build').glob('*.o')) + sorted((build/'EOMCore.build').glob('*.o'))
    command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-D', 'PERIFIT_SMOKE_CHECK',
               '-I', str(build/'Modules'), '-I', str(build/'EOMCore.build'), '-O',
               *map(str, sources), *map(str, objects), '-o', str(binary)]
    subprocess.run(command, check=True)
    screenshot = ROOT / 'dist/smoke.png'
    subprocess.run([str(binary), str(screenshot), *[arg for arg in sys.argv[1:] if arg != '--finder']], check=True, timeout=180)
    print('UI render:', screenshot)
