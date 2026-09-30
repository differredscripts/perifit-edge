#!/usr/bin/env python3
"""PE1 conformance against the compiled firmware core or a USB Uno. Stdlib only.

No arguments: native assertions + actual firmware core over pipes.
--port /dev/cu.usbmodem... --locked: verify an explicitly locked firmware build.
--port ... --unpowered-bench: active bench firmware, motor supply MUST be removed.
ACK checks are protocol evidence; measure physical outputs separately.
"""
import argparse
import os
from pathlib import Path
import select
import subprocess
import tempfile
import termios
import time
import uuid

ROOT = Path(__file__).resolve().parent


class Link:
    def __init__(self, rx, tx):
        self.rx, self.tx = rx, tx
        self.buffer = bytearray()

    def send(self, data):
        data = data.encode() if isinstance(data, str) else data
        deadline = time.monotonic() + 1
        while data:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([], [self.tx], [], remaining)[1], 'Write timeout'
            try:
                sent = os.write(self.tx, data)
                assert sent > 0, 'Port closed during write'
                data = data[sent:]
            except BlockingIOError:
                pass

    def line(self, timeout=1.5):
        deadline = time.monotonic() + timeout
        while b'\n' not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.rx], [], [], remaining)[0]:
                raise TimeoutError('No complete PE1 reply')
            chunk = os.read(self.rx, 1024)
            assert chunk, 'Port closed during read'
            self.buffer.extend(chunk)
            assert len(self.buffer) <= 8192, 'Response flood'
        line, _, self.buffer = self.buffer.partition(b'\n')
        return line.decode('ascii').removesuffix('\r')

    def expect(self, expected, timeout=1.5):
        actual = self.line(timeout)
        assert actual == expected, (actual, expected)

    def quiet(self, seconds):
        try:
            unexpected = self.line(seconds)
        except TimeoutError:
            return
        raise AssertionError(f'Unexpected reply: {unexpected}')


def conformance(link, locked):
    nonce = lambda: uuid.uuid4().hex
    session = nonce()
    if locked:
        link.send(f'PE1 HELLO {session}\n')
        link.expect(f'PE1 ERR {session} 0 NOT_CONFIGURED')
        for seq, command in enumerate(('ARM', 'SET', 'TEST', 'STOP'), 1):
            args = ' 8 0 0' if command in ('SET', 'TEST') else ''
            link.send(f'PE1 {command} {session} {seq}{args}\n')
            link.expect(f'PE1 ERR {session} {seq} NOT_CONFIGURED')
        link.quiet(1.2)
        print('PASS real-board locked handshake and rejection of ARM/SET/TEST/STOP; no readiness advertised')
        return

    def hello(value=None):
        nonlocal session
        session = value or nonce()
        frame = f'PE1 HELLO {session}\r\n'
        link.send(frame[:7]); time.sleep(.003); link.send(frame[7:])
        link.expect(f'PE1 READY {session} 3 200 180 160 1000 TEST250')

    def command(verb, seq, args=''):
        link.send(f'PE1 {verb} {session} {seq}{args}\n')

    def ack(seq, state):
        link.expect(f'PE1 ACK {session} {seq} {state}')

    hello('0123456789abcdef0123456789abcdef')
    hello(session)
    command('ARM', 1); ack(1, 'ARMED 0 0 0')
    # Golden exchange, concatenated frames, then independent channel changes.
    link.send(f'PE1 SET {session} 2 120 72 0\nPE1 SET {session} 3 0 0 0\n')
    ack(2, 'ARMED 120 72 0'); ack(3, 'ARMED 0 0 0')
    command('SET', 4, ' 80 36 0'); ack(4, 'ARMED 80 36 0')
    command('STOP', 5); ack(5, 'DISARMED 0 0 0')
    command('SET', 6, ' 1 1 0'); link.expect(f'PE1 ERR {session} 6 NOT_ARMED')
    hello(); command('ARM', 1); ack(1, 'ARMED 0 0 0')
    command('SET', 2, ' 80 36 0'); ack(2, 'ARMED 80 36 0')
    command('SET', 4, ' 0 36 0'); ack(4, 'ARMED 0 36 0')
    command('SET', 4, ' 8 8 0'); link.expect(f'PE1 ERR {session} 4 BAD_SEQUENCE')
    print('PASS golden exchange, fragmented/concatenated frames, channel pairs, STOP and stale sequence')

    hello(); command('ARM', 1); ack(1, 'ARMED 0 0 0')
    command('SET', 2, ' 8 8 0'); ack(2, 'ARMED 8 8 0')
    started = time.monotonic()
    link.expect(f'PE1 FAULT {session} WATCHDOG')
    assert .9 <= time.monotonic() - started < 1.3, 'Deadman timing'
    command('ARM', 3); link.expect(f'PE1 ERR {session} 3 NEW_SESSION_REQUIRED')
    print('PASS independent one-second deadman without host traffic')

    for levels in (' 8 0 0', ' 0 8 0', ' 0 0 8'):
        hello(); started = time.monotonic(); command('TEST', 1, levels)
        ack(1, 'DISARMED 0 0 0')
        elapsed = time.monotonic() - started
        assert .23 <= elapsed < .5, f'TEST250 timing: {elapsed}'
        link.quiet(.3)
        command('TEST', 2, levels); link.expect(f'PE1 ERR {session} 2 NEW_SESSION_REQUIRED')
    for cancel in ('STOP', 'HELLO', 'SET', 'BAD'):
        hello(); command('TEST', 1, ' 8 0 0'); time.sleep(.05)
        if cancel == 'HELLO':
            hello()
        elif cancel == 'STOP':
            command('STOP', 2); ack(2, 'DISARMED 0 0 0')
        elif cancel == 'SET':
            command('SET', 2, ' 1 0 0'); link.expect(f'PE1 ERR {session} 2 NOT_ARMED')
        else:
            link.send('bad\n'); link.expect(f'PE1 ERR {session} 0 BAD_FRAME')
        link.quiet(.3)
    for levels in (' 0 0 0', ' 8 8 0', ' 201 0 0', ' 0 181 0', ' 0 0 161', ' 8 0 8'):
        hello(); command('TEST', 1, levels); link.expect(f'PE1 ERR {session} 1 OUT_OF_RANGE')
        command('TEST', 2, ' 8 0 0'); link.expect(f'PE1 ERR {session} 2 NEW_SESSION_REQUIRED')
    print('PASS TEST250 local cutoff, one completion ACK, cancellation and consumed sessions')

    hello(); command('ARM', 1); ack(1, 'ARMED 0 0 0')
    link.send(b'x' * 128); link.expect(f'PE1 ERR {session} 0 OVERFLOW')
    link.send(f'PE1 HELLO {nonce()}\n'); link.quiet(.05)
    hello(); link.send(b'\0'); link.expect(f'PE1 ERR {session} 0 BAD_FRAME')
    link.send(f'PE1 HELLO {nonce()}\n'); link.quiet(.05)
    hello(); command('ARM', 1); ack(1, 'ARMED 0 0 0')
    command('SET', 2, ' 8'); link.expect(f'PE1 ERR {session} 2 BAD_FRAME')
    hello(); command('STOP', 1); ack(1, 'DISARMED 0 0 0')
    print('PASS overflow/invalid-byte discard, missing tokens and fresh-session recovery; final STOP acknowledged')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port')
    parser.add_argument('--watchdog-probe', action='store_true',
                        help='Expect one deliberate hardware-watchdog reset (locked diagnostic build only)')
    parser.add_argument('--timebase-probe', action='store_true',
                        help='Frozen millis diagnostic: parser must reply before the watchdog resets')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--locked', action='store_true')
    mode.add_argument('--unpowered-bench', action='store_true',
                      help='Motor supply physically disconnected; shield PWR jumper removed')
    args = parser.parse_args()
    if args.watchdog_probe and not (args.port and args.locked):
        parser.error('--watchdog-probe needs --port and --locked')
    if args.timebase_probe and not args.watchdog_probe:
        parser.error('--timebase-probe also needs --watchdog-probe')
    if args.port:
        if not (args.locked or args.unpowered_bench):
            parser.error('Physical ports require --locked or --unpowered-bench')
        fd = os.open(args.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            import fcntl
            fcntl.ioctl(fd, termios.TIOCEXCL)
            options = termios.tcgetattr(fd)
            options[0] = options[1] = options[3] = 0
            options[2] = termios.CLOCAL | termios.CREAD | termios.CS8
            options[4] = options[5] = termios.B115200
            options[6][termios.VMIN] = options[6][termios.VTIME] = 0
            termios.tcsetattr(fd, termios.TCSANOW, options)
            termios.tcflush(fd, termios.TCIOFLUSH)
            link = Link(fd, fd)
            # Uno may reset on open; drain boot notices before the handshake.
            until = time.monotonic() + 2.5
            while time.monotonic() < until:
                try:
                    line = link.line(.25)
                    assert line == 'PE1 BOOT 1', f'Unexpected startup: {line}'
                except TimeoutError:
                    pass
            if args.watchdog_probe:
                probe_session = uuid.uuid4().hex
                link.send(f'PE1 HELLO {probe_session}\n')
                link.expect('PE1 FAULT 00000000000000000000000000000000 WATCHDOG_PROBE')
                if args.timebase_probe:
                    link.expect(f'PE1 ERR {probe_session} 0 NOT_CONFIGURED')
                link.expect('PE1 BOOT 1', timeout=3)
                link.quiet(3)
                print('PASS ' + ('frozen millis with a live parser' if args.timebase_probe else 'deliberate firmware hang') +
                      ' reset by AVR watchdog; reboot observed without a boot loop')
            conformance(link, args.locked)
        finally:
            os.close(fd)
    else:
        if args.locked or args.unpowered_bench:
            parser.error('Physical-board mode needs --port')
        with tempfile.TemporaryDirectory(prefix='perifit-pe1-') as temp:
            binary = str(Path(temp) / 'checks')
            subprocess.run(['c++', '-std=c++11', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=address,undefined', str(ROOT / 'Checks.cpp'), '-o', binary], check=True)
            subprocess.run([binary], check=True)
            with subprocess.Popen([binary, '--serve'], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as peer:
                try:
                    conformance(Link(peer.stdout.fileno(), peer.stdin.fileno()), False)
                finally:
                    peer.terminate()


if __name__ == '__main__':
    main()
