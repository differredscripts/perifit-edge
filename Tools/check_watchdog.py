#!/usr/bin/env python3
"""Watchdog fault injection against production transport; no physical ports."""
import os
from pathlib import Path
import signal
import sys
import subprocess
import tempfile
import time
from arduino_emulator import ArduinoEmulator

ROOT = Path(__file__).resolve().parents[1]
build = ROOT / ('.build/finder/arm64-apple-macosx/release' if '--finder' in sys.argv else '.build/arm64-apple-macosx/release')
with tempfile.TemporaryDirectory(prefix='perifit-watchdog-') as directory:
    binary = Path(directory) / 'watchdog-check'
    sources = [ROOT / 'Sources/PerifitApp' / name for name in
               ('ArduinoUSB.swift', 'USBSerialWorker.swift', 'USBDebugLog.swift', 'PressureSafetyTap.swift')]
    objects = sorted((build / 'PerifitCore.build').glob('*.o')) + sorted((build / 'EOMCore.build').glob('*.o'))
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
                    '-I', str(build / 'Modules'), '-I', str(build / 'EOMCore.build'),
                    *map(str, sources), str(ROOT / 'Tools/WatchdogProbe.swift'), *map(str, objects),
                    '-o', str(binary)], check=True)
    peer = ArduinoEmulator(directory)
    child = subprocess.Popen([str(binary), peer.port, str(peer.control_file), str(peer.status_file)])
    paused = False
    try:
        deadline = time.monotonic() + 75
        while True:
            pid, status = os.waitpid(child.pid, os.WNOHANG | os.WUNTRACED)
            if pid and os.WIFSTOPPED(status):
                assert not paused, 'Unexpected second process suspension'
                paused = True
                time.sleep(1.25)
                assert peer.levels == [0, 0] and not peer.armed, 'Device failed to stop while host process was stopped'
                elapsed = peer.last_off - peer.last_command
                assert 0.99 <= elapsed < 1.10, f'Device deadman timing: {elapsed}'
                os.kill(child.pid, signal.SIGCONT)
            elif pid:
                child.returncode = os.waitstatus_to_exitcode(status)
                assert child.returncode == 0, f'Native watchdog checks exited {child.returncode}'
                break
            assert time.monotonic() < deadline, 'Watchdog test process timed out'
            time.sleep(.02)
        assert paused and peer.levels == [0, 0] and not peer.armed
        print('PASS watchdog transport checks; peer independently stopped a suspended host')
    finally:
        if child.returncode is None:
            os.kill(child.pid, signal.SIGCONT)
            child.terminate(); child.wait(timeout=5)
        peer.close()
