# SPDX-License-Identifier: MIT
"""ReleaseGyroscope while the client still holds its socket: the proxy closes
its end, so the client reads end of stream. Run from the package directory
on the bus a test proxy serves (test/all)."""
import select
import sys
import time

sys.path.insert(0, 'lib')
import gyro  # noqa: E402
from gi.repository import Gio  # noqa: E402

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
sock, rate = gyro.claim(bus, 60)
assert rate == 60, rate
time.sleep(0.3)
assert sock.recv(4096), 'records before the release'
bus.call_sync(gyro.NAME, gyro.PATH, gyro.IFACE, 'ReleaseGyroscope', None, None,
              Gio.DBusCallFlags.NONE, 2000, None)
deadline = time.monotonic() + 2
while time.monotonic() < deadline:
    if select.select([sock], [], [], 0.5)[0] and sock.recv(4096) == b'':
        print('end of stream after ReleaseGyroscope')
        sys.exit(0)
sys.exit('the stream stayed open after ReleaseGyroscope')
