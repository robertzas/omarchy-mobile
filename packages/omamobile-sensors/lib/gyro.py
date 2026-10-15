#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""omamobile-gyro: read the gyroscope stream of omamobile-sensor-proxy
(org.omamobile.SensorProxy.Gyro1), as a test and a reference client.

  omamobile-gyro [--rate HZ] [--duration S] [--stats | --integrate] [--session]

By default it prints one line per record: CLOCK_MONOTONIC ns, x, y, z in
rad/s, seq. --stats prints the achieved rate, the spread of the sample
intervals, the delivery latency (CLOCK_MONOTONIC when read minus the sample's
timestamp) and dropped records. --integrate prints the angle turned about
each axis, in degrees, twice a second: turn the phone about one axis to see
which one it is.
"""
import argparse
import os
import select
import socket
import statistics
import struct
import sys
import time

import gi
gi.require_version('Gio', '2.0')
from gi.repository import Gio, GLib  # noqa: E402

NAME = 'net.hadess.SensorProxy'
PATH = '/net/hadess/SensorProxy/Gyro'
IFACE = 'org.omamobile.SensorProxy.Gyro1'
RECORD = struct.Struct('<QfffI')


def claim(bus, rate):
    """ClaimGyroscope: (socket, rate the sensor runs at)."""
    reply, fds = bus.call_with_unix_fd_list_sync(
        NAME, PATH, IFACE, 'ClaimGyroscope', GLib.Variant('(u)', (rate,)),
        GLib.VariantType('(hu)'), Gio.DBusCallFlags.NONE, 5000, None, None)
    index, actual = reply.unpack()
    fd = fds.steal_fds()[index]
    return socket.socket(fileno=fd), actual


def records(sock, duration):
    """Yield (receive time ns, t_ns, x, y, z, seq) for duration seconds."""
    end = time.monotonic() + duration
    while True:
        left = end - time.monotonic()
        if left <= 0:
            return
        if not select.select([sock], [], [], min(left, 1.0))[0]:
            continue
        pkt = sock.recv(4096)
        now = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
        if not pkt:
            print('omamobile-gyro: the proxy closed the stream', file=sys.stderr)
            return
        for off in range(0, len(pkt) - len(pkt) % RECORD.size, RECORD.size):
            yield (now,) + RECORD.unpack_from(pkt, off)


def pct(values, p):
    s = sorted(values)
    return s[min(len(s) - 1, int(p / 100 * len(s)))]


def stats(rows, rate, out=sys.stdout):
    if len(rows) < 3:
        print(f'only {len(rows)} records', file=out)
        return 1
    ts = [r[1] for r in rows]
    d = [(b - a) / 1e6 for a, b in zip(ts, ts[1:])]
    lat = [(r[0] - r[1]) / 1e6 for r in rows]
    seqs = [r[5] for r in rows]
    lost = sum(b - a - 1 for a, b in zip(seqs, seqs[1:]))
    span = (ts[-1] - ts[0]) / 1e9
    print(f'sensor rate         {rate} Hz', file=out)
    print(f'records             {len(rows)} in {span:.2f} s: {(len(rows) - 1) / span:.1f} Hz', file=out)
    print(f'interval ms         mean {statistics.mean(d):.3f}  sd {statistics.pstdev(d):.4f}  '
          f'min {min(d):.3f}  max {max(d):.3f}', file=out)
    print(f'latency ms          min {min(lat):.2f}  median {statistics.median(lat):.2f}  '
          f'p95 {pct(lat, 95):.2f}  max {max(lat):.2f}', file=out)
    print(f'packets             {len(set(r[0] for r in rows))} (records per read: '
          f'{len(rows) / len(set(r[0] for r in rows)):.2f})', file=out)
    print(f'dropped (seq gaps)  {lost}', file=out)
    print(f'mean rate rad/s     x {statistics.mean(r[2] for r in rows):+.5f}  '
          f'y {statistics.mean(r[3] for r in rows):+.5f}  z {statistics.mean(r[4] for r in rows):+.5f}', file=out)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--rate', type=int, default=200, help='requested rate in Hz (default 200)')
    ap.add_argument('--duration', type=float, default=5.0)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument('--stats', action='store_true', help='print rate, jitter and latency at the end')
    mode.add_argument('--integrate', action='store_true', help='print the angle turned about each axis')
    ap.add_argument('--session', action='store_true', help='use the session bus (testing)')
    a = ap.parse_args(argv)
    bus = Gio.bus_get_sync(Gio.BusType.SESSION if a.session else Gio.BusType.SYSTEM, None)
    sock, rate = claim(bus, a.rate)
    print(f'omamobile-gyro: gyroscope at {rate} Hz', file=sys.stderr, flush=True)
    rows = []
    angle = [0.0, 0.0, 0.0]
    prev = None
    shown = time.monotonic()
    try:
        for row in records(sock, a.duration):
            if a.stats:
                rows.append(row)
            elif a.integrate:
                if prev is not None:
                    dt = (row[1] - prev) / 1e9
                    for i in range(3):
                        angle[i] += row[2 + i] * dt * 57.29577951308232
                prev = row[1]
                if time.monotonic() - shown >= 0.5:
                    shown = time.monotonic()
                    print(f'x {angle[0]:+7.1f}  y {angle[1]:+7.1f}  z {angle[2]:+7.1f} deg', flush=True)
            else:
                print(f'{row[1]} {row[2]:+.5f} {row[3]:+.5f} {row[4]:+.5f} {row[5]}')
    except KeyboardInterrupt:
        pass
    finally:
        sock.close()   # ends the claim
    if a.stats:
        return stats(rows, rate)
    if a.integrate:
        print(f'total: x {angle[0]:+.1f}  y {angle[1]:+.1f}  z {angle[2]:+.1f} deg')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except BrokenPipeError:
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        sys.exit(0)
