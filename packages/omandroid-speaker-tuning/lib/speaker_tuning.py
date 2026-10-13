# SPDX-License-Identifier: MIT
"""omandroid-speaker-tuning: stock's speaker tuning (Waves MaxxAudio on the
AoC) for the Pixel 7 Pro's speakers.

Waves' own controller computes the AoC configuration from the user's
vendor files, in a chroot, through omandroid-waves-host; this daemon is the
only opener of the AoC's tuning devices and carries the controller's
buffers there, for the speaker mixer's Waves component only (block 16,
component 2). device/cheetah/AOC-TUNING-RESEARCH.md.

Policy (/etc/omandroid/speaker.conf or speaker-tuning.conf):
  OMANDROID_SPK_TUNING=off       (default) nothing is sent; the AoC plays flat
  OMANDROID_SPK_TUNING=throttle  SPEAKER_MUSIC_THROTTLE (the low-power mode)
  OMANDROID_SPK_TUNING=music     SPEAKER_MUSIC; needs the C9 verification stamp

It sends only while omandroid-speaker-watch is active (the protection
watchdog), when a speaker stream starts (and the AoC is in playback), when
the phone turns while one plays, and after an AoC restart. Logs carry
command and message IDs, sizes, SHA-256 prefixes and return codes, never
payloads.
"""
import errno
import hashlib
import os
import queue
import re
import select
import subprocess
import sys
import threading
import time

from aoc_tuning import BLOCK_SPEAKER, COMPONENT_WAVES, CMD_SET_GET_PARAM_BULK, ETIMEDOUT
from waves_host import HelperGone, Violation

AUDIO_DEVICE_OUT_SPEAKER = 0x2
AUDIO_MODE_NORMAL = 0
# custom action 258's third number (waves_config.ini): 0 enabled, 1 disabled
THROTTLE_STATE = {'throttle': 0, 'music': 1}
PRESETS = {'throttle': 'SPEAKER_MUSIC_THROTTLE', 'music': 'SPEAKER_MUSIC'}
MODES = ('off', 'throttle', 'music')

WATCH_UNIT = 'omandroid-speaker-watch.service'
HELPER = '/usr/lib/omandroid-speaker-tuning/omandroid-waves-host-run'
AOC_DEV = '/sys/bus/platform/devices/181d0000.aoc'
AOC_MARKER = '/run/omandroid/aoc-firmware-loaded'


def log(msg):
    print(f'omandroid-speaker-tuning: {msg}', file=sys.stderr, flush=True)


def sha(data):
    return hashlib.sha256(data).hexdigest()[:16]


def waves_id(payload):
    """The Waves message's own ID (its first u32), for the logs."""
    return int.from_bytes(payload[:4], 'little') if len(payload) >= 4 else None


class Config:
    def __init__(self, env=None):
        env = os.environ if env is None else env
        self.mode = env.get('OMANDROID_SPK_TUNING', 'off').strip() or 'off'
        if self.mode not in MODES:
            raise ValueError(f'OMANDROID_SPK_TUNING={self.mode!r} (off, throttle or music)')
        self.volume = float(env.get('OMANDROID_SPK_TUNING_VOLUME', '1.0'))
        if not 0.0 <= self.volume <= 1.0:
            raise ValueError('OMANDROID_SPK_TUNING_VOLUME must be 0..1')
        # iio-sensor-proxy's left-up: 90 or 270 degrees for Waves (T4.3)
        left = int(env.get('OMANDROID_SPK_TUNING_LEFT_UP', '90'))
        if left not in (90, 270):
            raise ValueError('OMANDROID_SPK_TUNING_LEFT_UP must be 90 or 270')
        self.angles = {'normal': 0, 'bottom-up': 180, 'left-up': left, 'right-up': 360 - left}
        self.run = env.get('OMANDROID_RUN', '/run/omandroid')
        self.state_dir = env.get('OMANDROID_STATE', '/var/lib/omandroid')
        self.helper = env.get('OMANDROID_SPK_TUNING_HELPER', HELPER)
        self.aoc_dev = env.get('OMANDROID_SPK_TUNING_AOC', AOC_DEV)
        self.aoc_marker = env.get('OMANDROID_SPK_TUNING_AOC_MARKER', AOC_MARKER)
        self.asound = env.get('OMANDROID_SPK_TUNING_ASOUND', '/proc/asound')

    @property
    def state_file(self):
        return os.path.join(self.run, 'speaker-tuning')

    @property
    def stamp(self):
        return os.path.join(self.state_dir, 'speaker-protection-verified')


def watch_active():
    r = subprocess.run(['systemctl', 'is-active', '--quiet', WATCH_UNIT])
    return r.returncode == 0


class Tuner:
    """Runs the helper and sends the current state through it.

    host_factory() -> a started WavesHost; port: an AocTuningPort (unused in
    a dry run); gate() -> None when sending is allowed, else the reason."""

    MAX_FAILURES = 3

    def __init__(self, cfg, host_factory, port, gate, dry_run=False, dry_rc=ETIMEDOUT,
                 record=None):
        self.cfg = cfg
        self.host_factory = host_factory
        self.port = port
        self.gate = gate
        self.dry_run = dry_run
        self.dry_rc = dry_rc
        self.record = record
        self.host = None
        self.initialized = False      # the controller has woken the DSP since its/the AoC's start
        self.version_asked = False
        self.failures = 0
        self.exchanges = 0
        self.errors = 0
        self.state = None
        if record:
            os.makedirs(record, mode=0o700, exist_ok=True)
            os.chmod(record, 0o700)

    # -- state for the watchdog and for people ---------------------------------

    def set_state(self, text):
        if text == self.state:
            return
        self.state = text
        log(f'state: {text}')
        try:
            os.makedirs(self.cfg.run, exist_ok=True)
            tmp = self.cfg.state_file + '.tmp'
            with open(tmp, 'w') as f:
                f.write(text + '\n')
            os.replace(tmp, self.cfg.state_file)
        except OSError as e:
            log(f'cannot write {self.cfg.state_file}: {e}')

    # -- exchanges --------------------------------------------------------------

    def _record(self, n, payload, rc, rx):
        if not self.record:
            return
        base = os.path.join(self.record, f'{n:04d}-{sha(payload)}')
        fd = os.open(base + '.tx', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'wb') as f:
            f.write(payload)
        if rx:
            fd = os.open(base + '.rx', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, 'wb') as f:
                f.write(rx)
        with open(os.path.join(self.record, 'exchanges.log'), 'a') as f:
            f.write(f'{n} {self.cfg.mode} {sha(payload)} {len(payload)} {rc} '
                    f'{sha(rx) if rx else "-"} {len(rx)}\n')

    def exchange(self, payload):
        """The helper's sender: one bulk exchange with the AoC."""
        self.exchanges += 1
        n = self.exchanges
        what = (f'exchange {n}: 0x{CMD_SET_GET_PARAM_BULK:04x} block {BLOCK_SPEAKER} '
                f'component {COMPONENT_WAVES}, waves id {waves_id(payload)}, '
                f'{len(payload)} bytes, sha256 {sha(payload)}')
        if self.dry_run:
            log(f'{what}: dry run, not sent (answered {self.dry_rc})')
            if self.dry_rc != 0:
                self.errors += 1
            self._record(n, payload, self.dry_rc, b'')
            return self.dry_rc, b''
        reason = self.gate()
        if reason:
            log(f'{what}: not sent, {reason}')
            self.errors += 1
            return -errno.EACCES, b''
        rc, rx = self.port.set_get_bulk(BLOCK_SPEAKER, COMPONENT_WAVES, payload)
        if rc == ETIMEDOUT:
            log(f'{what}: timed out, one retry')
            rc, rx = self.port.set_get_bulk(BLOCK_SPEAKER, COMPONENT_WAVES, payload)
        log(f'{what}: rc {rc}' + (f', reply {len(rx)} bytes, sha256 {sha(rx)}' if rx else ''))
        if rc != 0:
            self.errors += 1
        self._record(n, payload, rc, rx)
        return rc, rx

    # -- the helper -------------------------------------------------------------

    def _ensure_host(self):
        if self.host is not None and self.host.alive():
            return True
        self.host = None
        self.initialized = False
        self.version_asked = False
        try:
            self.host = self.host_factory()
            return True
        except (HelperGone, Violation, OSError) as e:
            self._failed(f'helper: {e}')
            return False

    def _failed(self, reason):
        self.failures += 1
        if self.host is not None:
            self.host.stop()
            self.host = None
        self.initialized = False
        self.set_state(f'failed {reason}')

    def stop(self):
        if self.host is not None:
            self.host.stop()
            self.host = None

    def aoc_restarted(self):
        """The AoC came back with fresh firmware: the tuning is gone."""
        if self.initialized:
            log('AoC restarted: the next send starts with a DSP wake-up')
        self.initialized = False
        self.failures = 0

    def send(self, angle):
        """Send the configured preset at this orientation. True when the
        controller's batch went through with every exchange answered 0."""
        mode = self.cfg.mode
        if mode == 'off':
            self.set_state('off')
            return False
        if self.failures >= self.MAX_FAILURES:
            log(f'not sending: {self.failures} failures (an AoC restart or a restart of this unit resets this)')
            return False
        if not self.dry_run:
            reason = self.gate()
            if reason:
                self.set_state(f'blocked {reason}')
                return False
        if not self._ensure_host():
            return False
        self.set_state('sending')
        self.errors = 0
        seq = []
        if not self.version_asked:
            seq.append('version dsp')
        seq.append('begin')
        if not self.initialized:
            seq.append('wake')
        seq += ['bypass 0', f'volume {self.cfg.volume:g}', f'orientation {angle}',
                f'route {AUDIO_DEVICE_OUT_SPEAKER} {AUDIO_MODE_NORMAL} {THROTTLE_STATE[mode]}',
                'flush']
        try:
            for cmd in seq:
                ok, detail = self.host.request(cmd, self.exchange)
                if cmd.startswith('version'):
                    self.version_asked = True
                    log(f'DSP Waves version: {detail.split(" ", 1)[1]}' if ok else
                        'DSP Waves version: not available')
                    continue
                if not ok:
                    self._failed(f'{cmd.split()[0]}: {detail or "refused"}')
                    return False
                if cmd == 'wake':
                    self.initialized = True
        except Violation as e:
            log(f'helper broke the protocol ({e}): restarting it')
            self._failed(f'protocol: {e}')
            return False
        except HelperGone as e:
            self._failed(f'helper: {e}')
            return False
        if self.errors:
            self.initialized = False
            self._failed(f'{self.errors} exchange(s) not accepted')
            return False
        self.failures = 0
        self.set_state(f'active {PRESETS[mode]} {angle}' + (' (dry run)' if self.dry_run else ''))
        return True


# -- triggers ------------------------------------------------------------------

class Playback:
    """Is a playback stream running on the AoC card?"""

    def __init__(self, asound='/proc/asound'):
        self.asound = asound

    def card(self):
        try:
            with open(os.path.join(self.asound, 'cards')) as f:
                for line in f:
                    m = re.match(r'\s*(\d+)\s+\[(\S+)\s*\]', line)
                    if m and 'aoc' in line.lower():
                        return int(m.group(1))
        except OSError:
            pass
        return None

    def running(self):
        c = self.card()
        if c is None:
            return False
        d = os.path.join(self.asound, f'card{c}')
        try:
            pcms = [p for p in os.listdir(d) if re.fullmatch(r'pcm\d+p', p)]
        except OSError:
            return False
        for p in pcms:
            try:
                subs = [s for s in os.listdir(os.path.join(d, p)) if s.startswith('sub')]
            except OSError:
                continue
            for s in subs:
                try:
                    with open(os.path.join(d, p, s, 'status')) as f:
                        if 'state: RUNNING' in f.read():
                            return True
                except OSError:
                    pass
        return False

    def dsp_state(self):
        """"Audio DSP State" (Idle, Playback, Telephony), or None if unknown."""
        c = self.card()
        if c is None:
            return None
        try:
            r = subprocess.run(['amixer', '-c', str(c), 'cget', 'name=Audio DSP State'],
                               capture_output=True, text=True, timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            return None
        items = dict(re.findall(r"Item #(\d+) '([^']*)'", r.stdout))
        m = re.search(r': values=(\d+)', r.stdout)
        return items.get(m.group(1)) if m else None


class AocRestarts:
    """Notices a new AoC firmware run: restart_count or the start marker."""

    def __init__(self, dev=AOC_DEV, marker=AOC_MARKER):
        self.dev = dev
        self.marker = marker
        self.last = self._read()

    def _read(self):
        try:
            with open(os.path.join(self.dev, 'restart_count')) as f:
                count = f.read().strip()
        except OSError:
            count = None
        try:
            mtime = os.stat(self.marker).st_mtime_ns
        except OSError:
            mtime = None
        return count, mtime

    def changed(self):
        now = self._read()
        if now != self.last:
            self.last = now
            return True
        return False


class SensorProxyOrientation:
    """iio-sensor-proxy's AccelerometerOrientation (net.hadess.SensorProxy on
    the system bus), claimed only while a speaker stream runs. Calls
    on_change(name) from its own thread."""

    def __init__(self, on_change):
        self.on_change = on_change
        self.ok = False
        self.claimed = False
        try:
            import gi
            gi.require_version('Gio', '2.0')
            from gi.repository import Gio, GLib
        except (ImportError, ValueError) as e:
            log(f'orientation: no PyGObject ({e}); assuming portrait')
            return
        self.Gio, self.GLib = Gio, GLib
        self.loop = GLib.MainLoop()
        self.proxy = None
        threading.Thread(target=self.loop.run, daemon=True).start()
        self.ok = True

    def _call(self, fn):
        done = threading.Event()

        def run():
            try:
                fn()
            except Exception as e:  # noqa: BLE001 (D-Bus errors of any kind)
                log(f'orientation: {e}')
            done.set()
            return False
        self.GLib.idle_add(run)
        done.wait(5)

    def claim(self):
        if not self.ok or self.claimed:
            return

        def do():
            if self.proxy is None:
                self.proxy = self.Gio.DBusProxy.new_for_bus_sync(
                    self.Gio.BusType.SYSTEM, self.Gio.DBusProxyFlags.NONE, None,
                    'net.hadess.SensorProxy', '/net/hadess/SensorProxy',
                    'net.hadess.SensorProxy', None)
                self.proxy.connect('g-properties-changed', self._changed)
            self.proxy.call_sync('ClaimAccelerometer', None, self.Gio.DBusCallFlags.NONE, 3000, None)
            self.claimed = True
            self._report()
        self._call(do)

    def release(self):
        if not self.ok or not self.claimed:
            return

        def do():
            self.claimed = False
            self.proxy.call_sync('ReleaseAccelerometer', None, self.Gio.DBusCallFlags.NONE, 3000, None)
        self._call(do)

    def _report(self):
        v = self.proxy.get_cached_property('AccelerometerOrientation')
        if v is not None:
            self.on_change(v.unpack())

    def _changed(self, proxy, changed, invalidated):
        if 'AccelerometerOrientation' in changed.keys():
            self._report()


class Daemon:
    """The trigger loop. tick() is one pass; run() loops."""

    HYSTERESIS = 1.0      # s an orientation must hold before a resend
    DSP_WAIT = 2.0        # s to wait for "Audio DSP State" = Playback

    def __init__(self, cfg, tuner, playback, restarts, orientation_factory=None, clock=time.monotonic):
        self.cfg = cfg
        self.tuner = tuner
        self.playback = playback
        self.restarts = restarts
        self.clock = clock
        self.events = queue.Queue()
        self.wake_r, self.wake_w = os.pipe()
        self.orientation = (orientation_factory or SensorProxyOrientation)(self._orientation)
        self.playing = False
        self.current = 'normal'
        self.since = 0.0
        self.sent_angle = None
        self.stopping = False

    def _orientation(self, name):
        self.events.put(name)
        try:
            os.write(self.wake_w, b'.')
        except OSError:
            pass

    def angle(self):
        return self.cfg.angles.get(self.current, 0)

    def _send(self, why):
        log(f'sending ({why}): {PRESETS.get(self.cfg.mode, self.cfg.mode)}, {self.angle()} degrees')
        if self.tuner.send(self.angle()):
            self.sent_angle = self.angle()
        else:
            self.sent_angle = None

    def _wait_dsp(self):
        deadline = self.clock() + self.DSP_WAIT
        while True:
            st = self.playback.dsp_state()
            if st in (None, 'Playback'):
                return st
            if self.clock() >= deadline:
                return st
            time.sleep(0.1)

    def tick(self):
        now = self.clock()
        while True:
            try:
                name = self.events.get_nowait()
            except queue.Empty:
                break
            if name in self.cfg.angles and name != self.current:
                self.current, self.since = name, now
        if self.restarts.changed():
            self.tuner.aoc_restarted()
            if self.playing:
                self._send('AoC restarted')
        playing = self.playback.running()
        if playing and not self.playing:
            self.playing = True
            self.orientation.claim()
            self.tuner.set_state('stream')
            st = self._wait_dsp()
            if st not in (None, 'Playback'):
                log(f'stream started but the AoC DSP is {st}: not sending (as stock)')
            else:
                self._send('stream start')
            self.since = self.clock() - self.HYSTERESIS
        elif not playing and self.playing:
            self.playing = False
            self.orientation.release()
            if self.tuner.state and self.tuner.state.startswith('active'):
                self.tuner.set_state('idle (' + self.tuner.state + ')')
        elif playing and self.sent_angle is not None and self.angle() != self.sent_angle \
                and now - self.since >= self.HYSTERESIS:
            self._send(f'orientation {self.current}')

    def run(self):
        if self.cfg.mode == 'off':
            self.tuner.set_state('off')
            log('OMANDROID_SPK_TUNING=off: nothing to do')
            return 0
        self.tuner.set_state('idle')
        while not self.stopping:
            self.tick()
            r, _, _ = select.select([self.wake_r], [], [], 0.5)
            if r:
                os.read(self.wake_r, 4096)
        self.orientation.release()
        self.tuner.stop()
        return 0
