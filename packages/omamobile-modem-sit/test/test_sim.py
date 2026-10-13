# SPDX-License-Identifier: MIT
"""The whole RIL against tools/sit-sim: the start-up sequence to IMS, then
SMS both ways and a call through the socket and the CLI. Needs SIT_SIM (the
simulator's path); skipped without it."""
import env  # noqa: F401  (paths and sys.path first)
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
BIN = HERE.parent / 'bin'
SIM = os.environ.get('SIT_SIM')
KEEP = os.environ.get('KEEP')


@unittest.skipUnless(SIM and Path(SIM).exists(), 'no simulator (set SIT_SIM)')
class SimulatorTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix='sit-sim-'))
        (self.dir / 'run').mkdir(mode=0o700)
        self.env = dict(os.environ,
                        OMAMOBILE_SIT_RUN=str(self.dir / 'run'),
                        OMAMOBILE_SIT_STATE=str(self.dir / 'state'),
                        OMAMOBILE_SIT_CONFIG=str(self.dir / 'modem-sit.conf'),
                        OMAMOBILE_SIT_DEVICE='unix:' + str(self.dir / 'ipc0'),
                        OMAMOBILE_SIT_ROUTER='unix:' + str(self.dir / 'router'),
                        OMAMOBILE_SIT_BOOT='none', PYTHONDONTWRITEBYTECODE='1')
        (self.dir / 'modem-sit.conf').write_text(
            '[network]\napn = internet.example\nsim_timeout = 20\nregister_timeout = 30\n'
            '[audio]\ncard = none\n')
        self.transcript = self.dir / 'transcript.jsonl'
        self.procs = []

    def tearDown(self):
        for proc in reversed(self.procs):
            if proc.poll() is None:
                proc.send_signal(signal.SIGTERM)
                try:
                    proc.wait(10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        for f in self.files:
            f.close()
        if KEEP:
            print('kept', self.dir, file=sys.stderr)
        else:
            subprocess.run(['rm', '-rf', str(self.dir)])

    files = []

    def start(self, *sim_args, daemon=True):
        sim_log = open(self.dir / 'sim.log', 'w')
        daemon_log = open(self.dir / 'daemon.log', 'w')
        self.files = [sim_log, daemon_log]
        self.procs.append(subprocess.Popen(
            [sys.executable, SIM, '--ipc', str(self.dir / 'ipc0'), '--router', str(self.dir / 'router'),
             '--transcript', str(self.transcript), *sim_args], stdout=sim_log, stderr=sim_log))
        deadline = time.monotonic() + 5
        while not (self.dir / 'router').exists() and time.monotonic() < deadline:
            time.sleep(.05)
        if not daemon:
            return
        self.daemon = subprocess.Popen([sys.executable, str(BIN / 'omamobile-sitd'), '--bringup'],
                                       env=self.env, stdout=daemon_log, stderr=subprocess.STDOUT)
        self.procs.append(self.daemon)

    def wait_ready(self, seconds=40):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if (self.dir / 'run' / 'socket').exists():
                return
            if self.daemon.poll() is not None:
                self.fail('daemon exited: ' + (self.dir / 'daemon.log').read_text())
            time.sleep(.1)
        self.fail('daemon not ready: ' + (self.dir / 'daemon.log').read_text())

    def cli(self, *args, check=True):
        result = subprocess.run([sys.executable, str(BIN / 'omamobile-sit'), *args], env=self.env,
                                capture_output=True, text=True, timeout=60)
        if check and result.returncode:
            self.fail(f'omamobile-sit {args}: {result.stdout}{result.stderr}')
        return result.stdout

    def transcript_entries(self):
        return [json.loads(line) for line in self.transcript.read_text().splitlines()]

    def test_bringup_sms_and_call(self):
        self.start('--incoming-sms')
        self.wait_ready()
        status = json.loads(self.cli('status', '--json'))
        modem = status['modem']
        self.assertEqual((modem['stage'], modem['voice'], modem['sms'], modem['data']),
                         ('running', True, True, True))
        # The incoming SMS arrives just after the IMS registration.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and 'hello' not in self.cli('sms', 'list'):
            time.sleep(.2)
        listed = json.loads(self.cli('sms', 'list', '--json'))
        self.assertEqual([m['text'] for m in listed], ['hello'])
        self.assertEqual(self.cli('sms', 'send', '+12025550199', 'omamobile test').strip(), 'sent')
        self.cli('sms', 'delete', listed[0]['id'])
        self.assertEqual(json.loads(self.cli('sms', 'list', '--json')), [])
        call = self.cli('dial', '+12025550199').strip()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            calls = json.loads(self.cli('status', '--json'))['calls']
            if calls and calls[0]['state'] == 'active':
                break
            time.sleep(.1)
        self.assertEqual(calls[0]['id'], call)
        self.cli('hangup')
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            calls = json.loads(self.cli('status', '--json'))['calls']
            if calls[0]['state'] == 'terminated':
                break
            time.sleep(.1)
        self.assertEqual(calls[0]['state'], 'terminated')
        public = (self.dir / 'run' / 'state.json').read_text()
        self.assertNotIn('2025550', public)

        entries = self.transcript_entries()
        self.assertFalse([e for e in entries if 'violation' in e])
        ids = [e['id'] for e in entries if e.get('type') == 'req']
        # The verified order: SIM, attach APN and profile, registration, NR
        # off, internet bearer, IMS stack, IMS bearer, ADD_PDN.
        order = [0x0200, 0x0603, 0x0613, 0x0701, 0x0748, 0x0600, 0x0d39, 0x0600, 0x0d08]
        positions = []
        start = 0
        for ident in order:
            start = ids.index(ident, start)
            positions.append(start)
        self.assertEqual(positions, sorted(positions))
        at = [e['cmd'] for e in entries if e.get('type') == 'at']
        self.assertEqual(at, ['AT+CFUN=0', 'AT+CFUN=1'])
        setups = [e for e in entries if e.get('event') == 'setup_data_call']
        self.assertEqual([(s['cid'], s['apn'], s['ip']) for s in setups],
                         [(1, 'internet.example', 3), (2, 'ims', 2)])
        log = (self.dir / 'daemon.log').read_text()
        for secret in ('2025550123', '2025550199', 'hello', 'omamobile test'):
            self.assertNotIn(secret, log)

        self.assertEqual(self.cli('radio', 'off').strip(), 'off')
        at = [e['cmd'] for e in self.transcript_entries() if e.get('type') == 'at']
        self.assertEqual(at[-1], 'AT+CFUN=0')

        self.daemon.send_signal(signal.SIGTERM)
        self.assertEqual(self.daemon.wait(15), 0)
        self.assertFalse((self.dir / 'run' / 'socket').exists())

    def test_probe_is_read_only(self):
        self.start(daemon=False)
        probe = subprocess.run([sys.executable, str(BIN / 'omamobile-sitd'), '--probe'], env=self.env,
                               capture_output=True, text=True, timeout=30)
        self.assertEqual(probe.returncode, 0, probe.stdout + probe.stderr)
        self.assertIn('SIM card state 1 applications [(2, 5)]', probe.stdout)
        entries = self.transcript_entries()
        self.assertFalse([e for e in entries if 'violation' in e or e.get('type') == 'at'])
        self.assertEqual(sorted({e['id'] for e in entries if e.get('type') == 'req'}),
                         [0x0108, 0x0200, 0x0701, 0x0711, 0x0749, 0x0801])

    def test_rejected_bearer_ends_startup_without_ims(self):
        self.start('--reject-setup', '36')
        self.assertNotEqual(self.daemon.wait(40), 0)
        ids = [e['id'] for e in self.transcript_entries() if e.get('type') == 'req']
        self.assertIn(0x0600, ids)
        self.assertNotIn(0x0d39, ids)
        self.assertNotIn(0x0d08, ids)
        self.assertFalse([e for e in self.transcript_entries() if 'violation' in e])

    def test_no_apn_never_switches_the_radio(self):
        (self.dir / 'modem-sit.conf').write_text('[audio]\ncard = none\n')
        self.start()
        self.assertNotEqual(self.daemon.wait(30), 0)
        self.assertFalse([e for e in self.transcript_entries() if e.get('type') == 'at'])


if __name__ == '__main__':
    unittest.main()
