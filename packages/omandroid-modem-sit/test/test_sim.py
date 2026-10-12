# SPDX-License-Identifier: MIT
"""omandroid-sitd against tools/sit-sim: first registration, a data call,
SMS both ways, the PIN gate, and the do-not-send list. ip(8) and
resolvectl are stand-ins that log their arguments; nothing touches the
host's network. SIT_SIM names the simulator (test/all finds it)."""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
SIM = os.environ.get("SIT_SIM") or os.path.join(PKG, "..", "..", "tools", "sit-sim")

TEST_IMSI = "001010000000001"
TEST_SENDER = "15550100"

FAKE = """#!/bin/sh
echo "$*" >> "$FAKE_LOG_DIR/{name}.log"
"""


@unittest.skipUnless(os.path.exists(SIM), "tools/sit-sim not found (set SIT_SIM)")
class SimTest(unittest.TestCase):
    sim_args = []
    daemon_args = []
    config = ""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sitd-test.")
        self.run_dir = os.path.join(self.tmp, "run")
        self.state_dir = os.path.join(self.tmp, "state")
        fake = os.path.join(self.tmp, "bin")
        os.makedirs(fake)
        for name in ("ip", "resolvectl"):
            p = os.path.join(fake, name)
            with open(p, "w") as f:
                f.write(FAKE.format(name=name))
            os.chmod(p, 0o755)
        cfg = os.path.join(self.tmp, "modem-sit.conf")
        with open(cfg, "w") as f:
            f.write("[modem]\nradio_ready_timeout = 1\npoll_searching = 0.3\npoll_registered = 2\n"
                    "request_timeout = 3\n[data]\nretry = 1\ndns = auto\n" + self.config)
        self.sock = os.path.join(self.tmp, "sit.sock")
        self.transcript = os.path.join(self.tmp, "transcript.jsonl")
        self.env = dict(os.environ, PATH=fake + os.pathsep + os.environ["PATH"], FAKE_LOG_DIR=self.tmp,
                        OMANDROID_SIT_RUN=self.run_dir, OMANDROID_SIT_STATE=self.state_dir)
        self.sim = subprocess.Popen([sys.executable, SIM, "--listen", self.sock,
                                     "--transcript", self.transcript, *self.sim_args])
        for _ in range(100):
            if os.path.exists(self.sock):
                break
            time.sleep(0.05)
        self.log = open(os.path.join(self.tmp, "sitd.log"), "w")
        self.daemon = subprocess.Popen([sys.executable, os.path.join(PKG, "bin", "omandroid-sitd"),
                                        "--config", cfg, "--device", "unix:" + self.sock, "-v",
                                        *self.daemon_args],
                                       env=self.env, stderr=self.log, stdout=self.log)

    def tearDown(self):
        self.daemon.terminate()
        self.daemon.wait(10)
        self.sim.terminate()
        self.sim.wait(10)
        self.log.close()
        # Nothing identifying reaches the log, whatever happened above.
        log = self.daemon_log()
        for secret in (TEST_IMSI, TEST_SENDER, "hello from sim", "1234"):
            self.assertNotIn(secret, log, "the daemon logged an identifier or a message")
        violations = [e for e in self.events() if "violation" in e]
        self.assertEqual(violations, [], "the simulator saw a request it should not")
        if os.environ.get("KEEP"):
            print("kept", self.tmp, file=sys.stderr)
        else:
            subprocess.run(["rm", "-rf", self.tmp])

    # ---- helpers ---------------------------------------------------------

    def daemon_log(self):
        with open(os.path.join(self.tmp, "sitd.log")) as f:
            return f.read()

    def events(self):
        try:
            with open(self.transcript) as f:
                return [json.loads(line) for line in f]
        except FileNotFoundError:
            return []

    def requests(self):
        return [e["name"] for e in self.events() if e.get("dir") == "in"]

    def fake_log(self, name):
        try:
            with open(os.path.join(self.tmp, name + ".log")) as f:
                return f.read()
        except FileNotFoundError:
            return ""

    def call(self, req):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(20)
            s.connect(os.path.join(self.run_dir, "control"))
            s.sendall((json.dumps(req) + "\n").encode())
            with s.makefile("r") as f:
                return json.loads(f.readline())

    def cli(self, *a):
        return subprocess.run([sys.executable, os.path.join(PKG, "bin", "omandroid-sit"), *a],
                              env=self.env, capture_output=True, text=True, timeout=30)

    def wait(self, pred, what, timeout=15):
        end = time.time() + timeout
        st = None
        while time.time() < end:
            try:
                st = self.call({"cmd": "status"})["state"]
                if pred(st):
                    return st
            except (OSError, ValueError, KeyError):
                pass
            time.sleep(0.1)
        self.fail("timed out waiting for %s; last state %s\n%s" % (what, st, self.daemon_log()))


class FirstRegistration(SimTest):
    sim_args = ["--incoming-sms"]
    config = "enabled = yes\napn = test.apn\n"

    def test_registration_data_sms(self):
        st = self.wait(lambda s: s["data_reg"]["reg"] == "home" and s["voice"]["reg"] == "home",
                       "first registration")
        self.assertEqual(st["sim"]["state"], "ready")
        self.assertTrue(st["sim"]["imsi_read"])
        self.assertNotIn(TEST_IMSI, json.dumps(st))
        st = self.wait(lambda s: s["data"]["state"] == "connected", "the data call")
        self.assertEqual((st["data"]["iface"], st["data"]["ipv4"], st["data"]["ipv6"]),
                         ("rmnet0", "192.0.2.2", "2001:db8::2"))
        self.assertEqual(st["operator"], {"plmn": "00101", "short": "Test", "long": "Test Network"})
        self.assertEqual(st["data_reg"]["rat"], "LTE")

        # the order of the start-up sequence (spec section 5)
        req = self.requests()
        order = ["SET_RADIO_POWER", "GET_SIM_STATUS", "GET_IMSI", "SET_INITIAL_ATTACH_APN",
                 "SET_NTW_MODE_AUTO", "SET_PS_SERVICE", "GET_PS_REG_STATE", "SETUP_DATA_CALL"]
        idx = [req.index(n) for n in order]
        self.assertEqual(idx, sorted(idx), req)
        for never in ("GET_IMEI", "GET_IMEISV", "VERIFY_SIM_PIN", "SET_MODEM_CONFIG",
                      "SET_LOGICAL_TO_PHYSICAL_SLOT_MAPPING", "SEND_SMS"):
            self.assertNotIn(never, req)
        setup = [e for e in self.events() if e.get("event") == "setup_data_call"][0]
        self.assertEqual((setup["cid"], setup["apn"], setup["pdp"], setup["auth"]), (1, "test.apn", 3, 0))

        ip = self.fake_log("ip")
        for line in ("addr flush dev rmnet0", "link set dev rmnet0 up", "addr add 192.0.2.2/32 dev rmnet0",
                     "route replace default dev rmnet0 metric 700",
                     "-6 addr add 2001:db8::2/64 dev rmnet0 nodad"):
            self.assertIn(line, ip)
        self.assertIn("dns rmnet0 192.0.2.53 2001:db8::53", self.fake_log("resolvectl"))

        # incoming SMS: acked, stored, readable, not logged
        self.wait(lambda s: s["sms"]["received"] == 1, "the incoming SMS")
        self.assertIn("SEND_SMS_ACK", self.requests())
        ack = [e for e in self.events() if e.get("name") == "SEND_SMS_ACK" and e.get("dir") == "in"][0]
        self.assertEqual(bytes.fromhex(ack["hex"])[12:16], b"\x01\0\0\0")
        r = self.call({"cmd": "sms-list"})
        self.assertEqual([(m["from"], m["text"]) for m in r["messages"]], [("+" + TEST_SENDER, "hello from sim")])

        # outgoing SMS, only on request
        out = self.cli("sms", "send", "+15550101", "hi from omandroid")
        self.assertEqual(out.returncode, 0, out.stderr)
        sent = [e for e in self.events() if e.get("event") == "send_sms"]
        self.assertEqual(len(sent), 1)
        tpdu = bytes.fromhex(sent[0]["tpdu"])
        self.assertEqual(tpdu[:8], bytes([0x11, 0, 8, 0x91]) + bytes.fromhex("51551010"))
        self.assertEqual(sent[0]["smsc_len"], 1)

        # the status CLI and the tile's JSON
        out = self.cli("status")
        self.assertIn("mobile data: on, connected on rmnet0", out.stdout)
        js = json.loads(self.cli("status", "--json").stdout)
        self.assertEqual(js["data"]["state"], "connected")

        # mobile data off: the call goes, rmnet0 goes down, the switch is saved
        self.assertEqual(self.cli("data", "off").returncode, 0)
        st = self.wait(lambda s: s["data"]["state"] == "off", "data off")
        self.assertIn("DEACT_DATA_CALL", self.requests())
        self.assertIn("link set dev rmnet0 down", self.fake_log("ip"))
        self.assertIn("revert rmnet0", self.fake_log("resolvectl"))
        with open(os.path.join(self.state_dir, "mobile-data")) as f:
            self.assertEqual(f.read().strip(), "off")
        # and on again
        self.assertEqual(self.cli("data", "on").returncode, 0)
        self.wait(lambda s: s["data"]["state"] == "connected", "data on again")


class RadioOff(SimTest):
    daemon_args = ["--radio-off"]
    config = "enabled = yes\napn = test.apn\n"

    def test_radio_stays_off(self):
        self.wait(lambda s: s["sim"]["state"] == "ready", "the SIM read")
        time.sleep(1)
        req = self.requests()
        self.assertNotIn("SET_RADIO_POWER", req)
        self.assertNotIn("SETUP_DATA_CALL", req)


class DataOffByDefault(SimTest):
    config = "apn = test.apn\n"

    def test_no_data_call(self):
        self.wait(lambda s: s["data_reg"]["reg"] == "home", "registration")
        time.sleep(1)
        self.assertNotIn("SETUP_DATA_CALL", self.requests())
        self.assertEqual(self.call({"cmd": "status"})["state"]["data"]["state"], "off")


class PinWithoutFlag(SimTest):
    sim_args = ["--pin-locked"]

    def test_stops_at_pin(self):
        self.wait(lambda s: s["sim"]["state"] == "pin-required", "the PIN stop")
        r = self.call({"cmd": "pin", "pin": "1234"})
        self.assertFalse(r["ok"])
        self.assertIn("--allow-pin", r["error"])
        time.sleep(0.5)
        req = self.requests()
        self.assertNotIn("VERIFY_SIM_PIN", req)
        self.assertNotIn("GET_IMSI", req)


class PinWithFlag(SimTest):
    sim_args = ["--pin-locked", "--pin", "1234"]
    daemon_args = ["--allow-pin"]

    def test_pin(self):
        self.wait(lambda s: s["sim"]["state"] == "pin-required" and s["sim"]["pin1_retries"] == 3, "the PIN stop")
        r = self.call({"cmd": "pin", "pin": "0000"})
        self.assertFalse(r["ok"])
        self.assertIn("2 tries left", r["error"])
        r = self.call({"cmd": "pin", "pin": "1234"})
        self.assertTrue(r["ok"], r)
        self.wait(lambda s: s["data_reg"]["reg"] == "home", "registration after the PIN")
        self.assertEqual(self.requests().count("VERIFY_SIM_PIN"), 2)


class PinLastTry(SimTest):
    sim_args = ["--pin-locked", "--pin-retries", "1"]
    daemon_args = ["--allow-pin"]

    def test_last_try_refused(self):
        self.wait(lambda s: s["sim"]["state"] == "pin-required", "the PIN stop")
        r = self.call({"cmd": "pin", "pin": "1234"})
        self.assertFalse(r["ok"])
        self.assertIn("last one", r["error"])
        self.assertNotIn("VERIFY_SIM_PIN", self.requests())


class LongDataCall(SimTest):
    sim_args = ["--long-datacall"]
    config = "enabled = yes\napn = test.apn\n"

    def test_unsupported(self):
        st = self.wait(lambda s: s["data"]["state"] == "unsupported", "the v11 refusal")
        self.assertIn("v11", st["data"]["error"])
        self.assertNotIn("addr add", self.fake_log("ip"))


class SimGone(SimTest):
    config = "enabled = yes\napn = test.apn\n"

    def test_reconnect(self):
        self.wait(lambda s: s["data"]["state"] == "connected", "the data call")
        self.sim.terminate()
        self.sim.wait(5)
        self.wait(lambda s: s["daemon"] == "waiting" and s["data"]["state"] == "waiting", "the link loss")
        self.assertIn("link set dev rmnet0 down", self.fake_log("ip"))
        self.sim = subprocess.Popen([sys.executable, SIM, "--listen", self.sock,
                                     "--transcript", self.transcript])
        self.wait(lambda s: s["data"]["state"] == "connected", "the data call after a reconnect", 30)


if __name__ == "__main__":
    unittest.main()
