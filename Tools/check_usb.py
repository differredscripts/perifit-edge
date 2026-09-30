#!/usr/bin/env python3
"""Run the real native serial client and app against an isolated PE1 pseudo-TTY."""
import argparse
import subprocess
import tempfile
from pathlib import Path
from arduino_emulator import ArduinoEmulator

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--timed-only', action='store_true', help='Run just the persisted timed-edging regression')
parser.add_argument('--pressure-loss-only', action='store_true', help='Run just the Perifit pressure-loss stop regression')
parser.add_argument('--xtoys-only', action='store_true', help='Run the real XToys websocket bridge against the Arduino emulator')
parser.add_argument('--m3-only', action='store_true', help='Run the three-channel motor and separate M3 XToys integration')
parser.add_argument('--finder-only', action='store_true', help='Run Finder against a three-channel emulator using the prototype build')
args = parser.parse_args()
build = ROOT / ('.build/finder/arm64-apple-macosx/release' if args.finder_only else '.build/arm64-apple-macosx/release')
with tempfile.TemporaryDirectory(prefix='perifit-usb-check-') as directory:
    binary = Path(directory) / 'perifit-usb-check'
    sources = sorted((ROOT/'Sources/PerifitApp').glob('*.swift')) + [ROOT/'Tools/USBProbe.swift']
    objects = sorted((build/'PerifitCore.build').glob('*.o')) + sorted((build/'EOMCore.build').glob('*.o'))
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-D', 'PERIFIT_SMOKE_CHECK',
                    '-I', str(build/'Modules'), '-I', str(build/'EOMCore.build'), '-O',
                    *map(str, sources), *map(str, objects), '-o', str(binary)], check=True)
    peer = ArduinoEmulator(directory, channels=3 if args.m3_only or args.finder_only else 2)
    try:
        subprocess.run([str(binary), peer.port, str(peer.control_file), str(peer.status_file),
                        str(ROOT/'dist/usb-smoke.png'), *(['--timed-only'] if args.timed_only else []),
                        *(['--pressure-loss-only'] if args.pressure_loss_only else []),
                        *(['--xtoys-only'] if args.xtoys_only else []),
                        *(['--m3-only'] if args.m3_only else []),
                        *(['--finder-only'] if args.finder_only else [])], check=True, timeout=360)
        assert not any(peer.levels) and not peer.armed
        if not (args.timed_only or args.pressure_loss_only or args.xtoys_only or args.m3_only or args.finder_only):
            assert peer.watchdogs >= 1, 'The unplug test must exercise the independent firmware-side watchdog'
            assert peer.test_completions >= 4, 'Discovery pulses must finish on the board timer'
        print(f'PE1 integration passed; {len(peer.commands)} commands, {peer.watchdogs} independent watchdog expiry.')
    finally:
        peer.close()
