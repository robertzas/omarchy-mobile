# SPDX-License-Identifier: MIT
"""Unit tests for the SIT codec and the daemon's guards (no simulator)."""
import asyncio
import os
import struct
import sys
import tempfile
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import sit  # noqa: E402
import sitd  # noqa: E402

# Expected total request lengths, from the stock builders (spec section 3).
LENGTHS = {
    sit.SET_RADIO_POWER: (sit.build_radio_power(True), 18),
    sit.VERIFY_SIM_PIN: (sit.build_verify_pin("1234", b"\xa0" * 16), 38),
    sit.GET_IMSI: (sit.build_aid(b"\xa0" * 16), 29),
    sit.SETUP_DATA_CALL: (sit.build_setup_data_call(1, "test.apn"), 246),
    sit.SET_INITIAL_ATTACH_APN: (sit.build_initial_attach_apn("test.apn"), 251),
    sit.DEACT_DATA_CALL: (sit.build_deact_data_call(1), 14),
    sit.SET_PS_SERVICE: (sit.build_ps_service(True), 13),
    sit.SEND_SMS: (sit.build_send_sms(b"\x01" * 20), 271),
    sit.SEND_SMS_ACK: (sit.build_sms_ack(), 21),
    sit.SET_MODEM_CONFIG: (sit.build_modem_config(), 13),
    sit.SET_AP_SYSTEM_TIME: (sit.build_ap_time(__import__("time").localtime()), 18),
    sit.SET_LOGICAL_TO_PHYSICAL_SLOT_MAPPING: (sit.build_slot_mapping(), 17),
}


class Header(unittest.TestCase):
    def test_request_header(self):
        raw = sit.request(sit.GET_SIM_STATUS, 7)
        self.assertEqual(raw, struct.pack("<BBHHIBB", 0, 0, 0x0200, 12, 7, 0, 0))

    def test_parse_response_and_indication(self):
        m = sit.Message(struct.pack("<BBHHIBB", 1, 0, 0x0400, 14, 0x01020304, 3, 0) + b"\x01\x02")
        self.assertEqual((m.type, m.id, m.token, m.error, m.u8(12)), (1, 0x0400, 0x01020304, 3, 1))
        i = sit.Message(struct.pack("<BBHHH", 2, 0, 0x0802, 12, 0) + struct.pack("<I", 2))
        self.assertEqual((i.type, i.name, sit.parse_radio_state(i)), (2, "IND_RADIO_STATE_CHANGED", 2))
        with self.assertRaises(ValueError):
            sit.Message(b"\x01\x00")

    def test_lengths(self):
        for mid, (params, total) in LENGTHS.items():
            self.assertEqual(len(sit.request(mid, 1, params)), total, sit.name(mid))

    def test_names(self):
        self.assertEqual(len(sit.NAMES), 602)
        self.assertEqual(sit.name(0x0803), "IND_RADIO_READY")


class Guard(unittest.TestCase):
    def test_denied_refused(self):
        self.assertTrue(sit.DENIED)
        for mid in sit.DENIED:
            with self.assertRaises(sit.SendRefused, msg=sit.name(mid)):
                sit.request(mid, 1)

    def test_every_denied_name_known(self):
        names = set(sit.NAMES.values())
        self.assertEqual(sit.DENIED_NAMES - names, set())

    def test_families(self):
        for mid in (0x0E00, 0x0E02, 0x1300, 0x1305, 0x1308):
            with self.assertRaises(sit.SendRefused):
                sit.request(mid, 1)

    def test_allowlist_disjoint(self):
        self.assertEqual(sit.ALLOWED & sit.DENIED, frozenset())

    def test_unlisted_refused(self):
        # identity and anything else the client has no use for
        for mid in (0x0401, 0x0402, 0x0202, 0x0931, 0x0001, 0x0505, 0xFFFF):
            with self.assertRaises(sit.SendRefused, msg=sit.name(mid)):
                sit.request(mid, 1)


class Layouts(unittest.TestCase):
    def test_setup_data_call(self):
        raw = sit.request(sit.SETUP_DATA_CALL, 1, sit.build_setup_data_call(
            1, "internet", "u", "p", "chap", "ipv4v6"))
        self.assertEqual(raw[0x0C], 1)
        self.assertEqual(raw[0x0D], sit.RAT_LTE)
        self.assertEqual(raw[0x10:0x18], b"internet")
        self.assertEqual(raw[0x75], ord("u"))
        self.assertEqual(raw[0xA7], ord("p"))
        self.assertEqual((raw[0xD9], raw[0xDA]), (2, 3))

    def test_verify_pin(self):
        raw = sit.request(sit.VERIFY_SIM_PIN, 1, sit.build_verify_pin("123456", b"\xa1\xa2"))
        self.assertEqual(raw[0x0C], 6)
        self.assertEqual(raw[0x0D:0x13], b"123456")
        self.assertEqual((raw[0x15], raw[0x16:0x18]), (2, b"\xa1\xa2"))
        for bad in ("12", "123456789", "12a4"):
            with self.assertRaises(ValueError):
                sit.build_verify_pin(bad, b"")

    def _resp(self, mid, params):
        return sit.Message(struct.pack("<BBHHIBB", 1, 0, mid, 12 + len(params), 1, 0, 0) + params)

    def test_sim_status(self):
        app = bytearray(63)
        app[0], app[1], app[3] = 2, 5, 2
        app[4:6] = b"\xa0\x01"
        app[57], app[59], app[60] = 3, 3, 10
        st = sit.parse_sim_status(self._resp(0x0200, bytes([1, 0, 1]) + bytes(app)))
        a = st["apps"][0]
        self.assertEqual((st["card_state"], a["type"], a["state"], a["aid"], a["pin1"], a["pin1_retries"],
                          a["puk1_retries"]), (1, 2, 5, b"\xa0\x01", 3, 3, 10))

    def test_data_call_short(self):
        p = bytearray(0x61 - 12)
        struct.pack_into("<hBBB", p, 0, 0, 1, 1, 3)
        p[0x11 - 12:0x15 - 12] = bytes([192, 0, 2, 2])
        p[0x39 - 12:0x3D - 12] = bytes([192, 0, 2, 53])
        c = sit.parse_data_call(self._resp(0x0600, bytes(p)))
        self.assertEqual((c["cid"], c["active"], c["ipv4"], c["ipv6"], c["dns"]),
                         (1, 1, "192.0.2.2", None, ["192.0.2.53"]))

    def test_data_call_long_refused(self):
        with self.assertRaises(sit.Unsupported):
            sit.parse_data_call(self._resp(0x0600, bytes(0x84 + 40)))

    def test_operator(self):
        p = bytearray(0x72 - 12)
        p[0:6] = b"00101#"
        p[6:10] = b"Test"
        p[0x32 - 12:0x32 - 12 + 4] = b"Long"
        self.assertEqual(sit.parse_operator(self._resp(0x0702, bytes(p))),
                         {"plmn": "00101", "short": "Test", "long": "Long"})


class Sms(unittest.TestCase):
    def test_gsm7_roundtrip(self):
        for text in ("hello", "{price} is 5€ ~ [ok]", "x" * 160, ""):
            s = sit.gsm7_septets(text)
            for fill in (0, 1, 6):
                self.assertEqual(sit.gsm7_decode(sit.gsm7_unpack(sit.gsm7_pack(s, fill), len(s), fill)), text)

    def test_submit_single(self):
        [t] = sit.encode_submit("+15550101", "hi", ref=1)
        self.assertEqual(t[:4], bytes([0x11, 0x00, 8, 0x91]))
        self.assertEqual(t[4:8], bytes.fromhex("51551010"))
        self.assertEqual(t[8:12], bytes([0, 0x00, 0xA7, 2]))
        self.assertEqual(sit.gsm7_decode(sit.gsm7_unpack(t[12:], 2)), "hi")

    def test_submit_ucs2_and_concat(self):
        [t] = sit.encode_submit("5550101", "héllo ✓")
        self.assertEqual(t[1 + 1 + 1 + 1 + 4 + 1], 0x08)
        parts = sit.encode_submit("5550101", "y" * 300, ref=9)
        self.assertEqual(len(parts), 2)
        for n, t in enumerate(parts):
            self.assertTrue(t[0] & 0x40)
            self.assertLessEqual(len(t), 244)
        with self.assertRaises(ValueError):
            sit.encode_submit("not a number", "x")

    def _deliver(self, sender_digits, udh, text):
        d = sender_digits + ("F" if len(sender_digits) % 2 else "")
        bcd = bytes(int(d[i + 1] + d[i], 16) for i in range(0, len(d), 2))
        sept = sit.gsm7_septets(text)
        if udh:
            fill = (7 - (len(udh) * 8) % 7) % 7
            ud = udh + sit.gsm7_pack(sept, fill)
            udl = (len(udh) * 8 + fill) // 7 + len(sept)
        else:
            ud, udl = sit.gsm7_pack(sept), len(sept)
        first = 0x04 | (0x40 if udh else 0)
        return bytes([0, first, len(sender_digits), 0x91]) + bcd + bytes([0, 0]) + \
            bytes.fromhex("62012131000000") + bytes([udl]) + ud

    def test_deliver(self):
        m = sit.decode_deliver(self._deliver("15550100", b"", "hello"))
        self.assertEqual((m["from"], m["text"], m["sent"], m["concat"]),
                         ("+15550100", "hello", "2026-10-12T13:00:00", None))
        m = sit.decode_deliver(self._deliver("15550100", bytes([5, 0, 3, 7, 2, 1]), "part one"))
        self.assertEqual((m["text"], m["concat"]), ("part one", {"ref": 7, "total": 2, "seq": 1}))


class Redact(unittest.TestCase):
    def test_redact(self):
        for s in ("001010000000001", "+15550100", "8900100000000000001", "+1 555 0100 12"):
            self.assertNotIn(s, sitd.redact("x %s y" % s))
        self.assertEqual(sitd.redact("CID 1 on rmnet0, 3 tries"), "CID 1 on rmnet0, 3 tries")


class WaitOnline(unittest.TestCase):
    def test_waits_for_online(self):
        seq = [3, 5, 4]

        class T:
            def cp_status(self):
                return seq.pop(0) if len(seq) > 1 else seq[0]

        with tempfile.TemporaryDirectory() as tmp:
            args = types.SimpleNamespace(run_dir=tmp, state_dir=tmp, allow_pin=False, radio_off=False,
                                         device=None)

            async def go():
                d = sitd.Daemon(sitd.Config(), args)
                orig = asyncio.sleep

                async def fast(_):
                    await orig(0)
                sitd.asyncio.sleep = fast
                try:
                    await d.wait_online(T())
                finally:
                    sitd.asyncio.sleep = orig
                return d.state["cp"]
            self.assertEqual(asyncio.run(go()), "online")

    def test_pin_refused_without_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = types.SimpleNamespace(run_dir=tmp, state_dir=tmp, allow_pin=False, radio_off=False,
                                         device=None)

            async def go():
                d = sitd.Daemon(sitd.Config(), args)
                with self.assertRaises(PermissionError):
                    await d.verify_pin("1234")
            asyncio.run(go())


if __name__ == "__main__":
    unittest.main()
