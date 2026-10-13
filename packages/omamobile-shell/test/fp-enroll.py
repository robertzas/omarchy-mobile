# SPDX-License-Identifier: MIT
# Tests for bin/omamobile-fp-enroll's pure helpers; no D-Bus needed. Run by test/all.
import importlib.machinery
import importlib.util
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("fp_enroll", os.path.join(here, "..", "bin", "omamobile-fp-enroll"))
spec = importlib.util.spec_from_loader("fp_enroll", loader)
enroll = importlib.util.module_from_spec(spec)
loader.exec_module(enroll)

failed = 0


def check(name, fn):
    global failed
    try:
        fn()
        print("ok - fp enroll: " + name)
    except AssertionError as error:
        failed += 1
        print("not ok - fp enroll: %s\n  %s" % (name, error), file=sys.stderr)


def fingers():
    assert enroll.next_finger([]) == "right-index-finger"
    assert enroll.next_finger(["right-index-finger"]) == "left-index-finger"
    assert enroll.next_finger(["right-index-finger", "left-index-finger"]) == "right-thumb"
    assert enroll.next_finger(list(enroll.FINGERS)) is None
    assert len(set(enroll.FINGERS)) == 10


def results():
    assert enroll.final_status("enroll-completed") == (True, True)
    assert enroll.final_status("enroll-stage-passed") == (False, False)
    assert enroll.final_status("enroll-retry-scan") == (False, False)
    for result in ("enroll-failed", "enroll-data-full", "enroll-disconnected",
                   "enroll-unknown-error", "enroll-duplicate"):
        assert enroll.final_status(result) == (True, False), result


def errors():
    assert enroll.error_kind("net.reactivated.Fprint.Error.AlreadyInUse") == "busy"
    assert enroll.error_kind("net.reactivated.Fprint.Error.PermissionDenied") == "denied"
    assert enroll.error_kind("net.reactivated.Fprint.Error.NoSuchDevice") == "no-device"
    assert enroll.error_kind("org.freedesktop.DBus.Error.ServiceUnknown") == "no-device"
    assert enroll.error_kind("net.reactivated.Fprint.Error.Internal") == "failed"


def commands():
    assert enroll.parse_command('{"cmd": "cancel"}') == {"cmd": "cancel"}
    assert enroll.parse_command("cancel") is None
    assert enroll.parse_command('{"event": "x"}') is None


def usage():
    assert enroll.main(["bogus"]) == 2


check("the next free finger, index fingers first", fingers)
check("fprintd results that end an enrollment", results)
check("D-Bus errors become kinds the plugin words", errors)
check("stdin commands parse, junk doesn't", commands)
devnull = open(os.devnull, "w")
sys.stderr, saved = devnull, sys.stderr
try:
    check("an unknown mode is refused", usage)
finally:
    sys.stderr = saved
sys.exit(1 if failed else 0)
