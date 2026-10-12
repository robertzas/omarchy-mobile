# SPDX-License-Identifier: MIT
"""Read the CS35L41 protection firmware's state on the AoC sound card.

Used by omandroid-speaker-protection (AOC-PLAN.md stages C8/C9):

  status            the DSPs' state, decoded (never the calibration values)
  health            the amplifiers held awake, the DSP controls there, no error
                    state, no amplifier error in the kernel log since the
                    service started; exit 0 only if all hold
  monitor           the same as one line per amplifier, every --interval s
  watch             the protection watchdog: always, that the amplifiers stay
                    held awake, within the levels, and that the kernel logs
                    no amplifier/DSP failure (CSPL error, failed wake, failed
                    resume); while the speaker PCM runs, also that both DSPs
                    run the protection firmware with the calibration applied.
                    Mutes both amplifiers (through "omandroid-speaker-protection
                    mute") on any failure and exits
  verify            the watch checks plus liveness and plausibility over a few
                    seconds of playback; exit 0 only if all pass
  signal            write a test signal (1 kHz tone or pink multitone) as WAV

Controls are read through alsa-lib (ctypes), one element at a time by name.
Only the amplifiers' controls are read: reading an AoC control can send a
command to the AoC.

Formats, from the stock HAL library (vendor/lib64/audio_spk_35l41.so):
  CSPL_TEMPERATURE, BDLOG_MAX_TEMP  unsigned Q14, degrees C ("Max temp: 0x%x
                                    ==> %f C" converts with ucvtf #14)
  BDLOG_MAX_EXC                     unsigned Q19, mm ("Max exc" with ucvtf #19)
  SPK_OUTPUT_POWER                  raw / 2^23 * 667.1889 (its ConvertRawToPower)
States: HALO_STATE 2 = running (mainline cs35l41_hda.h HALO_STATE_CODE_RUN);
CSPL_STATE 0 running, 1 error, 2 muted, 3 reiniting, 6 diagnosing (Google's
cs35l41.h enum cs35l41_cspl_st); CAL_SET_STATUS 2 = calibration applied,
1 = firmware defaults (the stock HAL's check).
"""
import argparse
import ctypes
import ctypes.util
import glob
import json
import math
import os
import re
import struct
import subprocess
import sys
import time
import wave

AMPS = ('Top', 'Bottom')
NAME_MAX = 43          # SNDRV_CTL_ELEM_ID_NAME_MAXLEN - 1
DSP_KEYS = ('HALO_STATE', 'HALO_HEARTBEAT', 'CSPL_STATE', 'CSPL_ERRORNO', 'CAL_SET_STATUS',
            'CSPL_TEMPERATURE', 'CSPL_ATTENUATION', 'SPK_OUTPUT_POWER', 'BDLOG_MAX_TEMP',
            'BDLOG_MAX_EXC', 'BDLOG_OVER_TEMP_COUNT', 'BDLOG_OVER_EXC_COUNT', 'BDLOG_ABNORMAL_MUTE')
AMP_KEYS = ('PCM Source', 'Digital PCM Volume', 'Analog PCM Volume')
DELTA_KEYS = ('CSPL_UPDATE_PARAMS_CONFIG', 'CSPL_COMMAND')
CSPL_CMD_UPDATE_PARAM = 8
CSPL_STATES = {0: 'running', 1: 'error', 2: 'muted', 3: 'reiniting', 6: 'diagnosing'}
HALO_RUN = 2
CAL_APPLIED = 2


def q(v, bits):
    return None if v is None else v / float(1 << bits)


def log(msg):
    print(f'omandroid-speaker: {msg}', flush=True)


# --- control access ---------------------------------------------------------

class AlsaCtl:
    """alsa-lib's control interface, by element name."""
    BOOLEAN, INTEGER, ENUMERATED, BYTES = 1, 2, 3, 4
    IFACE_MIXER = 2

    def __init__(self, card):
        lib = ctypes.util.find_library('asound') or 'libasound.so.2'
        a = self.a = ctypes.CDLL(lib)
        vp = ctypes.c_void_p
        for fn, res, args in (
                ('snd_ctl_open', ctypes.c_int, [ctypes.POINTER(vp), ctypes.c_char_p, ctypes.c_int]),
                ('snd_ctl_close', ctypes.c_int, [vp]),
                ('snd_ctl_elem_list_malloc', ctypes.c_int, [ctypes.POINTER(vp)]),
                ('snd_ctl_elem_list', ctypes.c_int, [vp, vp]),
                ('snd_ctl_elem_list_get_count', ctypes.c_uint, [vp]),
                ('snd_ctl_elem_list_alloc_space', ctypes.c_int, [vp, ctypes.c_uint]),
                ('snd_ctl_elem_list_get_used', ctypes.c_uint, [vp]),
                ('snd_ctl_elem_list_get_name', ctypes.c_char_p, [vp, ctypes.c_uint]),
                ('snd_ctl_elem_id_malloc', ctypes.c_int, [ctypes.POINTER(vp)]),
                ('snd_ctl_elem_id_clear', None, [vp]),
                ('snd_ctl_elem_id_set_interface', None, [vp, ctypes.c_int]),
                ('snd_ctl_elem_id_set_name', None, [vp, ctypes.c_char_p]),
                ('snd_ctl_elem_info_malloc', ctypes.c_int, [ctypes.POINTER(vp)]),
                ('snd_ctl_elem_info_set_id', None, [vp, vp]),
                ('snd_ctl_elem_info_get_id', None, [vp, vp]),
                ('snd_ctl_elem_info', ctypes.c_int, [vp, vp]),
                ('snd_ctl_elem_info_get_type', ctypes.c_int, [vp]),
                ('snd_ctl_elem_info_get_count', ctypes.c_uint, [vp]),
                ('snd_ctl_elem_info_get_max', ctypes.c_long, [vp]),
                ('snd_ctl_elem_info_set_item', None, [vp, ctypes.c_uint]),
                ('snd_ctl_elem_info_get_item_name', ctypes.c_char_p, [vp]),
                ('snd_ctl_elem_value_malloc', ctypes.c_int, [ctypes.POINTER(vp)]),
                ('snd_ctl_elem_value_set_id', None, [vp, vp]),
                ('snd_ctl_elem_read', ctypes.c_int, [vp, vp]),
                ('snd_ctl_elem_value_get_boolean', ctypes.c_int, [vp, ctypes.c_uint]),
                ('snd_ctl_elem_value_get_integer', ctypes.c_long, [vp, ctypes.c_uint]),
                ('snd_ctl_elem_value_get_enumerated', ctypes.c_uint, [vp, ctypes.c_uint]),
                ('snd_ctl_elem_value_get_byte', ctypes.c_ubyte, [vp, ctypes.c_uint]),
                ('snd_ctl_elem_value_set_byte', None, [vp, ctypes.c_uint, ctypes.c_ubyte]),
                ('snd_ctl_elem_write', ctypes.c_int, [vp, vp])):
            f = getattr(a, fn)
            f.restype, f.argtypes = res, args
        self.h = vp()
        if a.snd_ctl_open(ctypes.byref(self.h), f'hw:{card}'.encode(), 0) < 0:
            raise OSError(f'cannot open the control device of card {card}')
        self.id, self.info, self.val = vp(), vp(), vp()
        a.snd_ctl_elem_id_malloc(ctypes.byref(self.id))
        a.snd_ctl_elem_info_malloc(ctypes.byref(self.info))
        a.snd_ctl_elem_value_malloc(ctypes.byref(self.val))

    def names(self):
        a, lst = self.a, ctypes.c_void_p()
        a.snd_ctl_elem_list_malloc(ctypes.byref(lst))
        if a.snd_ctl_elem_list(self.h, lst) < 0:
            return []
        n = a.snd_ctl_elem_list_get_count(lst)
        if a.snd_ctl_elem_list_alloc_space(lst, n) < 0 or a.snd_ctl_elem_list(self.h, lst) < 0:
            return []
        return [a.snd_ctl_elem_list_get_name(lst, i).decode(errors='replace')
                for i in range(a.snd_ctl_elem_list_get_used(lst))]

    def _info(self, name):
        a = self.a
        # Clear the numid the last lookup copied back: ALSA finds a control by
        # numid first, so a stale one returned the previous control.
        a.snd_ctl_elem_id_clear(self.id)
        a.snd_ctl_elem_id_set_interface(self.id, self.IFACE_MIXER)
        a.snd_ctl_elem_id_set_name(self.id, name.encode())
        a.snd_ctl_elem_info_set_id(self.info, self.id)
        if a.snd_ctl_elem_info(self.h, self.info) < 0:
            return None
        a.snd_ctl_elem_info_get_id(self.info, self.id)    # with its numid
        return a.snd_ctl_elem_info_get_type(self.info)

    def read(self, name):
        """Integer, boolean (0/1), enumerated (item name) or bytes (big-endian
        integer, as cs_dsp words are); None if it cannot be read."""
        a = self.a
        t = self._info(name)
        if t is None:
            return None
        count = a.snd_ctl_elem_info_get_count(self.info)
        items = None
        if t == self.ENUMERATED:
            idx = None
        a.snd_ctl_elem_value_set_id(self.val, self.id)
        if a.snd_ctl_elem_read(self.h, self.val) < 0:
            return None
        if t == self.BOOLEAN:
            return a.snd_ctl_elem_value_get_boolean(self.val, 0)
        if t == self.INTEGER:
            return a.snd_ctl_elem_value_get_integer(self.val, 0)
        if t == self.BYTES:
            v = 0
            for i in range(count):
                v = (v << 8) | a.snd_ctl_elem_value_get_byte(self.val, i)
            return v
        if t == self.ENUMERATED:
            idx = a.snd_ctl_elem_value_get_enumerated(self.val, 0)
            a.snd_ctl_elem_info_set_item(self.info, idx)
            if a.snd_ctl_elem_info(self.h, self.info) < 0:
                return None
            return a.snd_ctl_elem_info_get_item_name(self.info).decode()
        return None


    def read_bytes(self, name):
        a = self.a
        if self._info(name) != self.BYTES:
            return None
        count = a.snd_ctl_elem_info_get_count(self.info)
        a.snd_ctl_elem_value_set_id(self.val, self.id)
        if a.snd_ctl_elem_read(self.h, self.val) < 0:
            return None
        return bytes(a.snd_ctl_elem_value_get_byte(self.val, i) for i in range(count))

    def write_bytes(self, name, data):
        a = self.a
        if self._info(name) != self.BYTES:
            return False
        count = a.snd_ctl_elem_info_get_count(self.info)
        if len(data) != count:
            return False
        a.snd_ctl_elem_value_set_id(self.val, self.id)
        for i, b in enumerate(data):
            a.snd_ctl_elem_value_set_byte(self.val, i, b)
        return a.snd_ctl_elem_write(self.h, self.val) >= 0


class JsonCtl:
    """The state file of test/fake-amixer (tests only)."""

    def __init__(self, path):
        self.path = path

    def _load(self):
        try:
            with open(self.path) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def names(self):
        return list(self._load())

    def read(self, name):
        state = self._load()
        c = state.get(name)
        if c is None:
            return None
        t = c['type']
        if t == 'BYTES':
            v = 0
            for b in c['v']:
                v = (v << 8) | b
            if name.endswith('HALO_HEARTBEAT') and os.environ.get('FAKE_HB_STUCK') != '1':
                v += 1           # the firmware's heartbeat moves while it runs
                c['v'] = list(v.to_bytes(4, 'big'))
                with open(self.path, 'w') as f:
                    json.dump(state, f)
            return v
        if t == 'ENUMERATED':
            return c['items'][c['v']]
        return c['v']


    def read_bytes(self, name):
        c = self._load().get(name)
        return bytes(c['v']) if c and c['type'] == 'BYTES' else None

    def write_bytes(self, name, data):
        state = self._load()
        c = state.get(name)
        if not c or c['type'] != 'BYTES' or len(c['v']) != len(data):
            return False
        c['v'] = list(data)
        if name.endswith('CSPL_COMMAND') and int.from_bytes(data, 'big') == 8:
            # the fake firmware takes the parameter update and stays running
            log_path = os.environ.get('FAKE_DELTA_LOG')
            if log_path:
                with open(log_path, 'a') as f:
                    f.write(name + '\n')
        with open(self.path, 'w') as f:
            json.dump(state, f)
        return True


def open_ctl(card):
    backend = os.environ.get('OMANDROID_CTL_BACKEND', '')
    if backend.startswith('json:'):
        return JsonCtl(backend[5:])
    return AlsaCtl(card)


def resolve(names, amp, key):
    """The full name of a DSP firmware control: "<amp> DSP1 <fw> <alg> <key>".
    wm_adsp cuts a long name to 43 characters by dropping the start of the
    key, so a 43-character name whose last word ends the key matches too.
    The protection algorithm (cd) wins over others."""
    best = None
    for n in names:
        if not n.startswith(f'{amp} DSP1 '):
            continue
        tok = n.rsplit(' ', 1)[-1]
        if tok == key or (len(n) == NAME_MAX and len(tok) >= 4 and key.endswith(tok)):
            if best is None or (' cd ' in n and ' cd ' not in best):
                best = n
    return best


class Amps:
    def __init__(self, card):
        self.ctl = open_ctl(card)
        names = self.ctl.names()
        self.names = {}
        for amp in AMPS:
            for key in DSP_KEYS + DELTA_KEYS:
                self.names[amp, key] = resolve(names, amp, key)
            for key in AMP_KEYS:
                self.names[amp, key] = f'{amp} {key}'

    def read(self, keys=DSP_KEYS + AMP_KEYS):
        out = {}
        for amp in AMPS:
            for key in keys:
                n = self.names.get((amp, key))
                out[amp, key] = self.ctl.read(n) if n else None
        return out


# --- the card and its speaker PCM ---------------------------------------------

ASOUND = os.environ.get('OMANDROID_ASOUND', '/proc/asound')


def find_card():
    try:
        with open(f'{ASOUND}/cards') as f:
            for line in f:
                m = re.match(r'\s*(\d+) \[[^]]*\]: aoc-snd-card - ', line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return None


def speaker_pcm_status(card):
    """/proc path of the EP6 playback substream's status, found by PCM id."""
    for info in sorted(glob.glob(f'{ASOUND}/card{card}/pcm*p/info')):
        try:
            with open(info) as f:
                if re.search(r'^id: EP6 playback', f.read(), re.M):
                    return os.path.join(os.path.dirname(info), 'sub0', 'status')
        except OSError:
            pass
    return None


def running(status_path):
    try:
        with open(status_path) as f:
            return f.readline().strip() == 'state: RUNNING'
    except (OSError, TypeError):
        return False


SPIDEVS = os.environ.get('OMANDROID_SPIDEVS', '/sys/bus/spi/devices')
NODES = {'Top': 'amplifier@0', 'Bottom': 'amplifier@1'}


def amp_devices():
    out = {}
    for d in sorted(glob.glob(f'{SPIDEVS}/*')):
        node = os.path.basename(os.path.realpath(os.path.join(d, 'of_node')))
        for amp, n in NODES.items():
            if node == n:
                out[amp] = d
    return out


def pm_state(dev):
    def rd(f):
        try:
            with open(os.path.join(dev, 'power', f)) as fh:
                return fh.read().strip()
        except OSError:
            return None
    return rd('control'), rd('runtime_status')


def pm_problems(devs):
    problems = []
    for amp in AMPS:
        d = devs.get(amp)
        if d is None:
            problems.append(f'{amp}: no SPI device')
            continue
        c, s = pm_state(d)
        if c != 'on' or s != 'active':
            problems.append(f'{amp} ({os.path.basename(d)}): power/control {c}, runtime_status {s}: '
                            'not held awake (runtime hibernate breaks this firmware)')
    return problems


# Kernel log lines that mean an amplifier's DSP is broken until it is reset
# (C8e: a failed hibernate wake, then CSPL errors and a PCM that cannot open).
KMSG_FATAL = re.compile(
    r'cs35l41 \S+: (CSPL Error Detected|Wake failed|Timed out waking device|Firmware status is invalid|'
    r'Failed to restore register cache|Failed to set mailbox cmd [02-9])'
    r'|(PRE_PMU|POST_PMU): (Top|Bottom) DSP1 event failed'
    r'|snd_soc_pcm_component_pm_runtime_get')
# Seen at every stream stop with this firmware (the pause is not acknowledged);
# logged, not fatal: the stream checks catch a DSP that does not come back.
KMSG_WARN = re.compile(r'cs35l41 \S+: Failed to set mailbox cmd 1|PRE_PMD: (Top|Bottom) DSP1 event failed')
KMSG = os.environ.get('OMANDROID_KMSG', '/dev/kmsg')


class Kmsg:
    """The kernel log, as /dev/kmsg records ("pri,seq,usec,flags;text")."""

    def __init__(self, path=KMSG, follow=False):
        self.path = path
        self.dev = os.path.exists(path) and not os.path.isfile(path)
        self.fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        self.pos = 0
        if follow:
            if self.dev:
                os.lseek(self.fd, 0, os.SEEK_END)
            else:
                self.pos = os.fstat(self.fd).st_size

    def records(self):
        """New records as (seconds, text)."""
        out = []
        if self.dev:
            while True:
                try:
                    rec = os.read(self.fd, 8192)
                except BlockingIOError:
                    break
                except OSError:          # EPIPE: records overwritten; go on
                    continue
                if not rec:
                    break
                out.append(rec.decode(errors='replace'))
        else:
            os.lseek(self.fd, self.pos, os.SEEK_SET)
            data = b''
            while True:
                chunk = os.read(self.fd, 65536)
                if not chunk:
                    break
                data += chunk
            self.pos += len(data)
            out = data.decode(errors='replace').splitlines()
        recs = []
        for r in out:
            head, _, text = r.partition(';')
            f = head.split(',')
            try:
                t = int(f[2]) / 1e6
            except (IndexError, ValueError):
                continue
            recs.append((t, text.split('\n')[0]))
        return recs


def kmsg_problems(records, since=0.0):
    fatal, warn = [], []
    for t, text in records:
        if t < since:
            continue
        if KMSG_FATAL.search(text):
            fatal.append(f'[{t:.2f}] {text}')
        elif KMSG_WARN.search(text):
            warn.append(f'[{t:.2f}] {text}')
    return fatal, warn


# --- limits and checks --------------------------------------------------------

def ceilings():
    """This stage's ceilings, the same numbers the service checks before it
    unmutes: digital, then analog per amplifier (c8: the top drives the
    earpiece, AUDIO-PLAN.md section 4; c9: stock's 817 and 17 on both)."""
    if os.environ.get('OMANDROID_SPK_STAGE', 'c8') == 'c9':
        return 817, {'Top': 17, 'Bottom': 17}
    return 657, {'Top': 6, 'Bottom': 10}


def check(v, digital_ceil, analog_ceil, temp_max, strict=True):
    """Problems with one reading of both amplifiers (empty if none). With
    strict, the checks that only hold once the DSP runs a stream are on."""
    problems = []
    for amp in AMPS:
        g = lambda k: v.get((amp, k))
        if g('PCM Source') != 'DSP':
            problems.append(f'{amp}: PCM Source is {g("PCM Source")}, not DSP')
        d, a = g('Digital PCM Volume'), g('Analog PCM Volume')
        if d is None or d > digital_ceil:
            problems.append(f'{amp}: Digital PCM Volume {d} above {digital_ceil}')
        if a is None or a > analog_ceil[amp]:
            problems.append(f'{amp}: Analog PCM Volume {a} above {analog_ceil[amp]}')
        if not strict:
            continue
        if g('HALO_STATE') != HALO_RUN:
            problems.append(f'{amp}: HALO_STATE {g("HALO_STATE")}, not running')
        if g('CSPL_STATE') != 0:
            s = g('CSPL_STATE')
            problems.append(f'{amp}: CSPL_STATE {s} ({CSPL_STATES.get(s, "unknown")})')
        if g('CSPL_ERRORNO') != 0:
            problems.append(f'{amp}: CSPL_ERRORNO {g("CSPL_ERRORNO")}')
        if g('CAL_SET_STATUS') != CAL_APPLIED:
            problems.append(f'{amp}: CAL_SET_STATUS {g("CAL_SET_STATUS")}, calibration not applied')
        if g('BDLOG_ABNORMAL_MUTE') not in (None, 0):
            problems.append(f'{amp}: BDLOG_ABNORMAL_MUTE {g("BDLOG_ABNORMAL_MUTE")}')
        t = q(g('CSPL_TEMPERATURE'), 14)
        if t is None or t > temp_max:
            problems.append(f'{amp}: coil temperature {t} above {temp_max} C')
    return problems


def mute(reason):
    script = os.environ.get('OMANDROID_SPK_SCRIPT', '/usr/bin/omandroid-speaker-protection')
    subprocess.run([script, 'mute', '--reason', reason], check=False)


def fmt(v, amp):
    g = lambda k: v.get((amp, k))
    t, mt, mx = q(g('CSPL_TEMPERATURE'), 14), q(g('BDLOG_MAX_TEMP'), 14), q(g('BDLOG_MAX_EXC'), 19)
    p = g('SPK_OUTPUT_POWER')
    s = g('CSPL_STATE')
    f = lambda x, n: '-' if x is None else f'{x:.{n}f}'
    return (f'{amp:6} temp {f(t, 2)} C, attenuation {g("CSPL_ATTENUATION")}, power '
            f'{f(None if p is None else p / float(1 << 23) * 667.1889, 4)} (raw {p}), '
            f'state {s} ({CSPL_STATES.get(s, "?")}), errorno {g("CSPL_ERRORNO")}, '
            f'halo {g("HALO_STATE")}, heartbeat {g("HALO_HEARTBEAT")}, cal {g("CAL_SET_STATUS")}; '
            f'max temp {f(mt, 2)} C, max exc {f(mx, 4)} mm, over temp {g("BDLOG_OVER_TEMP_COUNT")}, '
            f'over exc {g("BDLOG_OVER_EXC_COUNT")}, abnormal mute {g("BDLOG_ABNORMAL_MUTE")}; '
            f'{g("PCM Source")} {g("Digital PCM Volume")}/{g("Analog PCM Volume")}')


# --- commands ---------------------------------------------------------------

def cmd_status(args):
    amps = Amps(args.card)
    v = amps.read()
    for amp in AMPS:
        missing = [k for k in DSP_KEYS if amps.names[amp, k] is None]
        print('  ' + fmt(v, amp))
        if missing:
            print(f'  {amp}: no control for {", ".join(missing)}')
    return 0


def since_start():
    run = os.environ.get('OMANDROID_RUN', '/run/omandroid')
    try:
        with open(f'{run}/speaker-protection-since') as f:
            return float(f.read())
    except (OSError, ValueError):
        return 0.0


def cmd_health(args):
    since = args.since if args.since is not None else since_start()
    problems = pm_problems(amp_devices())
    amps = Amps(args.card)
    for amp in AMPS:
        for key in ('HALO_STATE', 'CSPL_STATE', 'CSPL_ERRORNO', 'CAL_SET_STATUS', 'CSPL_TEMPERATURE', 'HALO_HEARTBEAT'):
            if amps.names[amp, key] is None:
                problems.append(f'{amp}: no {key} control (protection firmware not loaded)')
    v = amps.read(('CSPL_STATE', 'CSPL_ERRORNO'))
    for amp in AMPS:
        if v[amp, 'CSPL_STATE'] == 1:
            problems.append(f'{amp}: CSPL_STATE 1 (error)')
        if v[amp, 'CSPL_ERRORNO'] not in (None, 0):
            problems.append(f'{amp}: CSPL_ERRORNO {v[amp, "CSPL_ERRORNO"]}')
    try:
        fatal, warn = kmsg_problems(Kmsg().records(), since)
    except OSError as e:
        fatal, warn = [f'cannot read the kernel log: {e}'], []
    problems += fatal
    for w in warn:
        print(f'note: {w}')
    if problems:
        print('not healthy: ' + '; '.join(problems))
        return 1
    print(f'healthy: both amplifiers held awake, protection firmware controls present, '
          f'no amplifier errors in the kernel log since {since:.1f} s')
    return 0


def cmd_monitor(args):
    amps = Amps(args.card)
    pcm = speaker_pcm_status(args.card)
    end = time.monotonic() + args.duration
    while True:
        v = amps.read()
        stamp = time.strftime('%H:%M:%S')
        for amp in AMPS:
            print(f'{stamp} {"RUN " if running(pcm) else "idle"} {fmt(v, amp)}', flush=True)
        if time.monotonic() >= end:
            return 0
        time.sleep(args.interval)


FW_DIRS = os.environ.get('OMANDROID_FW_DIRS', '/usr/lib/firmware/updates /usr/lib/firmware').split()
DELTA_FILES = {'Top': 'cirrus/cs35l41-cheetah-top-media-delta.txt',
               'Bottom': 'cirrus/cs35l41-cheetah-bottom-media-delta.txt'}


def load_delta(amp):
    """Stock's media "fast use case" delta for this amplifier (vendor
    fast_switch3.txt for the top, fast_switch4.txt for the bottom, which the
    stock speaker path loads after the stream starts: "load Bypass FIR"), as
    big-endian words: the word count first, then the parameters (the format
    Google's cs35l41 driver parses)."""
    for d in FW_DIRS:
        path = os.path.join(d, DELTA_FILES[amp])
        try:
            with open(path) as f:
                words = [int(x) for x in f.read().replace(' ', '').replace('\n', '').split(',') if x]
        except OSError:
            continue
        except ValueError:
            return None
        if not words or words[0] != len(words):
            return None
        return b''.join(struct.pack('>i', w) for w in words)
    return None


def apply_delta(amps, amp):
    """Write the delta to CSPL_UPDATE_PARAMS_CONFIG, send CSPL_CMD_UPDATE_PARAM,
    and check that the firmware is running again, as Google's driver does."""
    data = load_delta(amp)
    cfg, cmd = amps.names.get((amp, DELTA_KEYS[0])), amps.names.get((amp, DELTA_KEYS[1]))
    if data is None or cfg is None or cmd is None:
        return f'{amp}: no media delta or no CSPL_UPDATE_PARAMS_CONFIG/CSPL_COMMAND control'
    cur = amps.ctl.read_bytes(cfg)
    if cur is None or len(cur) < len(data):
        return f'{amp}: CSPL_UPDATE_PARAMS_CONFIG is {None if cur is None else len(cur)} bytes, the delta {len(data)}'
    if not amps.ctl.write_bytes(cfg, data + cur[len(data):]):
        return f'{amp}: writing CSPL_UPDATE_PARAMS_CONFIG failed'
    if not amps.ctl.write_bytes(cmd, struct.pack('>I', CSPL_CMD_UPDATE_PARAM)):
        return f'{amp}: writing CSPL_COMMAND failed'
    for _ in range(50):
        if amps.ctl.read(amps.names[amp, 'CSPL_STATE']) == 0:
            return None
        time.sleep(0.002)
    return f'{amp}: CSPL_STATE not running after the media delta'


def cmd_watch(args):
    digital_ceil, analog_ceil = ceilings()
    strict_hb = os.environ.get('OMANDROID_SPK_STAGE', 'c8') == 'c9' or \
        os.environ.get('OMANDROID_SPK_HEARTBEAT', '1') == '2'
    temp_max = float(os.environ.get('OMANDROID_SPK_TEMP_MAX', '80'))
    amps = Amps(args.card)
    devs = amp_devices()
    try:
        kmsg = Kmsg(follow=True)
    except OSError as e:
        log(f'watchdog: cannot read the kernel log: {e}')
        mute('watchdog: no kernel log')
        return 1
    pcm = speaker_pcm_status(args.card)
    if pcm is None:
        log('watchdog: no EP6 playback PCM on the card')
        mute('watchdog: no speaker PCM')
        return 1
    log(f'watchdog: watching {pcm}, ceilings digital {digital_ceil} analog {analog_ceil}, '
        f'heartbeat {"enforced" if strict_hb else "logged"}')
    since = None
    beat = {}
    warned = False
    media_delta = os.environ.get('OMANDROID_SPK_MEDIA_DELTA', '0') == '1'
    applied = False
    problems_delta = []
    failures = 0
    n = 0
    while args.iterations == 0 or n < args.iterations:
        n += 1
        now = time.monotonic()
        fatal, warn = kmsg_problems(kmsg.records())
        for w in warn:
            log(f'watchdog: note: {w}')
        if fatal:
            reason = 'watchdog: amplifier failure in the kernel log: ' + '; '.join(fatal)
            log(reason)
            mute(reason)
            return 1
        pm = pm_problems(devs)
        if pm:
            reason = 'watchdog: ' + '; '.join(pm)
            log(reason)
            mute(reason)
            return 1
        if not running(pcm):
            since = None
            # Levels are checked when idle too: nobody raises them by hand.
            v = amps.read(AMP_KEYS)
            problems = check(v, digital_ceil, analog_ceil, temp_max, strict=False)
        else:
            if since is None:
                since = now
                beat = {}
                applied = False
                problems_delta = []
            strict = now - since >= args.grace
            if strict and media_delta and not applied:
                applied = True
                for amp in AMPS:
                    err = apply_delta(amps, amp)
                    if err:
                        problems_delta.append(err)
                    else:
                        log(f'watchdog: {amp}: stock media delta applied')
            v = amps.read()
            problems = check(v, digital_ceil, analog_ceil, temp_max, strict=strict) + problems_delta
            for amp in AMPS:
                hb = v.get((amp, 'HALO_HEARTBEAT'))
                last = beat.get(amp)
                if last is None or hb != last[0]:
                    beat[amp] = (hb, now)
                elif strict and now - last[1] >= args.heartbeat_timeout:
                    msg = f'{amp}: HALO_HEARTBEAT stuck at {hb} for {now - last[1]:.0f} s'
                    if strict_hb:
                        problems.append(msg)
                    elif not warned:
                        log(f'watchdog: {msg} (logged only in stage c8)')
                        warned = True
        unreadable = [p for p in problems if ' None' in p]
        if problems and len(unreadable) == len(problems):
            failures += 1          # a read failed: allow a transient one
            if failures < 3:
                problems = []
        else:
            failures = 0
        if problems:
            reason = 'watchdog: ' + '; '.join(problems)
            log(reason)
            mute(reason)
            return 1
        time.sleep(args.interval)
    return 0


def cmd_verify(args):
    digital_ceil, analog_ceil = ceilings()
    temp_max = float(os.environ.get('OMANDROID_SPK_TEMP_MAX', '80'))
    amps = Amps(args.card)
    pcm = speaker_pcm_status(args.card)
    missing = [f'{a} {k}' for (a, k), n in amps.names.items() if n is None and k in
               ('HALO_STATE', 'HALO_HEARTBEAT', 'CSPL_STATE', 'CSPL_ERRORNO', 'CAL_SET_STATUS', 'CSPL_TEMPERATURE')]
    if missing:
        print('not verified: no control for ' + ', '.join(missing))
        return 1
    first, last, temps = {}, {}, {a: [] for a in AMPS}
    end = time.monotonic() + args.seconds
    problems = []
    while time.monotonic() < end:
        if not running(pcm):
            print('not verified: the speaker PCM is not running (play the test signal while this runs)')
            return 1
        v = amps.read()
        problems = check(v, digital_ceil, analog_ceil, temp_max)
        if problems:
            break
        for a in AMPS:
            hb = v[a, 'HALO_HEARTBEAT']
            first.setdefault(a, hb)
            last[a] = hb
            temps[a].append(q(v[a, 'CSPL_TEMPERATURE'], 14))
        time.sleep(args.interval)
    for a in AMPS:
        if first.get(a) == last.get(a):
            problems.append(f'{a}: HALO_HEARTBEAT did not move')
        if temps[a] and not all(args.temp_low <= t <= args.temp_high for t in temps[a]):
            problems.append(f'{a}: coil temperature {min(temps[a]):.1f}-{max(temps[a]):.1f} C outside '
                            f'{args.temp_low}-{args.temp_high} C (calibration or sense wrong?)')
    if all(temps[a] for a in AMPS):
        d = abs(sum(temps['Top']) / len(temps['Top']) - sum(temps['Bottom']) / len(temps['Bottom']))
        if d > args.temp_spread:
            problems.append(f'the two coil temperatures differ by {d:.1f} C (calibration records swapped?)')
    if problems:
        print('not verified: ' + '; '.join(problems))
        return 1
    print('verified: both DSPs run the protection firmware with the calibration applied, '
          f'heartbeat moving, coil temperatures {", ".join(f"{a} {temps[a][-1]:.2f} C" for a in AMPS)}')
    return 0


def multitone(level_db, seconds, rate=48000):
    """Pink-weighted multitone, 300 Hz - 8 kHz (no energy below 300 Hz: AUDIO-PLAN
    section 4), RMS at level_db dBFS, 50 ms fades."""
    freqs = [300 * (8000 / 300) ** (i / 39) for i in range(40)]
    phases = [(i * i * 0.61803) % 1 * 2 * math.pi for i in range(40)]   # spread peaks
    amps_ = [1 / math.sqrt(f) for f in freqs]
    n = int(seconds * rate)
    raw = [sum(a * math.sin(2 * math.pi * f * t / rate + p) for a, f, p in zip(amps_, freqs, phases))
           for t in range(min(n, rate))]                                  # one second, looped
    rms = math.sqrt(sum(x * x for x in raw) / len(raw))
    g = 10 ** (level_db / 20) / rms
    peak = max(abs(x) for x in raw) * g
    if peak > 10 ** (-1 / 20):
        g *= 10 ** (-1 / 20) / peak                                        # never above -1 dBFS peak
    fade = int(0.05 * rate)
    out = []
    for t in range(n):
        e = min(1.0, t / fade, (n - 1 - t) / fade)
        out.append(raw[t % len(raw)] * g * e)
    return out


def cmd_signal(args):
    rate = 48000
    n = int(args.seconds * rate)
    if args.kind == 'tone':
        a = 10 ** (args.level / 20) * math.sqrt(2)                           # RMS -> peak
        s = [a * math.sin(2 * math.pi * 1000 * t / rate) for t in range(n)]
    else:
        s = multitone(args.level, args.seconds, rate)
    left, right = {'both': (1, 1), 'left': (1, 0), 'right': (0, 1)}[args.channels]
    with wave.open(args.out, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b''.join(struct.pack('<hh', int(x * 32767 * left), int(x * 32767 * right)) for x in s))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog='speaker_dsp')
    ap.add_argument('--card', default=None)
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('status')
    h = sub.add_parser('health')
    h.add_argument('--since', type=float, default=None, help='kernel log seconds; default: the service start')
    m = sub.add_parser('monitor')
    m.add_argument('--interval', type=float, default=1.0)
    m.add_argument('--duration', type=float, default=10.0)
    w = sub.add_parser('watch')
    env = os.environ.get
    w.add_argument('--interval', type=float, default=float(env('OMANDROID_WATCH_INTERVAL', '1.0')))
    w.add_argument('--grace', type=float, default=float(env('OMANDROID_WATCH_GRACE', '2.0')))
    w.add_argument('--heartbeat-timeout', type=float, default=float(env('OMANDROID_WATCH_HB_TIMEOUT', '3.0')))
    w.add_argument('--iterations', type=int, default=int(env('OMANDROID_WATCH_ITERATIONS', '0')))
    v = sub.add_parser('verify')
    v.add_argument('--seconds', type=float, default=float(env('OMANDROID_VERIFY_SECONDS', '5.0')))
    v.add_argument('--interval', type=float, default=float(env('OMANDROID_VERIFY_INTERVAL', '0.5')))
    v.add_argument('--temp-low', type=float, default=10.0)
    v.add_argument('--temp-high', type=float, default=45.0)
    v.add_argument('--temp-spread', type=float, default=5.0)
    s = sub.add_parser('signal')
    s.add_argument('kind', choices=('tone', 'multitone'))
    s.add_argument('out')
    s.add_argument('--level', type=float, default=-20.0, help='RMS dBFS')
    s.add_argument('--seconds', type=float, default=2.0)
    s.add_argument('--channels', choices=('both', 'left', 'right'), default='both')
    args = ap.parse_args(argv)
    if args.cmd == 'signal':
        return cmd_signal(args)
    if args.card is None:
        args.card = find_card()
        if args.card is None:
            print('no AoC sound card')
            return 1
    return {'status': cmd_status, 'health': cmd_health, 'monitor': cmd_monitor, 'watch': cmd_watch,
            'verify': cmd_verify}[args.cmd](args)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
