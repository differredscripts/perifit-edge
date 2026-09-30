#!/usr/bin/env python3
"""PE1 test peer over a real macOS pseudo-terminal. No motor hardware is accessed."""
import errno
import json
import os
import pty
import select
import threading
import time
from pathlib import Path


class ArduinoEmulator:
    def __init__(self, directory, channels=2):
        assert channels in (2, 3)
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.control_file = self.directory / 'control.json'
        self.status_file = self.directory / 'status.json'
        self.control_file.write_text('{}')
        self.master, slave = pty.openpty()
        self.port = os.ttyname(slave)
        os.close(slave)
        self.session = '0' * 32
        self.sequence = 0
        self.used = False
        self.armed = False
        self.levels = [0] * channels
        self.limits = [200, 180, 160][:channels]
        self.test_until = None
        self.test_sequence = None
        self.test_completions = 0
        self.last_command = time.monotonic()
        self.buffer = bytearray()
        self.discard = False
        self.commands = []
        self.watchdogs = 0
        self.running = True
        self.mode = {}
        self.was_reset = False
        self.delayed_acks = []
        self.was_bad_frame = False
        self.was_flood = False
        self.last_off = 0.0
        self.last_nonzero = 0.0
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def send(self, line):
        if self.master is None:
            return
        data = (line + '\r\n').encode('ascii')
        try:
            # Fragment replies to exercise incremental native parsing.
            middle = len(data) // 2
            os.write(self.master, data[:middle])
            os.write(self.master, data[middle:])
        except OSError as error:
            if error.errno not in (errno.EIO, errno.EBADF):
                raise

    def zero(self):
        if any(self.levels): self.last_off = time.monotonic()
        self.armed = False
        self.levels = [0] * len(self.limits)
        self.test_until = None
        self.test_sequence = None

    def publish(self):
        data = {'armed': self.armed, 'levels': self.levels, 'watchdogs': self.watchdogs,
                'commands': self.commands[-400:], 'session': self.session,
                'updatedAt': time.monotonic(), 'lastOff': self.last_off,
                'lastNonzero': self.last_nonzero, 'lastCommand': self.last_command}
        tmp = self.status_file.with_suffix('.tmp')
        tmp.write_text(json.dumps(data))
        tmp.replace(self.status_file)

    def fault(self, code, sequence=0):
        self.zero(); self.used = True
        self.send(f'PE1 ERR {self.session} {sequence} {code}')

    def line(self, raw):
        try:
            text = raw.removesuffix(b'\r').decode('ascii')
            fields = text.split(' ')
            assert len(fields) >= 3 and fields[0] == 'PE1' and all(fields)
            verb, session = fields[1:3]
            assert len(session) == 32 and all(c in '0123456789abcdef' for c in session)
            self.commands.append(text)
            if verb == 'HELLO':
                assert len(fields) == 3
                if session != self.session:
                    self.zero(); self.session = session; self.sequence = 0; self.used = False
                elif self.used:
                    self.fault('NEW_SESSION_REQUIRED'); return
                capability = '' if self.mode.get('legacy') else ' TEST250'
                self.send(f'PE1 READY {session} {len(self.limits)} {" ".join(map(str, self.limits))} 1000{capability}')
                return
            assert len(fields) >= 4 and fields[3].isascii() and fields[3].isdigit()
            seq = int(fields[3])
            assert session == self.session and self.sequence < seq <= 2_147_483_647
            if verb == 'ARM':
                assert len(fields) == 4 and not self.used and not self.armed
                self.armed = True; self.used = True; self.levels = [0] * len(self.limits)
            elif verb == 'STOP':
                assert len(fields) == 4
                if self.mode.get('ignore_stop'): return
                self.zero(); self.used = True
            elif verb == 'TEST':
                assert not self.mode.get('legacy') and not self.used and not self.armed and len(fields) == 4 + len(self.limits)
                assert all(f.isascii() and f.isdigit() for f in fields[4:])
                levels = list(map(int, fields[4:]))
                assert sum(value > 0 for value in levels) == 1
                assert all(0 <= value <= limit for value, limit in zip(levels, self.limits))
                self.levels = levels; self.used = True; self.sequence = seq
                self.test_until = time.monotonic() + 0.250; self.test_sequence = seq
                return  # ACK only after the board's own timer has turned both motors OFF.
            elif verb == 'SET':
                assert len(fields) == 4 + len(self.limits) and self.armed
                assert all(f.isascii() and f.isdigit() for f in fields[4:])
                levels = list(map(int, fields[4:]))
                assert all(0 <= level <= limit for level, limit in zip(levels, self.limits))
                if any(self.levels) and not any(levels): self.last_off = time.monotonic()
                self.levels = levels
                if any(levels): self.last_nonzero = time.monotonic()
            else:
                raise ValueError('verb')
            self.sequence = seq; self.last_command = time.monotonic()
            if self.mode.get('drop_ack'):
                return
            applied = list(self.levels)
            if self.mode.get('bad_ack') and verb == 'SET':
                applied[0] = (applied[0] + 1) % 200
            state = 'ARMED' if self.armed else 'DISARMED'
            reply = f'PE1 ACK {session} {seq} {state} {" ".join(map(str, applied))}'
            delay = float(self.mode.get('ack_delay', 0)) if verb in self.mode.get('delay_verbs', ['ARM', 'SET']) else 0
            if delay > 0: self.delayed_acks.append((time.monotonic() + delay, reply))
            else: self.send(reply)
        except (AssertionError, ValueError, UnicodeError):
            self.fault('BAD_FRAME')

    def run(self):
        last_publish = 0
        while self.running:
            try:
                self.mode = json.loads(self.control_file.read_text())
            except (OSError, ValueError):
                pass
            if self.mode.get('unplug') and self.master is not None:
                os.close(self.master); self.master = None
            if self.mode.get('reset') and not self.was_reset:
                self.zero(); self.session = '0' * 32; self.sequence = 0; self.used = False
                self.delayed_acks.clear()
                self.send('PE1 BOOT 1')
            self.was_reset = bool(self.mode.get('reset'))
            if self.mode.get('bad_frame') and not self.was_bad_frame:
                self.send('not a PE1 reply')
            self.was_bad_frame = bool(self.mode.get('bad_frame'))
            if self.mode.get('flood') and not self.was_flood:
                self.send(('PE1 ACK ' + '0' * 32 + ' 1 DISARMED' + ' 0' * len(self.limits) + '\n') * 200)
            self.was_flood = bool(self.mode.get('flood'))
            due = [item for item in self.delayed_acks if item[0] <= time.monotonic()]
            self.delayed_acks = [item for item in self.delayed_acks if item not in due]
            for _, reply in due: self.send(reply)
            if self.test_until is not None and time.monotonic() >= self.test_until:
                seq = self.test_sequence
                self.zero(); self.test_completions += 1
                if not self.mode.get('drop_ack'):
                    self.send(f'PE1 ACK {self.session} {seq} DISARMED' + ' 0' * len(self.limits))
            if self.armed and time.monotonic() - self.last_command >= 1:
                self.zero(); self.used = True; self.watchdogs += 1
                self.send(f'PE1 FAULT {self.session} WATCHDOG')
            if self.master is not None:
                readable, _, _ = select.select([self.master], [], [], 0.01)
                if readable:
                    try:
                        data = os.read(self.master, 1024)
                        for byte in data:
                            if self.discard:
                                if byte == 10:
                                    self.discard = False
                            elif byte == 10:
                                self.line(bytes(self.buffer)); self.buffer.clear()
                            elif len(self.buffer) >= 127:
                                self.buffer.clear(); self.discard = True; self.fault('OVERFLOW')
                            else:
                                self.buffer.append(byte)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        time.sleep(0.01)
            else:
                time.sleep(0.01)
            if time.monotonic() - last_publish >= 0.02:
                self.publish(); last_publish = time.monotonic()
        self.publish()

    def close(self):
        self.running = False; self.thread.join(timeout=2)
        if self.master is not None:
            os.close(self.master); self.master = None


if __name__ == '__main__':
    import tempfile
    with tempfile.TemporaryDirectory(prefix='perifit-board-') as directory:
        board = ArduinoEmulator(directory)
        print(f'PE1 emulated board: {board.port}\nTest controls/status: {directory}', flush=True)
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            board.close()
