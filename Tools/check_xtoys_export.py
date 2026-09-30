#!/usr/bin/env python3
"""Test XToys export against an in-process mock; never contacts XToys."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
build = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--scratch-path', '.build/finder', '--show-bin-path'], cwd=ROOT, text=True).strip())
with tempfile.TemporaryDirectory(prefix='perifit-xtoys-check-') as directory:
    binary = Path(directory) / 'xtoys-check'
    objects = sorted((build / 'PerifitCore.build').glob('*.o')) + sorted((build / 'EOMCore.build').glob('*.o'))
    assert objects, 'Build the Finder release first'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
                    '-I', str(build / 'Modules'), '-I', str(build / 'EOMCore.build'),
                    str(ROOT / 'Sources/PerifitApp/XToysExport.swift'), str(ROOT / 'Tools/XToysExportProbe.swift'),
                    *map(str, objects), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
