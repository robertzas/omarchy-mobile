# SPDX-License-Identifier: MIT
"""SIT codec for omandroid-sitd: the message header, the send guard, request
builders and response/indication parsers for the messages a first client
needs, and SMS PDUs.

Layouts are device/cheetah/MODEM-SIT-RESEARCH.md sections 1.3 and 3. All
offsets below are absolute in the SIT message (a request or response header
is 12 bytes, an indication header 8), so they read the same as the spec's
tables. Multi-byte fields are little-endian and unaligned.

Nothing here logs. Identifiers (IMSI, IMEI, ICCID, phone numbers) pass
through these functions as values only; omandroid-sitd decides what to show.
"""
import ipaddress
import struct

from sit_names import NAMES

TYPE_REQ, TYPE_RESP, TYPE_IND = 0, 1, 2
REQ_HDR = 12
IND_HDR = 8
MAX_MSG = 64 * 1024 + 32   # libsitril's read buffer

# CPIF (MODEM-SIT-RESEARCH 1.2): _IO('o', 0x27) and the states it returns.
IOCTL_GET_CP_STATUS = (ord("o") << 8) | 0x27
CP_STATES = {0: "offline", 1: "crash-reset", 2: "crash-exit", 3: "booting",
             4: "online", 5: "nv-rebuilding"}
CP_ONLINE = 4

# Message IDs used by the client (section 3).
SEND_SMS = 0x0100
SEND_SMS_EXPECT_MORE = 0x0101
SEND_SMS_ACK = 0x0102
IND_NEW_SMS = 0x010C
GET_SIM_STATUS = 0x0200
VERIFY_SIM_PIN = 0x0201
IND_SIM_STATUS_CHANGED = 0x0210
SET_LOGICAL_TO_PHYSICAL_SLOT_MAPPING = 0x0250
GET_IMSI = 0x0400
SETUP_DATA_CALL = 0x0600
DEACT_DATA_CALL = 0x0601
GET_DATA_CALL_LIST = 0x0602
SET_INITIAL_ATTACH_APN = 0x0603
IND_DATA_CALL_LIST_CHANGED = 0x0604
GET_CS_REG_STATE = 0x0700
GET_PS_REG_STATE = 0x0701
GET_OPERATOR = 0x0702
GET_NTW_MODE = 0x0703
SET_NTW_MODE_AUTO = 0x0704
IND_NTW_STATE_CHANGED = 0x070E
SET_PS_SERVICE = 0x0710
SET_RADIO_POWER = 0x0800
GET_RADIO_POWER = 0x0801
IND_RADIO_STATE_CHANGED = 0x0802
IND_RADIO_READY = 0x0803
IND_PHONE_RESET = 0x0804
IND_MODEM_RESTART = 0x0805
GET_SIGNAL_STRENGTH = 0x0900
IND_SIGNAL_STRENGTH = 0x0906
SET_MODEM_CONFIG = 0x093F
SET_AP_SYSTEM_TIME = 0x0949

# The only requests this client ever writes. Everything else is refused by
# check_send() before it reaches the device, whatever the caller asks for.
# GET_IMEI/GET_IMEISV are deliberately absent: the daemon has no use for them.
ALLOWED = frozenset({
    SET_RADIO_POWER, GET_RADIO_POWER,
    GET_SIM_STATUS, VERIFY_SIM_PIN, GET_IMSI,
    SET_LOGICAL_TO_PHYSICAL_SLOT_MAPPING, SET_MODEM_CONFIG, SET_AP_SYSTEM_TIME,
    GET_CS_REG_STATE, GET_PS_REG_STATE, GET_OPERATOR, GET_NTW_MODE,
    SET_NTW_MODE_AUTO, SET_PS_SERVICE, GET_SIGNAL_STRENGTH,
    SET_INITIAL_ATTACH_APN, SETUP_DATA_CALL, DEACT_DATA_CALL, GET_DATA_CALL_LIST,
    SEND_SMS, SEND_SMS_EXPECT_MORE, SEND_SMS_ACK,
})

# The spec's do-not-send list (MODEM-SIT-RESEARCH section 5): NV writes,
# identity, carrier and lock state, AT forwarding, VSIM and satellite.
# Checked as well as ALLOWED, so a later edit to ALLOWED can't let one through.
DENIED_NAMES = frozenset({
    "SET_RADIO_NODE_VALUE", "SET_RADIO_NODE", "EXEC_RADIO_NODE", "SET_CFG_DEFAULT",
    "SET_ENG_MODE", "SET_ENG_STRING_INPUT", "SET_SELFLOG", "SET_SELFLOG_PROFILE",
    "SET_MODEM_LOG_DUMP", "SET_CARRIER_INFO_IMSI_ENCRYPTION", "SET_CARRIER_RESTRICTIONS",
    "SET_CARRIER_RESTRICTIONS_V2", "OEM_SET_CARRIER_CONFIG_MANIFEST", "SET_SIM_CARD_POWER",
    "SET_FACILITY_LOCK", "CHG_SIM_PIN", "CHG_SIM_PIN2", "VERIFY_NETWORK_LOCK",
    "SET_FORWARDING_AT_COMMAND",
    "SET_SATELLITE_MODE_SERVICE", "SET_SATELLITE_PLMN_LIST",
})
DENIED_FAMILIES = (0x0E, 0x13)   # VSIM, NTN (satellite)
DENIED = frozenset(i for i, n in NAMES.items()
                   if n in DENIED_NAMES or (i >> 8) in DENIED_FAMILIES)

ERRORS = {
    0: "SUCCESS", 1: "RADIO_NOT_AVAILABLE", 2: "GENERIC_FAILURE", 3: "PASSWORD_INCORRECT",
    4: "SIM_PIN2", 5: "SIM_PUK2", 6: "REQUEST_NOT_SUPPORTED", 7: "CANCELLED",
    8: "OP_NOT_ALLOWED_DURING_VOICE_CALL", 9: "OP_NOT_ALLOWED_BEFORE_REG_TO_NW",
    10: "SMS_SEND_FAIL_RETRY", 11: "SIM_ABSENT", 12: "SUBSCRIPTION_NOT_AVAILABLE",
    13: "MODE_NOT_SUPPORTED", 14: "FDN_CHECK_FAILURE", 15: "ILLEGAL_SIM_OR_ME",
    16: "MISSING_RESOURCE", 17: "NO_SUCH_ELEMENT", 18: "SIM_MEMORY_FULL",
    19: "PB_TOO_LONG_DATA", 20: "SIM_PIN_REQ", 21: "SIM_PUK_REQ", 22: "UNDEFINED_CMD",
    23: "NOT_ALLOWED_DURING_PLMN_SEARCH", 24: "NOT_ALLOWED_DURING_PLMN_SEARCH",
    25: "SIMULTANEOUS_SMS_AND_CALL_NOT_ALLOWED", 26: "ACCESS_BARRED", 27: "BLOCKED_DUE_TO_CALL",
    28: "RF_HARDWARE_ISSUE", 29: "NO_RF_CALIBRATION_INFO", 30: "MODEM_ERR",
    31: "NOT_ALLOWED_DURING_CARRIER_CONFIG", 33: "PARSING_FAILURE",
}
E_SUCCESS, E_PASSWORD_INCORRECT = 0, 3

RADIO_STATES = {0: "initialized", 1: "stop-network", 2: "start-network", 3: "power-off", 4: "reset"}
REG_STATES = {0: "not-registered", 1: "home", 2: "searching", 3: "denied", 4: "unknown", 5: "roaming"}
REG_HOME, REG_ROAMING = 1, 5
# SIT RAT -> name (section 3.3: 1-16 as Android, then the reshuffled ones).
RATS = {0: "unknown", 1: "GPRS", 2: "EDGE", 3: "UMTS", 4: "IS95A", 5: "IS95B", 6: "1xRTT",
        7: "EVDO_0", 8: "EVDO_A", 9: "HSDPA", 10: "HSUPA", 11: "HSPA", 12: "EVDO_B",
        13: "EHRPD", 14: "LTE", 15: "HSPAP", 16: "GSM", 17: "IWLAN", 18: "TD_SCDMA",
        19: "HSPA", 20: "LTE_CA", 21: "NR", 22: "NR"}
RAT_LTE = 14
# PIN states, as Android's RIL_PinState (medium: by analogy).
PIN_STATES = {0: "unknown", 1: "enabled-not-verified", 2: "enabled-verified", 3: "disabled",
              4: "blocked", 5: "perm-blocked"}
PIN_NOT_VERIFIED, PIN_BLOCKED, PIN_PERM_BLOCKED = 1, 4, 5
AUTH = {"none": 0, "pap": 1, "chap": 2, "papchap": 3}
PDP = {"ipv4": 1, "ipv6": 2, "ipv4v6": 3}


class SendRefused(Exception):
    """A request the send guard refuses."""


def name(msg_id):
    return NAMES.get(msg_id, "0x%04x" % msg_id)


def check_send(msg_id):
    if msg_id in DENIED or (msg_id >> 8) in DENIED_FAMILIES:
        raise SendRefused("%s is on the do-not-send list" % name(msg_id))
    if msg_id not in ALLOWED:
        raise SendRefused("%s is not a request this client sends" % name(msg_id))


def request(msg_id, token, params=b""):
    """A whole request message. The send guard runs here, so every write
    goes through it."""
    check_send(msg_id)
    length = REQ_HDR + len(params)
    if length > 0xFFFF:
        raise ValueError("request too long")
    return struct.pack("<BBHHIBB", TYPE_REQ, 0, msg_id, length, token & 0xFFFFFFFF, 0, 0) + params


class Message:
    """A parsed message. `raw` is the whole message, so the spec's absolute
    offsets index it directly."""
    __slots__ = ("type", "id", "length", "token", "error", "raw")

    def __init__(self, raw):
        if len(raw) < IND_HDR:
            raise ValueError("short message (%d bytes)" % len(raw))
        self.type, _, self.id, self.length = struct.unpack_from("<BBHH", raw)
        self.raw = bytes(raw)
        self.token = self.error = None
        if self.type in (TYPE_REQ, TYPE_RESP):
            if len(raw) < REQ_HDR:
                raise ValueError("short response (%d bytes)" % len(raw))
            self.token, self.error = struct.unpack_from("<IB", raw, 6)
        elif self.type != TYPE_IND:
            raise ValueError("unknown message type %d" % self.type)
        # One read is one message (the kernel reassembles), so the read
        # length is authoritative; `length` is what the header declared.

    @property
    def name(self):
        return name(self.id)

    def u8(self, off, default=None):
        return self.raw[off] if off < len(self.raw) else default

    def u16(self, off, default=None):
        return struct.unpack_from("<H", self.raw, off)[0] if off + 2 <= len(self.raw) else default

    def s16(self, off, default=None):
        return struct.unpack_from("<h", self.raw, off)[0] if off + 2 <= len(self.raw) else default

    def u32(self, off, default=None):
        return struct.unpack_from("<I", self.raw, off)[0] if off + 4 <= len(self.raw) else default

    def bytes_at(self, off, n):
        return self.raw[off:off + n]

    def cstr(self, off, n):
        return self.raw[off:off + n].split(b"\0", 1)[0].decode("utf-8", "replace").strip()


def _fixed(data, n):
    data = bytes(data)[:n]
    return data + b"\0" * (n - len(data))


def _u8(v):
    return struct.pack("<B", v & 0xFF)


# ----------------------------------------------------------------- builders

def build_radio_power(on):
    """SET_RADIO_POWER params (len 18): u32 2 on / 1 off, then two u8
    (for-emergency-call, preferred-for-emergency: both 0)."""
    return struct.pack("<IBB", 2 if on else 1, 0, 0)


def build_modem_config(stacks=1):
    return _u8(stacks)


def build_slot_mapping(physical=(0,)):
    """SET_LOGICAL_TO_PHYSICAL_SLOT_MAPPING (len 17): count, then 4 slots."""
    return _u8(len(physical)) + _fixed(bytes(physical), 4)


def build_ap_time(tm):
    """SET_AP_SYSTEM_TIME (len 18): six u8. The year's form is not checked in
    the spec (medium); this sends years since 2000 and a 1-based month."""
    return bytes([tm.tm_year % 100, tm.tm_mon, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec])


def build_aid(aid):
    """GET_IMSI params (len 29): u8 AID length, AID (16 bytes)."""
    aid = bytes(aid)[:16]
    return _u8(len(aid)) + _fixed(aid, 16)


def build_verify_pin(pin, aid):
    """VERIFY_SIM_PIN (len 38): u8 length, PIN ASCII (8), u8 AID length, AID (16)."""
    if not (pin.isdigit() and 4 <= len(pin) <= 8):
        raise ValueError("a PIN is 4 to 8 digits")
    aid = bytes(aid)[:16]
    return _u8(len(pin)) + _fixed(pin.encode(), 8) + _u8(len(aid)) + _fixed(aid, 16)


def _apn_front(cid, rat, apn, user, password, auth, pdp):
    """The shared front of SETUP_DATA_CALL and SET_INITIAL_ATTACH_APN, from
    0x0c to 0xdb (sit_pdp_setup_data_call_req)."""
    b = bytearray(0xDC - REQ_HDR)
    b[0x0C - 12] = cid
    b[0x0D - 12] = rat
    b[0x0E - 12] = 0          # mode flag (low): 0
    b[0x0F - 12] = 0          # APN type (medium): default
    b[0x10 - 12:0x75 - 12] = _fixed(apn.encode("ascii"), 101)
    b[0x75 - 12:0xA7 - 12] = _fixed(user.encode(), 50)
    b[0xA7 - 12:0xD9 - 12] = _fixed(password.encode(), 50)
    b[0xD9 - 12] = AUTH[auth]
    b[0xDA - 12] = PDP[pdp]
    b[0xDB - 12] = 0          # P-CSCF request type: none
    return b


def build_setup_data_call(cid, apn, user="", password="", auth="none", pdp="ipv4v6", rat=RAT_LTE):
    """SETUP_DATA_CALL, legacy form (total length 246)."""
    b = _apn_front(cid, rat, apn, user, password, auth, pdp)
    b += bytes(246 - REQ_HDR - len(b))
    return bytes(b)


def build_initial_attach_apn(apn, user="", password="", auth="none", pdp="ipv4v6", rat=RAT_LTE):
    """SET_INITIAL_ATTACH_APN (total length 251); roaming PDP type at 0xf8."""
    b = _apn_front(0, rat, apn, user, password, auth, pdp)
    b += bytes(251 - REQ_HDR - len(b))
    b[0xF8 - 12] = PDP[pdp]
    return bytes(b)


def build_deact_data_call(cid, reason=0):
    return bytes([cid, reason])


def build_ps_service(allow):
    return _u8(1 if allow else 0)


def build_send_sms(tpdu, domain=0):
    """SEND_SMS (len 271): domain, SMSC (none: length 1 and a 0x00 byte, 12
    bytes), TPDU length, TPDU (244)."""
    if len(tpdu) > 244:
        raise ValueError("TPDU too long")
    return _u8(domain) + _u8(1) + _fixed(b"\0", 12) + _u8(len(tpdu)) + _fixed(tpdu, 244)


def build_sms_ack(success=True, cause=0):
    """SEND_SMS_ACK (len 21): u32 result (1 success), u8 cause, u32."""
    return struct.pack("<IBI", 1 if success else 0, cause, 0)


# ------------------------------------------------------------------ parsers

def parse_radio_state(m):
    v = m.u32(IND_HDR) if m.type == TYPE_IND else m.u32(REQ_HDR)
    return v


SIM_APP_LEN = 63


def parse_sim_status(m):
    """GET_SIM_STATUS response: card state, universal PIN, app count, then
    63-byte application records from 0x0f."""
    st = {"card_state": m.u8(0x0C, 0), "upin_state": m.u8(0x0D, 0), "apps": []}
    count = min(m.u8(0x0E, 0), 100)
    for i in range(count):
        o = 0x0F + i * SIM_APP_LEN
        if o + SIM_APP_LEN > len(m.raw):
            break
        aid_len = min(m.u8(o + 3), 16)
        lab_len = min(m.u8(o + 20), 32)
        st["apps"].append({
            "type": m.u8(o), "state": m.u8(o + 1), "perso": m.u8(o + 2),
            "aid": m.bytes_at(o + 4, aid_len),
            "label": m.bytes_at(o + 21, lab_len).decode("utf-8", "replace"),
            "pin1": m.u8(o + 57), "pin2": m.u8(o + 58),
            "pin1_retries": m.u8(o + 59), "puk1_retries": m.u8(o + 60),
            "pin2_retries": m.u8(o + 61), "puk2_retries": m.u8(o + 62),
        })
    return st


def parse_imsi(m):
    n = min(m.u8(0x0C, 0), 15)
    return m.bytes_at(0x0D, n).decode("ascii", "replace")


def parse_cs_reg(m):
    return {"reg": m.u8(0x0C, 4), "reject": m.u8(0x0D, 0), "rat": m.u8(0x0E, 0)}


def parse_ps_reg(m):
    return {"reg": m.u8(0x0C, 4), "reject": m.u8(0x0D, 0), "max_calls": m.u8(0x0E, 0),
            "rat": m.u8(0x0F, 0)}


def parse_operator(m):
    plmn = m.bytes_at(0x0C, 6).decode("ascii", "replace").replace("#", "").strip("\0")
    return {"plmn": plmn, "short": m.cstr(0x12, 32), "long": m.cstr(0x32, 64)}


def _addr_slot(m, off):
    """A 20-byte address slot: IPv4 (4 bytes) then IPv6 (16). Zero = absent."""
    v4, v6 = m.bytes_at(off, 4), m.bytes_at(off + 4, 16)
    a4 = str(ipaddress.IPv4Address(v4)) if len(v4) == 4 and any(v4) else None
    a6 = str(ipaddress.IPv6Address(v6)) if len(v6) == 16 and any(v6) else None
    return a4, a6


DATA_CALL_SHORT_MAX = 0x90


class Unsupported(Exception):
    """A layout the spec doesn't decode yet."""


def parse_data_call(m):
    """SETUP_DATA_CALL response, short form only (total length < 0x90). The
    long "v11" form is open question 3 of the spec: refuse it rather than
    guess field positions."""
    if len(m.raw) >= DATA_CALL_SHORT_MAX:
        raise Unsupported("data call response in the long (v11) form, %d bytes" % len(m.raw))
    call = {"status": m.s16(0x0C, -1), "cid": m.u8(0x0E, 0), "active": m.u8(0x0F, 0),
            "pdp": m.u8(0x10, 0)}
    call["ipv4"], call["ipv6"] = _addr_slot(m, 0x11)
    call["gw4"], call["gw6"] = _addr_slot(m, 0x25)
    dns = []
    for off in (0x39, 0x4D):
        dns += [a for a in _addr_slot(m, off) if a]
    call["dns"] = dns
    return call


def parse_send_sms(m):
    return {"ref": m.u8(0x0C, 0)}


def parse_new_sms(m):
    """IND_NEW_SMS: u8 type, u8 PDU length, PDU (SMSC + TPDU)."""
    n = m.u8(0x09, 0)
    return m.u8(0x08, 0), m.bytes_at(0x0A, n)


# --------------------------------------------------------------------- SMS
# GSM 03.38 default alphabet and its extension table.
GSM7 = ("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\x1bÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?"
        "¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà")
GSM7_EXT = {0x0A: "\f", 0x14: "^", 0x28: "{", 0x29: "}", 0x2F: "\\", 0x3C: "[", 0x3D: "~",
            0x3E: "]", 0x40: "|", 0x65: "€"}
_GSM7_REV = {c: i for i, c in enumerate(GSM7)}
_GSM7_EXT_REV = {c: i for i, c in GSM7_EXT.items()}


def gsm7_septets(text):
    """The text as septets, or None if it needs UCS-2."""
    out = []
    for ch in text:
        if ch in _GSM7_REV and ch != "\x1b":
            out.append(_GSM7_REV[ch])
        elif ch in _GSM7_EXT_REV:
            out += [0x1B, _GSM7_EXT_REV[ch]]
        else:
            return None
    return out


def gsm7_pack(septets, fill=0):
    bits = nbits = 0
    out = bytearray()
    nbits = fill
    for s in septets:
        bits |= (s & 0x7F) << nbits
        nbits += 7
        while nbits >= 8:
            out.append(bits & 0xFF)
            bits >>= 8
            nbits -= 8
    if nbits:
        out.append(bits & 0xFF)
    return bytes(out)


def gsm7_unpack(data, count, fill=0):
    bits = int.from_bytes(data, "little")
    return [(bits >> (fill + 7 * i)) & 0x7F for i in range(count)]


def gsm7_decode(septets):
    out, esc = [], False
    for s in septets:
        if esc:
            out.append(GSM7_EXT.get(s, " "))
            esc = False
        elif s == 0x1B:
            esc = True
        else:
            out.append(GSM7[s])
    return "".join(out)


def _bcd_number(number):
    digits = number.lstrip("+")
    if not digits or not all(c in "0123456789*#" for c in digits) or len(digits) > 20:
        raise ValueError("a phone number is up to 20 digits, optionally with a leading +")
    toa = 0x91 if number.startswith("+") else 0x81
    d = digits + ("F" if len(digits) % 2 else "")
    m = {"*": "A", "#": "B"}
    b = bytes(int(m.get(d[i + 1], d[i + 1]) + m.get(d[i], d[i]), 16) for i in range(0, len(d), 2))
    return len(digits), toa, b


def _bcd_decode(data, ndigits):
    s = ""
    for byte in data:
        for nib in (byte & 0x0F, byte >> 4):
            s += "0123456789*#abc"[nib] if nib < 15 else ""
    return s[:ndigits]


def encode_submit(number, text, ref=0):
    """SMS-SUBMIT TPDUs for `text`: one, or a concatenated series with an
    8-bit reference. Returns a list of TPDUs."""
    ndig, toa, bcd = _bcd_number(number)
    septets = gsm7_septets(text)
    if septets is not None:
        n = 160 if len(septets) <= 160 else 153
        chunks, i = [], 0
        while i < len(septets) or not chunks:
            j = min(i + n, len(septets))
            if j < len(septets) and septets[j - 1] == 0x1B:
                j -= 1                # never split an escape from its character
            chunks.append(septets[i:j])
            i = j
        dcs = 0x00
    else:
        data = text.encode("utf-16-be")
        n = 140 if len(data) <= 140 else 134
        chunks = [data[i:i + n] for i in range(0, len(data), n)]
        # keep surrogate pairs whole
        fixed, carry = [], b""
        for c in chunks:
            c = carry + c
            carry = b""
            if len(c) >= 2 and 0xD8 <= c[-2] <= 0xDB:
                c, carry = c[:-2], c[-2:]
            fixed.append(c)
        if carry:
            fixed.append(carry)
        chunks = fixed
        dcs = 0x08
    if len(chunks) > 8:
        raise ValueError("message too long (more than 8 parts)")
    out = []
    for idx, chunk in enumerate(chunks):
        multi = len(chunks) > 1
        first = 0x01 | 0x10 | (0x40 if multi else 0)   # SUBMIT, relative VP, UDHI
        udh = bytes([5, 0x00, 3, ref & 0xFF, len(chunks), idx + 1]) if multi else b""
        if dcs == 0x00:
            fill = (7 - (len(udh) * 8) % 7) % 7 if udh else 0
            ud = udh + gsm7_pack(chunk, fill)
            udl = (len(udh) * 8 + fill) // 7 + len(chunk) if udh else len(chunk)
        else:
            ud = udh + chunk
            udl = len(ud)
        out.append(bytes([first, 0x00, ndig, toa]) + bcd + bytes([0x00, dcs, 0xA7, udl]) + ud)
    return out


def decode_deliver(pdu):
    """An SMS-DELIVER as received (SMSC + TPDU). Returns a dict with the
    sender, text, timestamp and the concatenation info, or raises ValueError."""
    p = memoryview(pdu)
    i = 1 + p[0]                      # skip the SMSC
    first = p[i]; i += 1
    if first & 0x03 != 0x00:
        raise ValueError("not an SMS-DELIVER (MTI %d)" % (first & 3))
    olen, toa = p[i], p[i + 1]; i += 2
    ob = bytes(p[i:i + (olen + 1) // 2]); i += (olen + 1) // 2
    if toa & 0x70 == 0x50:            # alphanumeric sender, GSM 7-bit
        sender = gsm7_decode(gsm7_unpack(ob, olen * 4 // 7))
    else:
        sender = ("+" if toa & 0x70 == 0x10 else "") + _bcd_decode(ob, olen)
    pid, dcs = p[i], p[i + 1]; i += 2
    ts = bytes(p[i:i + 7]); i += 7
    udl = p[i]; i += 1
    ud = bytes(p[i:])
    alphabet = 0
    if dcs & 0xC0 == 0x00:
        alphabet = (dcs >> 2) & 3
    elif dcs & 0xF0 == 0xF0:
        alphabet = 1 if dcs & 0x04 else 0
    elif dcs & 0xF0 == 0xE0:
        alphabet = 2
    concat = None
    hdr_len = 0
    if first & 0x40 and ud:
        hdr_len = ud[0] + 1
        j = 1
        while j < hdr_len:
            iei, ln = ud[j], ud[j + 1]
            v = ud[j + 2:j + 2 + ln]
            if iei == 0x00 and ln == 3:
                concat = {"ref": v[0], "total": v[1], "seq": v[2]}
            elif iei == 0x08 and ln == 4:
                concat = {"ref": (v[0] << 8) | v[1], "total": v[2], "seq": v[3]}
            j += 2 + ln
    if alphabet == 0:
        fill = (7 - (hdr_len * 8) % 7) % 7 if hdr_len else 0
        skip = (hdr_len * 8 + fill) // 7 if hdr_len else 0
        sept = gsm7_unpack(ud[hdr_len:], udl - skip, fill)
        text = gsm7_decode(sept)
    elif alphabet == 2:
        text = ud[hdr_len:udl].decode("utf-16-be", "replace")
    else:
        text = ud[hdr_len:udl].hex()
    def sd(b):
        return int("%x%x" % (b & 0x0F, b >> 4)) if (b & 0x0F) < 10 and (b >> 4) < 10 else 0
    stamp = "20%02d-%02d-%02dT%02d:%02d:%02d" % tuple(sd(b) for b in ts[:6]) if len(ts) == 7 else ""
    return {"from": sender, "text": text, "sent": stamp, "concat": concat, "pid": pid, "dcs": dcs}
