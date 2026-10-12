#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline test of libfprint's omandroid_udfps driver against a fake bridge.

    driver-test.py              (needs FPrint-2.0 from the libfprint build:
                                 GI_TYPELIB_PATH and LD_LIBRARY_PATH)

Starts a fake omandroid-fp-bridge on a Unix socket that speaks the bridge's
line protocol with scripted HAL answers, points the driver at it
(FP_OMANDROID_UDFPS), and runs enroll, list, verify (match and no match),
identify, cancel, a lockout, delete and a bridge that goes away. No phone,
no HAL: this checks the driver's side of the protocol only.
"""
import os
import socket
import sys
import tempfile
import threading

import gi

gi.require_version("FPrint", "2.0")
from gi.repository import FPrint, GLib, Gio  # noqa: E402

ENROLL_ID = 123456789


class FakeBridge(threading.Thread):
    """One client at a time, as the real bridge. `script` maps a command to
    the lines to answer; "AUTH" answers come from `auth_answers` in turn."""

    def __init__(self, path):
        super().__init__(daemon=True)
        self.path = path
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(2)
        self.enrolled = []
        self.auth_answers = []
        self.commands = []
        self.hold_auth = False
        self.conn = None
        self.drop_next = False

    def send(self, *lines):
        for line in lines:
            self.conn.sendall((line + "\n").encode())

    def run(self):
        while True:
            try:
                self.conn, _ = self.sock.accept()
            except OSError:
                return
            self.send("READY 720 2360 120")
            buf = b""
            while True:
                data = self.conn.recv(256)
                if not data:
                    break
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    self.handle(line.decode())
                if self.drop_next:
                    self.drop_next = False
                    self.conn.close()
                    break

    def handle(self, cmd):
        self.commands.append(cmd)
        if cmd == "ENROLL":
            self.send("FINGER NEEDED", "FINGER DOWN", "ACQUIRED 1 0",
                      f"PROGRESS {ENROLL_ID} 38", "FINGER UP", "FINGER DOWN",
                      "ACQUIRED 2 0", "FINGER UP")
            for remaining in range(36, -1, -2):
                self.send("FINGER DOWN", f"PROGRESS {ENROLL_ID} {remaining}", "FINGER UP")
            self.enrolled.append(ENROLL_ID)
            self.send(f"ENROLLED {ENROLL_ID}")
        elif cmd == "AUTH":
            self.send("FINGER NEEDED")
            if self.hold_auth:
                return  # wait for CANCEL
            answer = self.auth_answers.pop(0) if self.auth_answers else "NOMATCH"
            self.send("FINGER DOWN", "ACQUIRED 1 0", answer, "FINGER UP")
        elif cmd == "CANCEL":
            self.send("ERROR 5")
        elif cmd == "LIST":
            self.send("LIST" + "".join(f" {i}" for i in self.enrolled))
        elif cmd.startswith("DELETE "):
            i = int(cmd.split()[1])
            if i in self.enrolled:
                self.enrolled.remove(i)
                self.send(f"DELETED {i}")
            else:
                self.send("ERROR 6")
        else:
            self.send("ERROR 2")


failures = 0


def check(what, ok):
    global failures
    print(f"{'ok  ' if ok else 'FAIL'} {what}")
    if not ok:
        failures += 1


def main():
    tmp = tempfile.mkdtemp(prefix="omandroid-udfps-")
    path = os.path.join(tmp, "bridge.sock")
    bridge = FakeBridge(path)
    bridge.start()
    os.environ["FP_OMANDROID_UDFPS"] = path

    ctx = FPrint.Context()
    devices = [d for d in ctx.get_devices() if d.get_driver() == "omandroid_udfps"]
    check("device found through FP_OMANDROID_UDFPS", len(devices) == 1)
    if not devices:
        return 1
    dev = devices[0]
    check("features: verify, identify, storage",
          dev.has_feature(FPrint.DeviceFeature.VERIFY)
          and dev.has_feature(FPrint.DeviceFeature.IDENTIFY)
          and dev.has_feature(FPrint.DeviceFeature.STORAGE))
    check("20 enroll stages", dev.get_nr_enroll_stages() == 20)

    dev.open_sync()

    template = FPrint.Print.new(dev)
    template.set_finger(FPrint.Finger.RIGHT_THUMB)
    template.set_username("tester")
    stages = []

    def progress(device, completed, print_, user_data, error):
        stages.append((completed, error.message if error else None))

    enrolled = dev.enroll_sync(template, None, progress, None)
    check("enroll completes", enrolled is not None)
    check("enroll reports a retry for PARTIAL", any(e for _, e in stages))
    check("enroll progress reaches 20", stages and stages[-1][0] == 20)
    data = enrolled.get_property("fpi-data")
    check("print carries the HAL id", data.unpack() == (ENROLL_ID,))
    check("print is device-stored", enrolled.props.device_stored)

    listed = dev.list_prints_sync()
    check("list returns the enrolled id",
          [p.get_property("fpi-data").unpack() for p in listed] == [(ENROLL_ID,)])

    bridge.auth_answers = [f"MATCH {ENROLL_ID}"]
    match, _ = dev.verify_sync(enrolled)
    check("verify: MATCH of the same id matches", match)

    bridge.auth_answers = ["MATCH 42"]
    match, _ = dev.verify_sync(enrolled)
    check("verify: MATCH of another id fails", not match)

    bridge.auth_answers = ["NOMATCH"]
    match, _ = dev.verify_sync(enrolled)
    check("verify: NOMATCH fails", not match)

    bridge.auth_answers = [f"MATCH {ENROLL_ID}"]
    found, _ = dev.identify_sync([enrolled])
    check("identify: finds the enrolled print", found is not None and found.equal(enrolled))

    bridge.auth_answers = ["LOCKOUT 30000"]
    try:
        dev.verify_sync(enrolled)
        check("lockout is an error", False)
    except GLib.Error as e:
        check("lockout is an error", "Too many attempts" in e.message)

    # cancel: the bridge holds AUTH until CANCEL, then answers ERROR 5
    bridge.hold_auth = True
    cancellable = Gio.Cancellable()
    GLib.timeout_add(200, lambda: cancellable.cancel() and False)
    try:
        dev.verify_sync(enrolled, cancellable)
        check("cancel ends verify", False)
    except GLib.Error as e:
        check("cancel ends verify as cancelled",
              e.matches(Gio.io_error_quark(), Gio.IOErrorEnum.CANCELLED))
    check("cancel sent CANCEL", "CANCEL" in bridge.commands)
    bridge.hold_auth = False

    dev.delete_print_sync(enrolled)
    check("delete removes it", bridge.enrolled == [])
    try:
        dev.delete_print_sync(enrolled)
        check("delete of a missing print fails", False)
    except GLib.Error as e:
        check("delete of a missing print fails as not found",
              e.matches(FPrint.device_error_quark(), FPrint.DeviceError.DATA_NOT_FOUND))

    # the bridge goes away mid-verify
    bridge.hold_auth = True
    bridge.drop_next = True
    try:
        dev.verify_sync(enrolled)
        check("lost bridge fails the action", False)
    except GLib.Error as e:
        check("lost bridge fails the action", True)
        print(f"     ({e.message})")

    dev.close_sync()
    bridge.sock.close()
    print(f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
