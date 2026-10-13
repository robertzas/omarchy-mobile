# SPDX-License-Identifier: MIT
"""Tests for omamobile-speaker-tuning against a fake AoC (SOCK_SEQPACKET
socket pairs, which keep message boundaries as the AoC char devices do)
and test/fake-waves-host."""
import contextlib
import io
import os
import re
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'lib'))

import aoc_tuning as at  # noqa: E402
import speaker_tuning as st  # noqa: E402
from waves_host import HelperGone, Violation, WavesHost  # noqa: E402

FAKE_HOST = os.path.join(HERE, 'fake-waves-host')


class FakeAoc:
    """The three tuning devices. Checks the framing of every exchange and
    refuses (reply -22, and records it) any block other than 16 / 2."""

    def __init__(self):
        self.pairs = {p: socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
                      for p in (at.DEV_TUNING, at.DEV_BULK_TX, at.DEV_BULK_RX)}
        self.opens = 0
        self.violations = []
        self.commands = []
        self.rc = []              # queued return codes (default 0)
        self.rx = b''             # bulk reply for SET_GET
        self.drop = 0             # replies to swallow (timeouts)
        self.asp_mode = 1
        self.last_tx = None
        self.stop = False
        self.t = threading.Thread(target=self._serve, daemon=True)
        self.t.start()

    def opener(self, path, flags):
        if path not in self.pairs:
            raise FileNotFoundError(2, 'No such file or directory', path)
        self.opens += 1
        fd = os.dup(self.pairs[path][0].fileno())
        os.set_blocking(fd, not flags & os.O_NONBLOCK)
        return fd

    def close(self):
        self.stop = True
        self.t.join(2)
        for a, b in self.pairs.values():
            a.close()
            b.close()

    def _serve(self):
        import select
        tun = self.pairs[at.DEV_TUNING][1]
        tx = self.pairs[at.DEV_BULK_TX][1]
        rx = self.pairs[at.DEV_BULK_RX][1]
        while not self.stop:
            r, _, _ = select.select([tun, tx], [], [], 0.05)
            if tx in r:
                msg = tx.recv(65536)
                if len(msg) != at.BULK_SIZE:
                    self.violations.append(f'bulk write of {len(msg)} bytes')
                self.last_tx = msg
            if tun in r:
                self._command(tun.recv(65536), tun, rx)

    def _command(self, msg, tun, rx):
        typ, counter, length, cid, reply = struct.unpack_from('<BBHHh', msg)
        if typ != 0 or length != len(msg) or reply != 0:
            self.violations.append(f'bad header {msg[:8].hex()}')
            return
        if cid == at.CMD_SET_GET_PARAM_BULK and len(msg) == 26:
            f = list(at.SET_GET_BULK.unpack(msg))
            block, comp, tx_size, rx_size = f[5], f[6], f[11], f[12]
            self.commands.append(('bulk', block, comp, tx_size))
            rc = self.rc.pop(0) if self.rc else 0
            if (block, comp) != (16, 2):
                self.violations.append(f'block {block} component {comp}')
                rc = -22
            elif self.last_tx is None or any(self.last_tx[tx_size:]) or rx_size != 0:
                self.violations.append('payload not zero-padded, or no bulk write first')
            self.last_tx = None
            if self.drop:
                self.drop -= 1
                return
            f[4] = rc
            f[1] = (f[1] + 0x80) & 0xff   # the AoC does not echo our counter (T3.2)
            f[12] = len(self.rx) if rc == 0 else 0
            tun.send(at.SET_GET_BULK.pack(*f))
            if rc == 0 and self.rx:
                rx.send(self.rx)
        elif cid == at.CMD_GET_PARAMETER and len(msg) == 18:
            f = list(at.GET_PARAM.unpack(msg))
            self.commands.append(('get', f[5], f[6], f[7]))
            if (f[5], f[6], f[7]) != (16, 2, 0):
                self.violations.append('get_parameter outside the allowlist')
                f[4] = -22
            else:
                f[8] = self.asp_mode
            f[1] = (f[1] + 0x80) & 0xff
            tun.send(at.GET_PARAM.pack(*f))
        else:
            self.violations.append(f'command 0x{cid:04x} ({len(msg)} bytes)')


class LogCapture:
    def __enter__(self):
        self.buf = io.StringIO()
        self.cm = contextlib.redirect_stderr(self.buf)
        self.cm.__enter__()
        return self

    def __exit__(self, *a):
        self.cm.__exit__(*a)

    @property
    def text(self):
        return self.buf.getvalue()


def no_payload_in(text):
    """Logs carry 16-hex-digit SHA-256 prefixes, never longer hex runs."""
    return not re.search(r'[0-9a-f]{24,}', text)


class Protocol(unittest.TestCase):
    def test_layout(self):
        cmd = at.pack_set_get_bulk(7, 16, 2, 11204)
        self.assertEqual(len(cmd), 26)
        self.assertEqual(struct.unpack_from('<BBHHh', cmd), (0, 7, 26, 0x00d5, 0))
        self.assertEqual((cmd[8], cmd[9]), (16, 2))
        self.assertEqual(struct.unpack_from('<HH', cmd, 22), (11204, 0))   # tx_size, rx_size
        g = at.pack_get_parameter(1, 16, 2, 0)
        self.assertEqual(len(g), 18)
        self.assertEqual(struct.unpack_from('<HH', g, 2), (18, 0x00d3))

    def test_allowlist(self):
        for args in ((16, 3, 10), (17, 2, 10), (0, 0, 10), (16, 2, 0), (16, 2, 16385)):
            with self.assertRaises(at.Refused):
                at.pack_set_get_bulk(0, *args)
        with self.assertRaises(at.Refused):
            at.pack_get_parameter(0, 16, 2, 1)
        with self.assertRaises(at.Refused):
            at.check_allowed(at.CMD_SET_PARAMETER, 16, 2)


class Port(unittest.TestCase):
    def setUp(self):
        self.aoc = FakeAoc()
        self.port = at.AocTuningPort(opener=self.aoc.opener, timeout=0.3)

    def tearDown(self):
        self.aoc.close()

    def test_exchange(self):
        self.aoc.rx = b'\x05\x00\x00\x00ok'
        notes = []
        self.port.log = notes.append
        rc, rx = self.port.set_get_bulk(16, 2, b'\x01' * 100)
        self.assertTrue(any('matched by command ID' in n for n in notes), notes)
        self.assertFalse(any('ignored' in n for n in notes), notes)
        self.assertEqual((rc, rx), (0, b'\x05\x00\x00\x00ok'))
        self.assertEqual(self.aoc.commands, [('bulk', 16, 2, 100)])
        self.assertEqual(self.aoc.violations, [])

    def test_refused_before_open(self):
        with self.assertRaises(at.Refused):
            self.port.set_get_bulk(17, 2, b'x')
        with self.assertRaises(at.Refused):
            self.port.set_get_bulk(16, 2, bytes(16385))
        self.assertEqual(self.aoc.opens, 0)

    def test_negative_reply_and_timeout(self):
        self.aoc.rc = [-1]
        self.assertEqual(self.port.set_get_bulk(16, 2, b'abc'), (-1, b''))
        self.aoc.drop = 1
        self.assertEqual(self.port.set_get_bulk(16, 2, b'abc')[0], -110)
        # the late reply of a timed-out exchange is not taken for the next one
        self.assertEqual(self.port.set_get_bulk(16, 2, b'abc'), (0, b''))
        self.assertEqual(self.aoc.violations, [])

    def test_asp_mode(self):
        self.assertEqual(self.port.get_parameter(16, 2, 0), (0, 1))
        self.assertEqual(self.aoc.violations, [])

    def test_missing_device(self):
        port = at.AocTuningPort(tuning='/nonexistent/acd', opener=self.aoc.opener)
        self.assertEqual(port.set_get_bulk(16, 2, b'x')[0], -2)


def fake_cfg(tmp, mode='throttle', **extra):
    env = {'OMAMOBILE_SPK_TUNING': mode, 'OMAMOBILE_RUN': os.path.join(tmp, 'run'),
           'OMAMOBILE_STATE': os.path.join(tmp, 'state'), 'OMAMOBILE_SPK_TUNING_HELPER': FAKE_HOST}
    env.update(extra)
    return st.Config(env)


def host_factory(env_extra=None, log_file=None):
    env = dict(os.environ)
    env.update(env_extra or {})
    if log_file:
        env['FAKE_WAVES_LOG'] = log_file

    def make():
        h = WavesHost([sys.executable, FAKE_HOST], log=st.log, env=env)
        h.start(timeout=10)
        return h
    return make


class Helper(unittest.TestCase):
    def run_flush(self, misbehave):
        h = host_factory({'FAKE_WAVES_MISBEHAVE': misbehave})()
        try:
            h.request('wake', lambda p: (0, b''))
            h.request('flush', lambda p: (0, b''), timeout=5)
        finally:
            h.stop()

    def test_violations(self):
        for m in ('instance', 'oversize', 'hex', 'junk'):
            with self.subTest(m), LogCapture():
                with self.assertRaises(Violation):
                    self.run_flush(m)
        with LogCapture(), self.assertRaises(HelperGone):
            self.run_flush('exit')

    def test_reply_passthrough(self):
        h = host_factory()()
        try:
            self.assertEqual(h.request('version dsp', lambda p: (0, b'\x05\x00\x00\x00')),
                             (True, 'dsp fake-1.0'))
            self.assertEqual(h.request('version dsp', lambda p: (-110, b''))[0], False)
        finally:
            h.stop()


class TunerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.aoc = FakeAoc()
        self.port = at.AocTuningPort(opener=self.aoc.opener, timeout=0.3)
        self.cmdlog = os.path.join(self.tmp, 'cmds')
        self.gate_reason = None

    def tearDown(self):
        self.aoc.close()

    def tuner(self, mode='throttle', **kw):
        cfg = fake_cfg(self.tmp, mode)
        return st.Tuner(cfg, host_factory(log_file=self.cmdlog), kw.pop('port', self.port),
                        lambda: self.gate_reason, **kw)

    def state(self, t):
        with open(t.cfg.state_file) as f:
            return f.read().strip()

    def cmds(self):
        with open(self.cmdlog) as f:
            return [line.strip() for line in f]

    def test_send_sequence(self):
        t = self.tuner()
        with LogCapture() as lc:
            self.assertTrue(t.send(0))
            self.assertEqual(self.state(t), 'active SPEAKER_MUSIC_THROTTLE 0')
            self.assertEqual(self.cmds(), ['version dsp', 'begin', 'wake', 'bypass 0', 'volume 1',
                                           'orientation 0', 'route 2 0 0', 'flush'])
            # version query (4 bytes) and the full upload
            self.assertEqual([c[3] for c in self.aoc.commands], [4, 3000])
            # a turn: no wake, a small update
            self.assertTrue(t.send(90))
            self.assertEqual(self.aoc.commands[-1][3], 200)
            self.assertEqual(self.state(t), 'active SPEAKER_MUSIC_THROTTLE 90')
            # an AoC restart: wake again, full upload
            t.aoc_restarted()
            self.assertTrue(t.send(90))
            self.assertEqual(self.aoc.commands[-1][3], 3000)
            t.stop()
        self.assertEqual(self.aoc.violations, [])
        self.assertTrue(all(c[1:3] == (16, 2) for c in self.aoc.commands))
        self.assertTrue(no_payload_in(lc.text), lc.text)
        self.assertIn('rc 0', lc.text)

    def test_music_route(self):
        t = self.tuner('music')
        with LogCapture():
            self.assertTrue(t.send(270))
            t.stop()
        self.assertIn('route 2 0 1', self.cmds())
        self.assertEqual(self.state(t), 'active SPEAKER_MUSIC 270')

    def test_retry_once_on_timeout(self):
        t = self.tuner()
        self.aoc.drop = 1
        with LogCapture() as lc:
            self.assertTrue(t.send(0))
            t.stop()
        self.assertIn('timed out, one retry', lc.text)

    def test_negative_reply_fails(self):
        t = self.tuner()
        self.aoc.rc = [0, -1]
        with LogCapture() as lc:
            self.assertFalse(t.send(0))
            t.stop()
        self.assertTrue(self.state(t).startswith('failed'))
        self.assertIn('rc -1', lc.text)

    def test_gate_blocks_everything(self):
        self.gate_reason = 'omamobile-speaker-watch.service is not active'
        t = self.tuner()
        with LogCapture():
            self.assertFalse(t.send(0))
        self.assertEqual(self.aoc.opens, 0)
        self.assertTrue(self.state(t).startswith('blocked'))

    def test_dry_run_opens_nothing(self):
        t = self.tuner(port=None, dry_run=True, dry_rc=0)
        with LogCapture() as lc:
            self.assertTrue(t.send(0))
            t.stop()
        self.assertEqual(self.aoc.opens, 0)
        self.assertEqual(self.state(t), 'active SPEAKER_MUSIC_THROTTLE 0 (dry run)')
        self.assertIn('dry run, not sent', lc.text)
        # the default dry answer is a timeout: the controller's flush fails
        t = self.tuner(port=None, dry_run=True)
        with LogCapture():
            self.assertFalse(t.send(0))
            t.stop()
        self.assertEqual(self.aoc.opens, 0)

    def test_helper_violation_restarts(self):
        cfg = fake_cfg(self.tmp)
        bad = host_factory({'FAKE_WAVES_MISBEHAVE': 'oversize'})
        t = st.Tuner(cfg, bad, self.port, lambda: None)
        with LogCapture() as lc:
            self.assertFalse(t.send(0))
            self.assertIsNone(t.host)
            t.host_factory = host_factory()
            self.assertTrue(t.send(0))
            t.stop()
        self.assertIn('broke the protocol', lc.text)
        self.assertEqual(self.aoc.violations, [])

    def test_off_and_give_up(self):
        t = self.tuner('off')
        with LogCapture():
            self.assertFalse(t.send(0))
        self.assertEqual(self.state(t), 'off')
        t = st.Tuner(fake_cfg(self.tmp), host_factory({'FAKE_WAVES_MISBEHAVE': 'exit'}),
                     self.port, lambda: None)
        with LogCapture() as lc:
            for _ in range(5):
                t.send(0)
        self.assertEqual(t.failures, st.Tuner.MAX_FAILURES)
        self.assertIn('not sending', lc.text)

    def test_record(self):
        rec = os.path.join(self.tmp, 'rec')
        t = self.tuner(record=rec)
        with LogCapture():
            self.assertTrue(t.send(0))
            t.stop()
        self.assertEqual(os.stat(rec).st_mode & 0o777, 0o700)
        files = sorted(os.listdir(rec))
        self.assertIn('exchanges.log', files)
        tx = [f for f in files if f.endswith('.tx')]
        self.assertEqual(len(tx), 2)
        self.assertEqual(os.stat(os.path.join(rec, tx[0])).st_mode & 0o777, 0o600)


class FakeOrientation:
    def __init__(self, on_change):
        self.on_change = on_change
        self.claimed = False

    def claim(self):
        self.claimed = True
        self.on_change('normal')

    def release(self):
        self.claimed = False


class FakePlayback(st.Playback):
    def dsp_state(self):
        return 'Playback'


class DaemonTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.asound = os.path.join(self.tmp, 'asound')
        sub = os.path.join(self.asound, 'card1', 'pcm6p', 'sub0')
        os.makedirs(sub)
        os.makedirs(os.path.join(self.asound, 'card1', 'pcm8c', 'sub0'))
        with open(os.path.join(self.asound, 'cards'), 'w') as f:
            f.write(' 0 [Dummy          ]: Dummy - Dummy\n'
                    ' 1 [aocsndcard     ]: aoc-snd-card - aoc-snd-card\n')
        self.status = os.path.join(sub, 'status')
        self.play(False)
        self.aocdir = os.path.join(self.tmp, 'aoc')
        os.makedirs(self.aocdir)
        self.restart(0)
        self.aoc = FakeAoc()
        self.now = 100.0

    def tearDown(self):
        self.aoc.close()

    def play(self, on):
        with open(self.status, 'w') as f:
            f.write('state: RUNNING\n' if on else 'closed\n')

    def restart(self, n):
        with open(os.path.join(self.aocdir, 'restart_count'), 'w') as f:
            f.write(f'{n}\n')

    def test_triggers(self):
        cfg = fake_cfg(self.tmp)
        port = at.AocTuningPort(opener=self.aoc.opener, timeout=0.3)
        tuner = st.Tuner(cfg, host_factory(), port, lambda: None)
        d = st.Daemon(cfg, tuner, FakePlayback(self.asound),
                      st.AocRestarts(self.aocdir, os.path.join(self.tmp, 'none')),
                      orientation_factory=FakeOrientation, clock=lambda: self.now)
        with LogCapture() as lc:
            d.tick()
            self.assertEqual(self.aoc.commands, [])           # nothing plays
            self.play(True)
            d.tick()                                          # stream start
            self.assertTrue(d.orientation.claimed)
            self.assertEqual(len(self.aoc.commands), 2)       # version + full upload
            d.tick()
            self.assertEqual(len(self.aoc.commands), 2)       # nothing new
            d._orientation('left-up')
            self.now += 0.5
            d.tick()
            self.assertEqual(len(self.aoc.commands), 2)       # hysteresis
            self.now += 1.0
            d.tick()
            self.assertEqual(len(self.aoc.commands), 3)       # resent at 90
            self.assertEqual(tuner.state, 'active SPEAKER_MUSIC_THROTTLE 90')
            self.restart(1)
            d.tick()                                          # AoC restart while playing
            self.assertEqual(self.aoc.commands[-1][3], 3000)
            self.play(False)
            d.tick()
            self.assertFalse(d.orientation.claimed)
            tuner.stop()
        self.assertEqual(self.aoc.violations, [])
        self.assertTrue(no_payload_in(lc.text))

    def test_playback_detection(self):
        p = st.Playback(self.asound)
        self.assertEqual(p.card(), 1)
        self.assertFalse(p.running())
        self.play(True)
        self.assertTrue(p.running())


class ConfigTest(unittest.TestCase):
    def test_config(self):
        self.assertEqual(st.Config({}).mode, 'off')
        for bad in ({'OMAMOBILE_SPK_TUNING': 'loud'}, {'OMAMOBILE_SPK_TUNING_VOLUME': '2'},
                    {'OMAMOBILE_SPK_TUNING_LEFT_UP': '45'}):
            with self.assertRaises(ValueError):
                st.Config(bad)
        c = st.Config({'OMAMOBILE_SPK_TUNING_LEFT_UP': '270'})
        self.assertEqual((c.angles['left-up'], c.angles['right-up']), (270, 90))


if __name__ == '__main__':
    unittest.main()
