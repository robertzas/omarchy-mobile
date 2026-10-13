# SPDX-License-Identifier: MIT
"""Client of omamobile-waves-host (bionic/omamobile-waves-host.c), which runs
Waves' controller in the "waves" vendor chroot.

The helper answers each command with "ok CMD", "fail CMD ..." or
"version NAME TEXT", and may ask for any number of AoC exchanges first:
"send INSTANCE LEN HEX", answered with "reply RC HEX|-". Everything it says
is checked here; a frame that breaks the protocol (wrong instance, a size
over 16 KiB, bad hex, a line we don't know) raises Violation, and the
daemon restarts the helper.
"""
import os
import selectors
import subprocess
import threading
import time

MAX_PAYLOAD = 16384
MAX_LINE = 2 * MAX_PAYLOAD + 64


class Violation(Exception):
    """The helper broke the protocol."""


class HelperGone(Exception):
    """The helper exited or stopped answering."""


class WavesHost:
    def __init__(self, argv, instance=1, log=None, env=None):
        self.argv = list(argv)
        self.instance = instance
        self.log = log or (lambda msg: None)
        self.env = env
        self.proc = None
        self.buf = b''
        self.sel = None

    # -- process ------------------------------------------------------------

    def start(self, timeout=30.0):
        self.proc = subprocess.Popen(self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, env=self.env, start_new_session=True)
        self.buf = b''
        self.sel = selectors.DefaultSelector()
        self.sel.register(self.proc.stdout, selectors.EVENT_READ)
        threading.Thread(target=self._stderr, args=(self.proc.stderr,), daemon=True).start()
        line = self._line(timeout)
        if line != f'ready {self.instance}':
            self.stop()
            raise HelperGone(f'did not start: {line[:80]!r}' if line else 'did not start')

    def _stderr(self, f):
        for raw in f:
            text = raw.decode('utf-8', 'replace').rstrip()
            # bionic's linker notes the chroot has no linker namespaces
            # config (none is needed: LD_LIBRARY_PATH is the search path)
            if text and 'ld.config.txt' not in text:
                self.log(f'helper: {text[:300]}')

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def stop(self):
        p, self.proc = self.proc, None
        if p is None:
            return
        try:
            p.stdin.write(b'quit\n')
            p.stdin.close()
        except OSError:
            pass
        try:
            p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, 9)
            except ProcessLookupError:
                pass
            p.wait()
        if self.sel:
            self.sel.close()
            self.sel = None

    # -- lines --------------------------------------------------------------

    def _line(self, timeout):
        deadline = time.monotonic() + timeout
        while b'\n' not in self.buf:
            if len(self.buf) > MAX_LINE:
                raise Violation('an over-long line')
            left = deadline - time.monotonic()
            if left <= 0 or not self.sel.select(left):
                return None
            chunk = os.read(self.proc.stdout.fileno(), 65536)
            if not chunk:
                raise HelperGone(f'exited ({self.proc.wait()})')
            self.buf += chunk
        line, self.buf = self.buf.split(b'\n', 1)
        if len(line) > MAX_LINE:
            raise Violation('an over-long line')
        try:
            return line.decode('ascii')
        except UnicodeDecodeError:
            raise Violation('a line that is not ASCII') from None

    def _write(self, text):
        try:
            self.proc.stdin.write(text.encode('ascii') + b'\n')
            self.proc.stdin.flush()
        except OSError as e:
            raise HelperGone(f'stdin: {e}') from None

    def parse_send(self, line):
        """(instance, payload) of a "send" line, or Violation."""
        parts = line.split(' ')
        if len(parts) != 4:
            raise Violation('a malformed send line')
        _, inst, n, hexdata = parts
        if not (inst.isdigit() and n.isdigit()):
            raise Violation('a malformed send line')
        inst, n = int(inst), int(n)
        if inst != self.instance:
            raise Violation(f'a send for instance {inst} (expected {self.instance})')
        if not 0 < n <= MAX_PAYLOAD:
            raise Violation(f'a {n}-byte send (1..{MAX_PAYLOAD})')
        if len(hexdata) != 2 * n:
            raise Violation('a send whose length does not match its data')
        try:
            data = bytes.fromhex(hexdata)
        except ValueError:
            raise Violation('a send with bad hex') from None
        return inst, data

    def request(self, cmd, on_send, timeout=30.0):
        """Run one command. on_send(payload) -> (rc, rx bytes) is called for
        every exchange the controller asks for. Returns (ok, detail)."""
        if not self.alive():
            raise HelperGone('not running')
        self._write(cmd)
        name = cmd.split(' ', 1)[0]
        deadline = time.monotonic() + timeout
        while True:
            line = self._line(max(0.0, deadline - time.monotonic()))
            if line is None:
                raise HelperGone(f'no answer to {name}')
            word = line.split(' ', 1)[0]
            if word == 'send':
                _, data = self.parse_send(line)
                rc, rx = on_send(data)
                if not isinstance(rc, int) or rc > 0 or rc < -4095 or len(rx) > MAX_PAYLOAD:
                    raise ValueError('bad exchange result')
                self._write(f'reply {rc} {rx.hex() if rx else "-"}')
                continue
            rest = line[len(word) + 1:]
            if word == 'ok' and rest == name:
                return True, ''
            if word == 'fail' and rest.split(' ', 1)[0] == name:
                return False, rest[len(name):].strip()
            if word == 'version' and name == 'version':
                return True, rest
            raise Violation(f'an unexpected line ({word!r})')
