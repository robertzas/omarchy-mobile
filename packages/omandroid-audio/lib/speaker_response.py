# SPDX-License-Identifier: MIT
"""Measure the built-in speakers' frequency response with stepped tones
(AOC-PLAN.md C9g), in plain Python (no numpy on the phone).

  gen OUT.wav --channel left|right [--level DBFS] [--fmin HZ] [--fmax HZ] [--per-octave N]
        the stimulus: silence, a 1 kHz marker, then one tone per step on one
        channel (left = the top speaker / earpiece, right = the bottom one)
  analyze REC.wav [same options] [--mic N]
        the response from a recording of it, made by any microphone (the
        phone's own, or a laptop's at the listening position): per step, the
        tone's level relative to the stimulus, by a windowed Goertzel at the
        known frequency, timed from the marker; the noise at each frequency
        from the silence before it
  suggest LEFT.json RIGHT.json
        a bounded starting point for omandroid-speaker-eq from two analyses

Levels are relative: a microphone's own response and its distance are in
them, so compare steps, speakers and settings measured the same way, not
absolute numbers. Tones at -30 dBFS RMS by default, 0.25 s each, 100 Hz up:
at the everyday amplifier level (stage media) that is far below what music
puts into the speakers.
"""
import argparse
import json
import math
import struct
import sys
import wave

RATE = 48000
PRE, MARK, AFTER_MARK, TONE, GAP, TAIL = 0.6, 0.3, 0.2, 0.25, 0.05, 0.5
FADE = 0.005
MARK_HZ = 1000.0


def steps(fmin=100.0, fmax=16000.0, per_octave=6):
    n = int(math.floor(math.log2(fmax / fmin) * per_octave + 1e-9))
    return [round(fmin * 2 ** (i / per_octave), 1) for i in range(n + 1)]


def tone(f, seconds, amp, rate=RATE):
    n = int(seconds * rate)
    fade = int(FADE * rate)
    out = []
    for t in range(n):
        e = 1.0
        if t < fade:
            e = 0.5 - 0.5 * math.cos(math.pi * t / fade)
        elif t >= n - fade:
            e = 0.5 - 0.5 * math.cos(math.pi * (n - 1 - t) / fade)
        out.append(amp * e * math.sin(2 * math.pi * f * t / rate))
    return out


def stimulus(freqs, level_db, rate=RATE):
    """Mono samples (the caller puts them on one channel)."""
    amp = 10 ** (level_db / 20) * math.sqrt(2)          # RMS -> peak
    s = [0.0] * int(PRE * rate)
    s += tone(MARK_HZ, MARK, amp, rate)
    s += [0.0] * int(AFTER_MARK * rate)
    for f in freqs:
        s += tone(f, TONE, amp, rate)
        s += [0.0] * int(GAP * rate)
    s += [0.0] * int(TAIL * rate)
    return s


def write_wav(path, samples, channel, rate=RATE):
    left, right = {'left': (1, 0), 'right': (0, 1), 'both': (1, 1)}[channel]
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b''.join(struct.pack('<hh', int(x * 32767 * left), int(x * 32767 * right))
                               for x in samples))


def read_wav(path):
    """(rate, [channel samples as floats in -1..1])."""
    with wave.open(path, 'rb') as w:
        rate, nch, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
        data = w.readframes(w.getnframes())
    if width == 2:
        vals = struct.unpack(f'<{len(data) // 2}h', data)
        scale = 32768.0
    elif width == 4:
        vals = struct.unpack(f'<{len(data) // 4}i', data)
        scale = 2147483648.0
    elif width == 3:
        vals = [int.from_bytes(data[i:i + 3], 'little', signed=True) for i in range(0, len(data), 3)]
        scale = 8388608.0
    else:
        raise ValueError(f'{width * 8}-bit WAV not supported')
    return rate, [[v / scale for v in vals[c::nch]] for c in range(nch)]


def goertzel_db(x, start, n, f, rate):
    """The amplitude of the sinusoid at f in x[start:start+n], Hann-windowed,
    as dB relative to a full-scale sine's RMS (so a -30 dBFS RMS tone reads
    -30)."""
    if start < 0 or start + n > len(x) or n <= 0:
        return None
    w = 2 * math.pi * f / rate
    coeff = 2 * math.cos(w)
    s1 = s2 = 0.0
    wsum = 0.0
    for i in range(n):
        h = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1))
        wsum += h
        s0 = x[start + i] * h + coeff * s1 - s2
        s2, s1 = s1, s0
    power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    amp = 2 * math.sqrt(max(power, 0.0)) / wsum             # peak amplitude
    rms = amp / math.sqrt(2)
    return 20 * math.log10(rms) if rms > 1e-12 else -240.0


def find_marker(x, rate):
    """The sample where the 1 kHz marker starts (10 ms resolution), or None."""
    blk = int(0.01 * rate)
    # The marker comes before any step, within the first seconds of the
    # recording (which starts a little before the playback): find its level
    # there, then where it starts, at 10 dB below it, held for 50 ms.
    levels = [goertzel_db(x, i * blk, blk, MARK_HZ, rate) for i in range(min(len(x), 4 * rate) // blk)]
    if len(levels) < 30:
        return None
    floor = sorted(levels)[len(levels) // 4]
    top = max(levels)
    if top < floor + 20:
        return None
    for i in range(len(levels) - 5):
        if all(v > top - 10 for v in levels[i:i + 5]):
            return i * blk
    return None


def analyze(path, freqs, level_db, mic=None):
    rate, chans = read_wav(path)
    best = None
    for c, x in enumerate(chans):
        if mic is not None and c != mic:
            continue
        on = find_marker(x, rate)
        if on is None:
            continue
        m = goertzel_db(x, on + int(0.08 * rate), int(0.15 * rate), MARK_HZ, rate)
        if best is None or m > best[2]:
            best = (c, on, m)
    if best is None:
        raise ValueError('no 1 kHz marker found in the recording (too quiet, or the wrong microphone?)')
    c, on, _ = best
    x = chans[c]
    n = int(0.15 * rate)
    noise_at = on - int(0.45 * rate)
    peak = max(abs(v) for v in x)
    rows = []
    t0 = on + int((MARK + AFTER_MARK) * rate)
    for i, f in enumerate(freqs):
        st = t0 + int(i * (TONE + GAP) * rate) + int(0.08 * rate)
        lv = goertzel_db(x, st, n, f, rate)
        nz = goertzel_db(x, noise_at, n, f, rate) if noise_at >= 0 else None
        if lv is None:
            break
        rows.append({'freq': f, 'db': round(lv - level_db, 2),
                     'snr': None if nz is None else round(lv - nz, 1)})
    return {'file': path, 'mic': c, 'rate': rate, 'peak_dbfs': round(20 * math.log10(max(peak, 1e-9)), 1),
            'level': level_db, 'steps': rows}


def band(rows, lo, hi):
    v = [r['db'] for r in rows if lo <= r['freq'] <= hi and (r['snr'] is None or r['snr'] >= 10)]
    return sum(v) / len(v) if v else None


def corner(rows, ref, down=12.0):
    """The lowest step from which the response stays within `down` dB of ref
    for three steps."""
    ok = [r['db'] >= ref - down and (r['snr'] is None or r['snr'] >= 10) for r in rows]
    for i in range(len(rows) - 2):
        if ok[i] and ok[i + 1] and ok[i + 2]:
            return rows[i]['freq']
    return None


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def suggest(left, right):
    """A bounded starting point, never more than +6 dB of boost or a channel
    raised: the ear decides (AOC-PLAN C9g)."""
    out, notes = {}, []
    sides = {'top': left['steps'], 'bottom': right['steps']}
    info = {}
    for side, rows in sides.items():
        ref = band(rows, 1000, 3000)
        if ref is None:
            notes.append(f'{side}: no usable steps between 1 and 3 kHz')
            continue
        c = corner(rows, ref)
        low = band(rows, c, 2 * c) if c else None
        pres = band(rows, 2500, 5000)
        mid = band(rows, 800, 2000)
        hi = band(rows, 6000, 12000)
        info[side] = {'ref': ref, 'corner': c, 'low': low, 'pres': pres, 'mid': mid, 'hi': hi,
                      'avg': band(rows, 500, 4000)}
        notes.append(f'{side}: -12 dB corner {c or "-"} Hz; relative to 1-3 kHz: '
                     f'{"-" if low is None else f"{low - ref:+.1f}"} dB just above the corner, '
                     f'{"-" if pres is None else f"{pres - ref:+.1f}"} dB at 2.5-5 kHz, '
                     f'{"-" if hi is None else f"{hi - ref:+.1f}"} dB at 6-12 kHz')
    b = info.get('bottom') or info.get('top')
    if b and b['corner']:
        out['hp'] = clamp(round(b['corner'] * 0.5 / 10) * 10, 60, 200)
        out['bass_freq'] = clamp(round(b['corner'] * 2 / 10) * 10, 200, 800)
        if b['low'] is not None:
            out['bass'] = round(clamp((b['ref'] - b['low']) / 2, 0, 6), 1)
    pres = [i['pres'] - i['mid'] for i in info.values() if i['pres'] is not None and i['mid'] is not None]
    if pres:
        p = sum(pres) / len(pres)
        out['dip'] = round(-clamp(p - 1, 0, 4), 1)
    for side in ('top', 'bottom'):
        i = info.get(side)
        if i and i['hi'] is not None:
            out[f'treble_{side}'] = round(-clamp(i['hi'] - i['ref'] - 2, 0, 4), 1)
    if 'top' in info and 'bottom' in info and info['top']['avg'] is not None and info['bottom']['avg'] is not None:
        d = info['top']['avg'] - info['bottom']['avg']
        notes.append(f'balance (500 Hz-4 kHz): top {d:+.1f} dB against bottom at this microphone')
        if abs(d) >= 1:
            out['trim_top' if d > 0 else 'trim_bottom'] = round(-clamp(abs(d), 0, 6), 1)
    return out, notes


def main(argv):
    ap = argparse.ArgumentParser(prog='speaker_response')
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name in ('gen', 'analyze'):
        p = sub.add_parser(name)
        p.add_argument('file')
        p.add_argument('--level', type=float, default=-30.0)
        p.add_argument('--fmin', type=float, default=100.0)
        p.add_argument('--fmax', type=float, default=16000.0)
        p.add_argument('--per-octave', type=int, default=6)
        if name == 'gen':
            p.add_argument('--channel', choices=('left', 'right', 'both'), required=True)
        else:
            p.add_argument('--mic', type=int, default=None)
            p.add_argument('--json', default=None, help='also write the result here')
    s = sub.add_parser('suggest')
    s.add_argument('left')
    s.add_argument('right')
    args = ap.parse_args(argv)
    if args.cmd == 'suggest':
        with open(args.left) as f:
            left = json.load(f)
        with open(args.right) as f:
            right = json.load(f)
        out, notes = suggest(left, right)
        for n in notes:
            print(n)
        print('suggested: omandroid-speaker-eq set ' + ' '.join(f'{k}={v:g}' for k, v in out.items()))
        return 0
    freqs = steps(args.fmin, args.fmax, args.per_octave)
    if args.cmd == 'gen':
        s = stimulus(freqs, args.level)
        write_wav(args.file, s, args.channel)
        print(f'{args.file}: {len(freqs)} steps {freqs[0]:g}-{freqs[-1]:g} Hz at {args.level:g} dBFS, '
              f'{len(s) / RATE:.1f} s, {args.channel}')
        return 0
    try:
        res = analyze(args.file, freqs, args.level, args.mic)
    except ValueError as e:
        print(f'{args.file}: {e}')
        return 1
    if args.json:
        with open(args.json, 'w') as f:
            json.dump(res, f)
    print(f'{args.file}: microphone channel {res["mic"]}, peak {res["peak_dbfs"]} dBFS'
          + ('  (CLIPPED: lower --level or move the microphone)' if res['peak_dbfs'] > -1 else ''))
    print(' freq Hz   dB re stimulus   SNR dB')
    for r in res['steps']:
        bar = '#' * max(0, int((r['db'] + 60) / 2))
        snr = '-' if r['snr'] is None else f'{r["snr"]:.0f}'
        flag = '' if r['snr'] is None or r['snr'] >= 10 else '  (noise)'
        print(f'{r["freq"]:8.0f}   {r["db"]:+7.1f}   {snr:>6}  {bar}{flag}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
