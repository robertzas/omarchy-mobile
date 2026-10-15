#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""iio-sensor-proxy's D-Bus service (net.hadess.SensorProxy) for cheetah.

The Pixel 7 Pro's sensors hang off the AoC (audio and sensor DSP), not Linux
buses, so there is no IIO device for iio-sensor-proxy to open. This daemon
serves the same system bus API from the AoC's sensor framework (USF), so its
clients (monitor-sensor, omamobile-autorotate, brightness and proximity
helpers) work unchanged:

  /net/hadess/SensorProxy          net.hadess.SensorProxy
      HasAccelerometer, AccelerometerOrientation, AccelerometerTilt,
      HasAmbientLight, LightLevelUnit, LightLevel, HasProximity, ProximityNear;
      Claim/Release{Accelerometer,Light,Proximity}
  /net/hadess/SensorProxy/Compass  net.hadess.SensorProxy.Compass
      HasCompass, CompassHeading; Claim/ReleaseCompass
  /net/hadess/SensorProxy/Gyro     org.omamobile.SensorProxy.Gyro1 (ours)
      HasGyroscope, MinRate, MaxRate, RecordSize, TimestampClock;
      ClaimGyroscope(u rate_hz) -> (h stream, u rate_hz); ReleaseGyroscope

As in iio-sensor-proxy, a sensor runs only while some client holds a claim,
and a client's claims end when it leaves the bus.

The gyroscope is too fast for D-Bus signals: ClaimGyroscope hands the client
one end of a SOCK_SEQPACKET socket pair. Each packet holds one or more
24-byte records (at most GYRO_MAX_RECORDS), little-endian:

  u64 timestamp_ns   CLOCK_MONOTONIC, when the sensor took the sample
  f32 x, y, z        angular rate in rad/s, Android's device frame (x to the
                     right, y to the top, z out of the screen, in natural
                     portrait; positive is counter-clockwise looking down
                     the axis)
  u32 seq            this stream's record counter: a gap is a dropped record

The claim ends when the client closes its end, calls ReleaseGyroscope or
leaves the bus. A client that does not keep up loses records (seq skips);
it never stalls the proxy.

  omamobile-sensor-proxy [--backend usf|test] [--device PATH]
"""
import argparse
import math
import signal
import socket
import struct
import sys

import gi
gi.require_version('Gio', '2.0')
gi.require_version('GLibUnix', '2.0')
from gi.repository import Gio, GLib, GLibUnix  # noqa: E402

NAME = 'net.hadess.SensorProxy'
PATH = '/net/hadess/SensorProxy'
XML = '''<node>
  <interface name="net.hadess.SensorProxy">
    <method name="ClaimAccelerometer"/>
    <method name="ReleaseAccelerometer"/>
    <method name="ClaimLight"/>
    <method name="ReleaseLight"/>
    <method name="ClaimProximity"/>
    <method name="ReleaseProximity"/>
    <property name="HasAccelerometer" type="b" access="read"/>
    <property name="AccelerometerOrientation" type="s" access="read"/>
    <property name="AccelerometerTilt" type="s" access="read"/>
    <property name="HasAmbientLight" type="b" access="read"/>
    <property name="LightLevelUnit" type="s" access="read"/>
    <property name="LightLevel" type="d" access="read"/>
    <property name="HasProximity" type="b" access="read"/>
    <property name="ProximityNear" type="b" access="read"/>
  </interface>
</node>'''
COMPASS_XML = '''<node>
  <interface name="net.hadess.SensorProxy.Compass">
    <method name="ClaimCompass"/>
    <method name="ReleaseCompass"/>
    <property name="HasCompass" type="b" access="read"/>
    <property name="CompassHeading" type="d" access="read"/>
  </interface>
</node>'''

GYRO_XML = '''<node>
  <interface name="org.omamobile.SensorProxy.Gyro1">
    <method name="ClaimGyroscope">
      <arg name="rate_hz" type="u" direction="in"/>
      <arg name="stream" type="h" direction="out"/>
      <arg name="rate_hz" type="u" direction="out"/>
    </method>
    <method name="ReleaseGyroscope"/>
    <property name="HasGyroscope" type="b" access="read"/>
    <property name="MinRate" type="u" access="read"/>
    <property name="MaxRate" type="u" access="read"/>
    <property name="RecordSize" type="u" access="read"/>
    <property name="TimestampClock" type="s" access="read"/>
  </interface>
</node>'''
GYRO_IFACE = 'org.omamobile.SensorProxy.Gyro1'
GYRO_RECORD = struct.Struct('<QfffI')
GYRO_MAX_RECORDS = 64            # per packet: 1536 bytes
GYRO_DEFAULT_HZ = 200


def gyro_rate(requested, lo, hi):
    """The rate the LSM6DSV will run at for a request: its output data rates
    are 15 Hz times a power of two, and the AoC picks the first one at or above
    the request (measured: 100 -> 121, 200 -> 243, 400 -> 485 Hz by the
    sample timestamps, the sensor's own clock being about 1 % fast)."""
    rate = float(requested or GYRO_DEFAULT_HZ)
    rate = min(max(rate, lo), hi)
    odr = 15
    while odr < rate and odr * 2 <= hi:
        odr *= 2
    return odr


def gyro_packets(records, first_seq):
    """records [(t_ns, x, y, z)] as packets of whole records, numbered from first_seq."""
    out = []
    for i in range(0, len(records), GYRO_MAX_RECORDS):
        chunk = records[i:i + GYRO_MAX_RECORDS]
        out.append(b''.join(GYRO_RECORD.pack(t, x, y, z, (first_seq + i + j) & 0xffffffff)
                            for j, (t, x, y, z) in enumerate(chunk)))
    return out


class GyroClient:
    """One claim: the proxy's end of the client's socket pair."""

    def __init__(self, sender, rate, on_close):
        self.sender = sender
        self.rate = rate
        self.seq = 0
        self.dropped = 0
        self.sock, self.peer = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.sock.setblocking(False)
        self.sock.shutdown(socket.SHUT_RD)
        self.on_close = on_close
        # The client closing its end (or exiting) hangs ours up.
        self.watch = GLib.io_add_watch(self.sock.fileno(), GLib.IO_HUP | GLib.IO_ERR, self._hup)

    def _hup(self, *_):
        self.watch = None
        self.on_close(self)
        return False

    def send(self, records):
        """Send records; False once the client has gone."""
        for pkt in gyro_packets(records, self.seq):
            n = len(pkt) // GYRO_RECORD.size
            self.seq += n
            try:
                self.sock.send(pkt)
            except BlockingIOError:
                self.dropped += n
            except OSError:
                return False
        return True

    def close(self):
        if self.watch:
            GLib.source_remove(self.watch)
            self.watch = None
        self.sock.close()
        if self.peer is not None:
            self.peer.close()
            self.peer = None


# iio-sensor-proxy's orientation thresholds (src/orientation.c).
THRESHOLD = 35
SAME_AXIS_LIMIT = 5


def orientation(prev, x, y, z):
    """iio-sensor-proxy's orientation_calc(), for a gravity vector in its frame:
    upright portrait reads y < 0, left edge up reads x > 0."""
    portrait = round(math.degrees(math.atan2(x, math.sqrt(y * y + z * z))))
    landscape = round(math.degrees(math.atan2(y, math.sqrt(x * x + z * z))))
    if abs(portrait) > THRESHOLD and abs(landscape) > THRESHOLD:
        return prev
    if abs(portrait) > THRESHOLD:
        ret = 'left-up' if portrait > 0 else 'right-up'
        if prev in ('left-up', 'right-up') and abs(portrait) < SAME_AXIS_LIMIT:
            return prev
        return ret
    if abs(landscape) > THRESHOLD:
        ret = 'bottom-up' if landscape > 0 else 'normal'
        if prev in ('bottom-up', 'normal') and abs(landscape) < SAME_AXIS_LIMIT:
            return prev
        return ret
    return prev


def tilt(x, y, z):
    """The screen's tilt, as iio-sensor-proxy names it (lying face up: z < 0)."""
    g = math.sqrt(x * x + y * y + z * z) or 1.0
    angle = math.degrees(math.acos(max(-1.0, min(1.0, z / g))))
    if angle < 10:
        return 'face-down'
    if angle > 170:
        return 'face-up'
    if angle < 80:
        return 'tilted-down'
    if angle > 100:
        return 'tilted-up'
    return 'vertical'


class TestBackend:
    """Scripted readings, to exercise the D-Bus side without sensors."""
    has = {'accel': True, 'light': True, 'proximity': True, 'compass': True, 'gyro': True}

    def __init__(self, report):
        self.report = report
        self.timers = {}
        self.step = 0
        self.stream_periods = []   # every start_stream period, for the tests

    def stream_range(self, kind):
        return 15.0, 480.0

    def start_stream(self, kind, period_ns):
        self.stop_stream(kind)
        self.stream_periods.append(period_ns)
        print(f'test backend: {kind} at {1e9 / period_ns:.0f} Hz', file=sys.stderr, flush=True)
        state = {'next': GLib.get_monotonic_time() * 1000, 'n': 0}

        def tick():
            # Samples timestamped as the sensor would (CLOCK_MONOTONIC), sent
            # in the small batches the AoC's messages carry.
            now = GLib.get_monotonic_time() * 1000
            out = []
            while state['next'] <= now:
                state['n'] += 1
                out.append((state['next'], 0.1, -0.2, math.sin(state['n'] / 50)))
                state['next'] += period_ns
            if out:
                self.report(kind, out)
            return True
        self.timers[kind] = GLib.timeout_add(10, tick)

    def stop_stream(self, kind):
        if kind in self.timers:
            GLib.source_remove(self.timers.pop(kind))
            print(f'test backend: {kind} stopped', file=sys.stderr, flush=True)

    def start(self, kind):
        self.timers[kind] = GLib.timeout_add(1000, self._tick, kind)

    def stop(self, kind):
        GLib.source_remove(self.timers.pop(kind))

    def _tick(self, kind):
        self.step += 1
        if kind == 'accel':
            # Android frame (reaction to gravity): upright, then on the left edge.
            ax, ay, az = [(0, 9.8, 0.5), (-9.8, 0, 0.5)][(self.step // 3) % 2]
            self.report('accel', (ax, ay, az))
        elif kind == 'light':
            self.report('light', 100.0 + self.step)
        elif kind == 'compass':
            self.report('compass', (10.0 * self.step) % 360)
        else:
            self.report('proximity', self.step % 4 < 2)
        return True


class Proxy:
    def __init__(self, bus, backend):
        self.bus = bus
        self.backend = backend
        self.claims = {'accel': set(), 'light': set(), 'proximity': set(), 'compass': set()}
        self.gyro = {}           # sender -> GyroClient
        self.gyro_period = None  # the period the gyroscope runs at
        self.state = {'AccelerometerOrientation': 'undefined', 'AccelerometerTilt': 'undefined',
                      'LightLevel': 0.0, 'ProximityNear': False, 'CompassHeading': -1.0}
        info = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0]
        compass = Gio.DBusNodeInfo.new_for_xml(COMPASS_XML).interfaces[0]
        bus.register_object_with_closures2(PATH, info, self._call, self._get, None)
        bus.register_object_with_closures2(PATH + '/Compass', compass, self._compass_call,
                                           self._compass_get, None)
        gyro = Gio.DBusNodeInfo.new_for_xml(GYRO_XML).interfaces[0]
        bus.register_object_with_closures2(PATH + '/Gyro', gyro, self._gyro_call, self._gyro_get, None)
        bus.signal_subscribe('org.freedesktop.DBus', 'org.freedesktop.DBus', 'NameOwnerChanged',
                             '/org/freedesktop/DBus', None, Gio.DBusSignalFlags.NONE,
                             self._owner_changed)

    def _get(self, conn, sender, path, iface, prop):
        has = self.backend.has
        values = {
            'HasAccelerometer': GLib.Variant('b', has['accel']),
            'AccelerometerOrientation': GLib.Variant('s', self.state['AccelerometerOrientation']),
            'AccelerometerTilt': GLib.Variant('s', self.state['AccelerometerTilt']),
            'HasAmbientLight': GLib.Variant('b', has['light']),
            'LightLevelUnit': GLib.Variant('s', 'lux'),
            'LightLevel': GLib.Variant('d', self.state['LightLevel']),
            'HasProximity': GLib.Variant('b', has['proximity']),
            'ProximityNear': GLib.Variant('b', self.state['ProximityNear']),
        }
        return values.get(prop)

    def _call(self, conn, sender, path, iface, method, params, invocation):
        claim = method.startswith('Claim')
        sensor = method[len('Claim'):] if claim else method[len('Release'):]
        kind = {'Accelerometer': 'accel', 'Light': 'light', 'Proximity': 'proximity'}[sensor]
        if not self.backend.has[kind]:
            invocation.return_dbus_error('net.hadess.SensorProxy.Error.NoSensor', f'No {sensor.lower()}')
            return
        if claim:
            self._claim(kind, sender)
        else:
            self._release(kind, sender)
        invocation.return_value(None)

    def _compass_get(self, conn, sender, path, iface, prop):
        return {'HasCompass': GLib.Variant('b', self.backend.has['compass']),
                'CompassHeading': GLib.Variant('d', self.state['CompassHeading'])}.get(prop)

    def _compass_call(self, conn, sender, path, iface, method, params, invocation):
        if not self.backend.has['compass']:
            invocation.return_dbus_error('net.hadess.SensorProxy.Error.NoSensor', 'No compass')
            return
        if method == 'ClaimCompass':
            self._claim('compass', sender)
        else:
            self._release('compass', sender)
        invocation.return_value(None)

    def _gyro_range(self):
        lo, hi = self.backend.stream_range('gyro') if self.backend.has.get('gyro') else (0, 0)
        return int(math.ceil(lo)), int(hi)

    def _gyro_get(self, conn, sender, path, iface, prop):
        lo, hi = self._gyro_range()
        return {'HasGyroscope': GLib.Variant('b', bool(self.backend.has.get('gyro'))),
                'MinRate': GLib.Variant('u', lo), 'MaxRate': GLib.Variant('u', hi),
                'RecordSize': GLib.Variant('u', GYRO_RECORD.size),
                'TimestampClock': GLib.Variant('s', 'monotonic')}.get(prop)

    def _gyro_call(self, conn, sender, path, iface, method, params, invocation):
        if not self.backend.has.get('gyro'):
            invocation.return_dbus_error('net.hadess.SensorProxy.Error.NoSensor', 'No gyroscope')
            return
        if method == 'ReleaseGyroscope':
            self._gyro_release(sender)
            invocation.return_value(None)
            return
        if not conn.get_capabilities() & Gio.DBusCapabilityFlags.UNIX_FD_PASSING:
            invocation.return_dbus_error('org.freedesktop.DBus.Error.NotSupported', 'No fd passing')
            return
        (requested,) = params.unpack()
        lo, hi = self.backend.stream_range('gyro')
        rate = gyro_rate(requested, lo, hi)
        self._gyro_release(sender, update=False)
        client = GyroClient(sender, rate, self._gyro_closed)
        self.gyro[sender] = client
        try:
            self._gyro_update()
        except Exception as e:  # noqa: BLE001 - the AoC refused: the claim fails
            self._gyro_release(sender)
            invocation.return_dbus_error('net.hadess.SensorProxy.Error.Failed', f'gyroscope: {e}')
            return
        # The fd list owns the client's end from here; Gio closes it once sent.
        fds = Gio.UnixFDList.new_from_array([client.peer.detach()])
        client.peer = None
        invocation.return_value_with_unix_fd_list(GLib.Variant('(hu)', (0, rate)), fds)

    def _gyro_closed(self, client):
        if self.gyro.get(client.sender) is client:
            self._gyro_release(client.sender)

    def _gyro_release(self, sender, update=True):
        client = self.gyro.pop(sender, None)
        if client is None:
            return
        client.close()
        if client.dropped:
            print(f'gyroscope client {sender} dropped {client.dropped} of {client.seq} records',
                  file=sys.stderr, flush=True)
        if update:
            self._gyro_update()

    def _gyro_update(self):
        """Run the gyroscope at the fastest claimed rate, or stop it."""
        period = int(1e9 / max(c.rate for c in self.gyro.values())) if self.gyro else None
        if period == self.gyro_period:
            return
        self.gyro_period = None
        if period is None:
            self.backend.stop_stream('gyro')
            return
        self.backend.start_stream('gyro', period)
        self.gyro_period = period

    def _claim(self, kind, sender):
        first = not self.claims[kind]
        self.claims[kind].add(sender)
        if first:
            self.backend.start(kind)

    def _release(self, kind, sender):
        if sender in self.claims[kind]:
            self.claims[kind].discard(sender)
            if not self.claims[kind]:
                self.backend.stop(kind)

    def _owner_changed(self, conn, sender, path, iface, signal_name, params):
        name, _old, new = params.unpack()
        if new == '' and name.startswith(':'):
            for kind in self.claims:
                self._release(kind, name)
            self._gyro_release(name)

    def report(self, kind, value):
        if kind == 'gyro':
            for client in list(self.gyro.values()):
                if not client.send(value):
                    self._gyro_release(client.sender)
            return
        changed = {}
        if kind == 'accel':
            ax, ay, az = value
            # Android frame (reaction to gravity) -> iio-sensor-proxy's (gravity).
            x, y, z = -ax, -ay, -az
            o = orientation(self.state['AccelerometerOrientation'], x, y, z)
            t = tilt(x, y, z)
            if o != self.state['AccelerometerOrientation']:
                changed['AccelerometerOrientation'] = GLib.Variant('s', o)
            if t != self.state['AccelerometerTilt']:
                changed['AccelerometerTilt'] = GLib.Variant('s', t)
        elif kind == 'light':
            if value != self.state['LightLevel']:
                changed['LightLevel'] = GLib.Variant('d', float(value))
        elif kind == 'proximity':
            if bool(value) != self.state['ProximityNear']:
                changed['ProximityNear'] = GLib.Variant('b', bool(value))
        elif kind == 'compass':
            if abs(value - self.state['CompassHeading']) >= 0.1:
                changed['CompassHeading'] = GLib.Variant('d', float(value))
        if not changed:
            return
        for prop, variant in changed.items():
            self.state[prop] = variant.unpack()
        path, iface = (PATH + '/Compass', NAME + '.Compass') if kind == 'compass' else (PATH, NAME)
        self.bus.emit_signal(None, path, 'org.freedesktop.DBus.Properties', 'PropertiesChanged',
                             GLib.Variant('(sa{sv}as)', (iface, changed, [])))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--backend', choices=('usf', 'test'), default='usf')
    ap.add_argument('--device', default='/dev/acd-com.google.usf')
    ap.add_argument('--session', action='store_true', help='use the session bus (testing)')
    a = ap.parse_args(argv)
    bus = Gio.bus_get_sync(Gio.BusType.SESSION if a.session else Gio.BusType.SYSTEM, None)
    proxy = None

    def report(kind, value):
        proxy.report(kind, value)

    if a.backend == 'test':
        backend = TestBackend(report)
    else:
        from usf_backend import UsfBackend  # noqa: PLC0415
        backend = UsfBackend(a.device, report)
    proxy = Proxy(bus, backend)
    loop = GLib.MainLoop()

    def lost(conn, name):
        print(f'{NAME} is owned by another process', file=sys.stderr)
        loop.quit()

    Gio.bus_own_name_on_connection(bus, NAME, Gio.BusNameOwnerFlags.NONE, None, lost)
    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, loop.quit)
    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, loop.quit)
    loop.run()
    return 0


if __name__ == '__main__':
    sys.exit(main())
