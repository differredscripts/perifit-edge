#!/usr/bin/env python3
"""Build and flash the three-motor Uno firmware when its USB port appears.

Disconnect external motor power and remove the shield PWR jumper first. Close
Perifit Edge and any serial monitor. Upload replaces the Uno's application firmware.
Run: python3 Firmware/flash_arduino.py [--port /dev/cu.usbmodem...] [--wait 300]
Use --build-only to compile without waiting for or writing to a board.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
FQBN = 'arduino:avr:uno'


def choose_port(snapshot, requested=None):
    ports = snapshot.get('detected_ports', [])
    if requested:
        for item in ports:
            if item.get('port', {}).get('address') == requested:
                if item['port'].get('protocol') != 'serial':
                    raise ValueError('The selected port is not a USB serial port.')
                boards = item.get('matching_boards', [])
                if boards and not any(board.get('fqbn') == FQBN for board in boards):
                    raise ValueError('The selected port identifies a different board; refusing to flash Uno firmware.')
                return requested
        return None
    matches = [item['port']['address'] for item in ports
               if item.get('port', {}).get('protocol') == 'serial' and
               any(board.get('fqbn') == FQBN for board in item.get('matching_boards', []))]
    if len(matches) > 1:
        raise ValueError('Multiple Uno boards detected. Select exactly one with --port.')
    return matches[0] if matches else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', help='Explicit USB serial port; needed for an unrecognized Uno clone')
    parser.add_argument('--wait', type=float, default=300, help='Maximum seconds to wait for USB (default: 300)')
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--self-check', action='store_true')
    args = parser.parse_args()
    if args.self_check:
        uno = {'port': {'address': '/dev/cu.test', 'protocol': 'serial'}, 'matching_boards': [{'fqbn': FQBN}]}
        assert choose_port({'detected_ports': [uno]}) == '/dev/cu.test'
        assert choose_port({'detected_ports': []}) is None
        clone = {'port': {'address': '/dev/cu.clone', 'protocol': 'serial'}}
        assert choose_port({'detected_ports': [clone]}) is None
        assert choose_port({'detected_ports': [clone]}, '/dev/cu.clone') == '/dev/cu.clone'
        remote = {'port': {'address': '192.0.2.1', 'protocol': 'network'}, 'matching_boards': [{'fqbn': FQBN}]}
        assert choose_port({'detected_ports': [remote]}) is None
        for items in ([uno, uno], [{'port': uno['port'], 'matching_boards': [{'fqbn': 'arduino:avr:mega'}]}]):
            try: choose_port({'detected_ports': items}, None if len(items) == 2 else '/dev/cu.test')
            except ValueError: pass
            else: raise AssertionError('Ambiguous or wrong-board selection accepted')
        print('PASS Uno selection, absent board, explicit clone, ambiguous and wrong-board rejection')
        return
    if not 0 <= args.wait <= 3600:
        parser.error('--wait must be between 0 and 3600 seconds')
    cli = shutil.which('arduino-cli')
    if not cli:
        parser.error('Install arduino-cli first (brew install arduino-cli).')
    build = ROOT / 'dist/uno-m3'
    subprocess.run([cli, 'compile', '--fqbn', FQBN, '--build-path', str(build),
                    str(ROOT / 'Firmware/PerifitEdgeUno')], check=True)
    if args.build_only:
        print('Built M1/M2/M3 firmware:', build)
        return
    print('Disconnect external motor power and remove the shield PWR jumper before USB flashing. '
          'Close Perifit Edge and all serial monitors. This replaces the Uno firmware.', flush=True)
    print(f'Waiting up to {args.wait:g} seconds for an Uno…', flush=True)
    deadline = time.monotonic() + args.wait
    while True:
        result = subprocess.run([cli, 'board', 'list', '--json'], check=True, capture_output=True, text=True,
                                timeout=max(1, min(10, deadline - time.monotonic() + 1)))
        port = choose_port(json.loads(result.stdout), args.port)
        if port:
            break
        if time.monotonic() >= deadline:
            raise SystemExit('No matching Uno appeared. Plug it in and rerun, or specify --port for a clone.')
        time.sleep(min(1, max(0, deadline - time.monotonic())))
    holder = subprocess.run(['lsof', '-t', port], capture_output=True, text=True)
    if holder.returncode == 0 and holder.stdout.strip():
        raise SystemExit(f'{port} is open in another process. Close Perifit Edge/serial monitors and rerun.')
    print('Flashing and verifying', port, flush=True)
    subprocess.run([cli, 'upload', '--fqbn', FQBN, '--port', port, '--input-dir', str(build), '--verify'], check=True)
    print('Flash verified. Reconnect the Arduino in Perifit Edge; it should advertise three channels. '
          'Outputs remain off until you confirm setup and manually start. No powered motor test was run.')


if __name__ == '__main__':
    main()
