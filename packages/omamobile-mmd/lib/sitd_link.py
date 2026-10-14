# SPDX-License-Identifier: MIT
"""The bridge's two ways into omamobile-sitd's socket
(/run/omamobile-sit/socket, JSON lines; packages/omamobile-modem-sit):

- one long-lived "subscribe" connection, read from the GLib main loop: a
  full status after connecting and after every change. When it closes
  (sitd stopped, the CP left ONLINE) the modem goes away, and the link
  tries again every few seconds;
- requests (dial, accept, sms-send, ...), each on its own connection in a
  worker thread, since sitd answers one at a time and an SMS send can take
  minutes. The answer comes back in the main loop.

sitd stays the only process that talks to the modem; nothing here sends
anything but its socket requests.
"""
from concurrent.futures import ThreadPoolExecutor
import json
import socket

from gi.repository import GLib

RETRY_SECONDS = 3
MAX_LINE = 1 << 20


class SitdError(RuntimeError):
    """sitd refused a request; its message is safe to show (no numbers)."""


def blocking_request(path, action, timeout=25, **args):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout)
        client.connect(path)
        client.sendall(json.dumps(dict(action=action, **args)).encode() + b'\n')
        data = b''
        while b'\n' not in data:
            chunk = client.recv(65536)
            if not chunk:
                raise SitdError('omamobile-sitd closed the connection')
            data += chunk
            if len(data) > MAX_LINE:
                raise SitdError('omamobile-sitd reply too large')
    reply = json.loads(data.split(b'\n', 1)[0])
    if not reply.get('ok'):
        raise SitdError(reply.get('error') or 'omamobile-sitd refused the request')
    return reply.get('result')


class SitdLink:
    def __init__(self, path, on_status, on_lost):
        self.path = path
        self.on_status = on_status
        self.on_lost = on_lost
        self.sock = None
        self.watch = None
        self.buffer = b''
        self.subscribed = False
        self.reported_absent = False
        self.pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix='sitd')

    def start(self):
        self._connect()

    def stop(self):
        self._close()
        self.pool.shutdown(wait=False, cancel_futures=True)

    def _connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.settimeout(2)
            sock.connect(self.path)
            sock.sendall(b'{"action": "subscribe"}\n')
        except OSError as error:
            sock.close()
            if not self.reported_absent:
                print(f'omamobile-sitd not reachable ({type(error).__name__}); retrying every '
                      f'{RETRY_SECONDS} s', flush=True)
                self.reported_absent = True
            GLib.timeout_add_seconds(RETRY_SECONDS, self._retry)
            return
        sock.setblocking(False)
        self.sock, self.buffer, self.subscribed = sock, b'', False
        self.reported_absent = False
        self.watch = GLib.io_add_watch(sock.fileno(), GLib.PRIORITY_DEFAULT,
                                       GLib.IOCondition.IN | GLib.IOCondition.HUP | GLib.IOCondition.ERR,
                                       self._readable)

    def _retry(self):
        if self.sock is None:
            self._connect()
        return False

    def _close(self):
        if self.watch is not None:
            GLib.source_remove(self.watch)
            self.watch = None
        if self.sock is not None:
            self.sock.close()
            self.sock = None

    def _lost(self, why):
        was = self.subscribed
        self._close()
        self.subscribed = False
        print(f'omamobile-sitd link closed ({why})', flush=True)
        if was:
            self.on_lost()
        GLib.timeout_add_seconds(RETRY_SECONDS, self._retry)
        return False

    def _readable(self, fd, condition):
        try:
            chunk = self.sock.recv(65536)
        except BlockingIOError:
            return True
        except OSError as error:
            return self._lost(type(error).__name__)
        if not chunk:
            return self._lost('end of stream')
        self.buffer += chunk
        if len(self.buffer) > MAX_LINE:
            return self._lost('oversized event')
        while b'\n' in self.buffer:
            line, self.buffer = self.buffer.split(b'\n', 1)
            try:
                message = json.loads(line)
            except ValueError:
                return self._lost('malformed event')
            if not self.subscribed:
                if not (isinstance(message, dict) and message.get('ok')):
                    return self._lost('subscription refused: ' + str(message.get('error', ''))[:80])
                self.subscribed = True
                print('Subscribed to omamobile-sitd', flush=True)
                continue
            if isinstance(message, dict) and message.get('event') == 'status':
                self.on_status(message['status'])
        return True

    def request(self, action, done, timeout=25, **args):
        """Run one request in a worker; done(result, error) in the main loop."""
        future = self.pool.submit(blocking_request, self.path, action, timeout, **args)

        def finished(future):
            try:
                result, error = future.result(), None
            except (OSError, ValueError, SitdError) as failure:
                result, error = None, failure
            GLib.idle_add(lambda: done(result, error) and False)
        future.add_done_callback(finished)
