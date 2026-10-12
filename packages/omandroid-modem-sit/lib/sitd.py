# SPDX-License-Identifier: MIT
"""omandroid-sitd: a small SIT client for the S5300 on /dev/umts_ipc0.

device/cheetah/MODEM-CLIENT.md is the design; MODEM-SIT-RESEARCH.md the
protocol. The daemon:

  - waits for the CP to be ONLINE (IOCTL_GET_CP_STATUS), then runs the
    spec's start-up sequence and turns the radio on;
  - reads the SIM status and the IMSI (kept in memory, never logged or
    exported), and stops at a PIN-locked SIM unless --allow-pin is given and
    a PIN arrives over the control socket;
  - polls voice and data registration, the operator and the signal;
  - sets up a data call with the configured APN and configures rmnetN from
    the response (no DHCP);
  - stores received SMS and sends SMS only on an explicit control request;
  - publishes its state in $RUN/state.json and on a control socket.

Only requests in sit.ALLOWED can be written; sit.request() refuses the rest.
"""
import argparse
import asyncio
import configparser
import errno
import fcntl
import grp
import json
import logging
import os
import pwd
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time

import sit

log = logging.getLogger("sitd")

DEFAULT_CONFIG = "/etc/omandroid/modem-sit.conf"
DEFAULT_RUN = "/run/omandroid-sit"
DEFAULT_STATE = "/var/lib/omandroid-sit"


# ---------------------------------------------------------------- redaction

_LONG_DIGITS = re.compile(r"\+?\d[\d ]{5,}\d")


def redact(text):
    """Mask every run of 7 or more digits: IMSI, IMEI, ICCID and phone numbers
    all are, and nothing the daemon logs on purpose is."""
    return _LONG_DIGITS.sub("<redacted>", text)


class RedactingFormatter(logging.Formatter):
    def format(self, record):
        return redact(super().format(record))


# ------------------------------------------------------------------- config

class Config:
    def __init__(self, path=None):
        cp = configparser.ConfigParser(interpolation=None)
        cp.read_dict({
            "modem": {"device": "/dev/umts_ipc0", "radio": "on", "radio_ready_timeout": "5",
                      "modem_config": "no", "slot_mapping": "no", "ap_time": "no",
                      "request_timeout": "15", "poll_searching": "10", "poll_registered": "60"},
            "data": {"enabled": "no", "apn": "", "user": "", "password": "", "auth": "none",
                     "pdp": "ipv4v6", "roaming": "no", "initial_attach": "yes", "cid": "1",
                     "netdev_prefix": "rmnet", "mtu": "", "metric": "700", "dns": "auto",
                     "retry": "30"},
            "sms": {"store": "yes"},
            "control": {"group": "wheel"},
        })
        if path:
            cp.read(path)
        self.cp = cp
        self.apn_sections = {s[4:]: cp[s] for s in cp.sections() if s.startswith("apn.")}

    def get(self, sec, key):
        return self.cp.get(sec, key)

    def bool(self, sec, key):
        return self.cp.getboolean(sec, key)

    def float(self, sec, key):
        return self.cp.getfloat(sec, key)

    def int(self, sec, key):
        return self.cp.getint(sec, key)

    def apn_for(self, imsi):
        """[apn.<MCCMNC>] sections override [data] for SIMs whose IMSI starts
        with that PLMN; the longest match wins."""
        d = {k: self.get("data", k) for k in ("apn", "user", "password", "auth", "pdp")}
        best = ""
        for plmn in self.apn_sections:
            if imsi and imsi.startswith(plmn) and len(plmn) > len(best):
                best = plmn
        if best:
            for k in d:
                if k in self.apn_sections[best]:
                    d[k] = self.apn_sections[best][k]
        if d["auth"] not in sit.AUTH:
            raise ValueError("auth must be one of %s" % ", ".join(sit.AUTH))
        if d["pdp"] not in sit.PDP:
            raise ValueError("pdp must be one of %s" % ", ".join(sit.PDP))
        return d


# --------------------------------------------------------------- transports

class LinkDown(Exception):
    pass


class CpifTransport:
    """/dev/umts_ipc0: one write() is one SIT message, one read() returns one
    (the kernel adds and strips the link header, MODEM-SIT-RESEARCH 1.2)."""

    def __init__(self, path):
        self.path = path
        self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC)

    def cp_status(self):
        try:
            return fcntl.ioctl(self.fd, sit.IOCTL_GET_CP_STATUS)
        except OSError as e:
            log.warning("IOCTL_GET_CP_STATUS failed: %s", e.strerror)
            return -1

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


class SocketTransport:
    """A SOCK_SEQPACKET Unix socket (tools/sit-sim): same message boundaries
    as the CPIF node. The simulated CP is always ONLINE."""

    def __init__(self, path):
        self.path = path
        s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET | socket.SOCK_CLOEXEC)
        s.connect(path)
        s.setblocking(False)
        self.sock = s
        self.fd = s.fileno()

    def cp_status(self):
        return sit.CP_ONLINE

    def close(self):
        if self.sock is not None:
            self.sock.close()
            self.sock = None
            self.fd = None


def open_transport(spec):
    if spec.startswith("unix:"):
        return SocketTransport(spec[5:])
    return CpifTransport(spec)


# ---------------------------------------------------------------- the link

class Link:
    """Request/response matching by token, indications to a callback."""

    def __init__(self, transport, on_indication, timeout):
        self.t = transport
        self.on_indication = on_indication
        self.timeout = timeout
        self.token = 0
        self.pending = {}
        self.closed = asyncio.get_running_loop().create_future()
        asyncio.get_running_loop().add_reader(self.t.fd, self._readable)

    def _next_token(self):
        tok = self.token
        self.token = (self.token + 1) & 0xFFFFFFFF
        if self.token == 0xFFFFFFFF:
            self.token = 0
        return tok

    def _fail(self, exc):
        if not self.closed.done():
            self.closed.set_exception(exc)
            self.closed.exception()          # mark retrieved
        for f in self.pending.values():
            if not f.done():
                f.set_exception(exc)
        self.pending.clear()

    def _readable(self):
        try:
            data = os.read(self.t.fd, sit.MAX_MSG)
        except BlockingIOError:
            return
        except OSError as e:
            asyncio.get_running_loop().remove_reader(self.t.fd)
            self._fail(LinkDown("read: %s" % e.strerror))
            return
        if not data:
            if isinstance(self.t, SocketTransport):
                asyncio.get_running_loop().remove_reader(self.t.fd)
                self._fail(LinkDown("the simulator closed the link"))
            return
        try:
            m = sit.Message(data)
        except ValueError as e:
            log.warning("dropped a malformed message: %s", e)
            return
        if m.type == sit.TYPE_RESP:
            f = self.pending.pop(m.token, None)
            if f is None or f.done():
                log.info("unmatched response %s token %d", m.name, m.token)
                return
            f.set_result(m)
        elif m.type == sit.TYPE_IND:
            log.debug("<- %s (%d bytes)", m.name, len(m.raw))
            try:
                self.on_indication(m)
            except Exception:
                log.exception("indication %s", m.name)
        else:
            log.info("ignored a request from the modem: %s", m.name)

    async def request(self, msg_id, params=b"", timeout=None):
        tok = self._next_token()
        msg = sit.request(msg_id, tok, params)    # the send guard
        if self.closed.done():
            raise LinkDown("link closed")
        fut = asyncio.get_running_loop().create_future()
        self.pending[tok] = fut
        deadline = time.monotonic() + (timeout or self.timeout)
        while True:
            try:
                os.write(self.t.fd, msg)
                break
            except OSError as e:
                if e.errno == errno.EAGAIN and time.monotonic() < deadline:
                    await asyncio.sleep(0.2)      # INIT_END not done yet
                    continue
                self.pending.pop(tok, None)
                if e.errno == errno.EPERM:
                    raise LinkDown("write refused: the CP is not ONLINE")
                raise LinkDown("write: %s" % e.strerror)
        log.debug("-> %s token %d (%d bytes)", sit.name(msg_id), tok, len(msg))
        try:
            m = await asyncio.wait_for(fut, max(0.1, deadline - time.monotonic()))
        except asyncio.TimeoutError:
            self.pending.pop(tok, None)
            raise TimeoutError("%s: no response" % sit.name(msg_id))
        if m.id != msg_id:
            log.warning("response %s to request %s (token %d)", m.name, sit.name(msg_id), tok)
        return m

    def close(self):
        try:
            asyncio.get_running_loop().remove_reader(self.t.fd)
        except Exception:
            pass
        self._fail(LinkDown("closed"))
        self.t.close()


class RequestFailed(Exception):
    def __init__(self, msg_id, err):
        super().__init__("%s: %s" % (sit.name(msg_id), sit.ERRORS.get(err, "error %d" % err)))
        self.err = err


# ------------------------------------------------------------------ daemon

class Daemon:
    def __init__(self, cfg, args):
        self.cfg = cfg
        self.args = args
        self.run_dir = args.run_dir
        self.state_dir = args.state_dir
        self.link = None
        self.imsi = None          # memory only
        self.sim = None           # parsed GET_SIM_STATUS (AIDs, retries)
        self.call = None          # the active data call
        self.watchers = set()
        self.kick = asyncio.Event()
        self.sim_changed = asyncio.Event()
        self.radio_ready = asyncio.Event()
        self.radio_state_ev = asyncio.Event()
        self.data_retry_at = 0.0
        self.sms_lock = asyncio.Lock()
        self.sms_ref = int(time.time()) & 0xFF
        self.concat = {}
        self.stopping = False
        self.state = {
            "daemon": "starting", "cp": "unknown", "radio": "unknown",
            "sim": {"state": "unknown"},
            "voice": {"reg": "unknown", "rat": "unknown"},
            "data_reg": {"reg": "unknown", "rat": "unknown"},
            "operator": {}, "signal": {},
            "data": {"enabled": self._data_enabled_initial(), "state": "off"},
            "sms": {"received": self._count_inbox()},
        }
        self.publish()

    # ---- state -----------------------------------------------------------

    def _data_enabled_initial(self):
        try:
            with open(os.path.join(self.state_dir, "mobile-data")) as f:
                return f.read().strip() == "on"
        except OSError:
            return self.cfg.bool("data", "enabled")

    def _count_inbox(self):
        try:
            return len([n for n in os.listdir(os.path.join(self.state_dir, "sms")) if n.endswith(".json")])
        except OSError:
            return 0

    def set(self, path, value):
        node = self.state
        keys = path.split(".")
        for k in keys[:-1]:
            node = node.setdefault(k, {})
        if node.get(keys[-1]) != value:
            node[keys[-1]] = value
            self.publish()

    def publish(self):
        self.state["updated"] = int(time.time())
        body = json.dumps(self.state, sort_keys=True)
        tmp = os.path.join(self.run_dir, ".state.json.tmp")
        try:
            with open(tmp, "w") as f:
                f.write(body + "\n")
            os.chmod(tmp, 0o644)
            os.replace(tmp, os.path.join(self.run_dir, "state.json"))
        except OSError as e:
            log.warning("state.json: %s", e.strerror)
        for w in list(self.watchers):
            try:
                w.write((body + "\n").encode())
            except Exception:
                self.watchers.discard(w)

    # ---- indications ------------------------------------------------------

    def on_indication(self, m):
        i = m.id
        if i == sit.IND_RADIO_READY:
            log.info("modem: radio ready")
            self.radio_ready.set()
        elif i == sit.IND_RADIO_STATE_CHANGED:
            v = sit.parse_radio_state(m)
            log.info("modem: radio state %s", sit.RADIO_STATES.get(v, v))
            self.set("radio", "on" if v == 2 else "off" if v in (0, 1) else "unavailable")
            self.radio_state_ev.set()
        elif i == sit.IND_SIM_STATUS_CHANGED:
            log.info("modem: SIM status changed")
            self.sim_changed.set()
            self.kick.set()
        elif i == sit.IND_NTW_STATE_CHANGED:
            self.kick.set()
        elif i == sit.IND_SIGNAL_STRENGTH:
            # Per-RAT layout not decoded yet (spec 3.4, low confidence).
            self.set("signal", {"raw_len": len(m.raw) - sit.IND_HDR, "decoded": False,
                                "source": "indication"})
        elif i == sit.IND_DATA_CALL_LIST_CHANGED:
            log.info("modem: data call list changed")
            asyncio.ensure_future(self.check_data_calls())
        elif i == sit.IND_NEW_SMS:
            asyncio.ensure_future(self.on_new_sms(m))
        elif i in (sit.IND_PHONE_RESET, sit.IND_MODEM_RESTART):
            log.warning("modem: %s", m.name)
            if self.link:
                self.link._fail(LinkDown(m.name))
        else:
            log.info("modem: %s (%d bytes)", m.name, len(m.raw))

    # ---- requests -----------------------------------------------------------

    async def req(self, msg_id, params=b"", ok_errors=()):
        m = await self.link.request(msg_id, params)
        if m.error != sit.E_SUCCESS and m.error not in ok_errors:
            raise RequestFailed(msg_id, m.error)
        return m

    async def try_req(self, msg_id, params=b""):
        """A request whose failure is logged, not fatal."""
        try:
            return await self.req(msg_id, params)
        except (RequestFailed, TimeoutError) as e:
            log.warning("%s", e)
            return None

    # ---- the session --------------------------------------------------------

    async def wait_online(self, t):
        last = None
        while not self.stopping:
            st = t.cp_status()
            name = sit.CP_STATES.get(st, "state %d" % st)
            if st != last:
                log.info("CP: %s", name)
                self.set("cp", name)
                last = st
            if st == sit.CP_ONLINE:
                return
            await asyncio.sleep(1)

    async def run(self):
        dev = self.args.device or self.cfg.get("modem", "device")
        while not self.stopping:
            try:
                t = open_transport(dev)
            except OSError as e:
                self.set("daemon", "waiting")
                self.set("cp", "absent")
                log.info("%s: %s; retrying", dev, e.strerror)
                await asyncio.sleep(5)
                continue
            try:
                await self.wait_online(t)
                for ev in (self.radio_ready, self.radio_state_ev, self.sim_changed):
                    ev.clear()
                self.link = Link(t, self.on_indication, self.cfg.float("modem", "request_timeout"))
                self.set("daemon", "running")
                session = asyncio.ensure_future(self.session(t))
                done, _ = await asyncio.wait({session, self.link.closed},
                                             return_when=asyncio.FIRST_COMPLETED)
                if session in done:
                    session.result()
                else:
                    session.cancel()
                    try:
                        await session
                    except (asyncio.CancelledError, Exception):
                        pass
                    self.link.closed.result()
            except asyncio.CancelledError:
                raise
            except (LinkDown, TimeoutError, RequestFailed) as e:
                log.warning("session ended: %s", e)
            except Exception:
                log.exception("session failed")
            finally:
                if self.stopping and self.call and self.link:
                    try:     # leave no PDN up at the modem behind a dead netdev
                        await asyncio.wait_for(self.deactivate(), 3)
                    except (Exception, asyncio.CancelledError):
                        pass
                await self.drop_data("link down")
                if self.link:
                    self.link.close()
                    self.link = None
                else:
                    t.close()
                self.imsi = None
                self.set("radio", "unknown")
                self.set("cp", "unknown")
            if not self.stopping:
                self.set("daemon", "waiting")
                await asyncio.sleep(2)

    async def session(self, t):
        cfg = self.cfg
        # 3. IND_RADIO_READY, or go on after a few seconds
        try:
            await asyncio.wait_for(self.radio_ready.wait(), cfg.float("modem", "radio_ready_timeout"))
        except asyncio.TimeoutError:
            log.info("no IND_RADIO_READY yet; going on")
        # 4. the start-up requests stock sends, each opt-in (spec: try without first)
        if cfg.bool("modem", "modem_config"):
            await self.try_req(sit.SET_MODEM_CONFIG, sit.build_modem_config(1))
        if cfg.bool("modem", "slot_mapping"):
            await self.try_req(sit.SET_LOGICAL_TO_PHYSICAL_SLOT_MAPPING, sit.build_slot_mapping((0,)))
        if cfg.bool("modem", "ap_time"):
            await self.try_req(sit.SET_AP_SYSTEM_TIME, sit.build_ap_time(time.localtime()))
        # 5. radio power
        m = await self.try_req(sit.GET_RADIO_POWER)
        if m is not None and len(m.raw) >= 16:
            v = m.u32(0x0C)
            self.set("radio", "on" if v == 2 else "off" if v in (0, 1) else "unavailable")
        if cfg.get("modem", "radio") == "on" and not self.args.radio_off:
            await self.set_radio(True)
        # 6. the SIM, held at a PIN until a verified PIN or a status change
        while not await self.refresh_sim():
            self.sim_changed.clear()
            try:
                await asyncio.wait_for(self.sim_changed.wait(), 30)
            except asyncio.TimeoutError:
                pass
        # 7. IMSI, for the APN choice only
        await self.read_imsi()
        # 8-9. attach APN, automatic selection, data allowed
        apn = cfg.apn_for(self.imsi)
        if apn["apn"] and cfg.bool("data", "initial_attach"):
            await self.try_req(sit.SET_INITIAL_ATTACH_APN,
                               sit.build_initial_attach_apn(apn["apn"], apn["user"], apn["password"],
                                                            apn["auth"], apn["pdp"]))
        await self.try_req(sit.SET_NTW_MODE_AUTO)
        await self.try_req(sit.SET_PS_SERVICE, sit.build_ps_service(self.state["data"]["enabled"]))
        # 10-11. registration and data
        while True:
            await self.poll_registration()
            await self.manage_data()
            reg = self.state["data_reg"]["reg"] in ("home", "roaming")
            interval = cfg.float("modem", "poll_registered" if reg else "poll_searching")
            if self.state["data"]["enabled"] and self.call is None and self.data_retry_at:
                interval = min(interval, max(0.1, self.data_retry_at - time.monotonic()))
            self.kick.clear()
            try:
                await asyncio.wait_for(self.kick.wait(), interval)
            except asyncio.TimeoutError:
                pass
            if t.cp_status() != sit.CP_ONLINE:
                raise LinkDown("CP left ONLINE")

    async def set_radio(self, on):
        self.radio_state_ev.clear()
        await self.req(sit.SET_RADIO_POWER, sit.build_radio_power(on))
        log.info("radio power %s requested", "on" if on else "off")
        try:
            await asyncio.wait_for(self.radio_state_ev.wait(), 15)
        except asyncio.TimeoutError:
            log.warning("no IND_RADIO_STATE_CHANGED after SET_RADIO_POWER")
        if not on:
            await self.drop_data("radio off")

    # ---- SIM ---------------------------------------------------------------

    def _sim_app(self):
        apps = (self.sim or {}).get("apps") or []
        for a in apps:                      # prefer a USIM (RIL AppType 2, medium)
            if a["type"] == 2:
                return a
        return apps[0] if apps else None

    async def refresh_sim(self):
        """Read the SIM status. True when the SIM is usable."""
        m = await self.req(sit.GET_SIM_STATUS, ok_errors=(11,))
        self.sim = sit.parse_sim_status(m) if m.error == sit.E_SUCCESS else {"card_state": 0, "apps": []}
        app = self._sim_app()
        out = {"card_state": self.sim["card_state"], "apps": len(self.sim["apps"])}
        if m.error == 11 or self.sim["card_state"] == 0 or app is None:
            out["state"] = "absent"
        else:
            out.update(pin1=sit.PIN_STATES.get(app["pin1"], app["pin1"]),
                       pin1_retries=app["pin1_retries"], puk1_retries=app["puk1_retries"])
            if app["pin1"] in (sit.PIN_BLOCKED, sit.PIN_PERM_BLOCKED) or app["state"] == 3:
                out["state"] = "puk-required"
            elif app["pin1"] == sit.PIN_NOT_VERIFIED or app["state"] == 2:
                out["state"] = "pin-required"
            elif app["state"] == 5:
                out["state"] = "ready"
            else:
                out["state"] = "not-ready"
        out["imsi_read"] = self.imsi is not None
        self.set("sim", out)
        log.info("SIM: %s (card state %d, %d application(s)%s)", out["state"], out["card_state"],
                 out["apps"], ", PIN1 retries %s" % out["pin1_retries"] if "pin1_retries" in out else "")
        if out["state"] == "pin-required":
            log.warning("SIM PIN required: stopping here. %s", "send it with 'omandroid-sit pin'"
                        if self.args.allow_pin else "start with --allow-pin to accept one")
        return out["state"] == "ready"

    async def read_imsi(self):
        app = self._sim_app()
        m = await self.try_req(sit.GET_IMSI, sit.build_aid(app["aid"] if app else b""))
        if m is not None:
            imsi = sit.parse_imsi(m)
            self.imsi = imsi if imsi.isdigit() else None
        log.info("IMSI %s", "read (not logged)" if self.imsi else "not available")
        self.set("sim.imsi_read", self.imsi is not None)

    async def verify_pin(self, pin):
        """VERIFY_SIM_PIN, only with --allow-pin, only for a SIM that asks
        for it, and never with the last try left."""
        if not self.args.allow_pin:
            raise PermissionError("PIN entry is off: start omandroid-sitd with --allow-pin")
        if self.link is None:
            raise RuntimeError("no modem")
        await self.refresh_sim()        # a fresh retry counter
        app = self._sim_app()
        if self.state["sim"]["state"] != "pin-required" or app is None:
            raise RuntimeError("the SIM is not asking for a PIN (%s)" % self.state["sim"]["state"])
        if app["pin1_retries"] < 2:
            raise PermissionError("%d PIN tries left: refusing to spend the last one" % app["pin1_retries"])
        m = await self.link.request(sit.VERIFY_SIM_PIN, sit.build_verify_pin(pin, app["aid"]))
        log.info("VERIFY_SIM_PIN: %s", sit.ERRORS.get(m.error, m.error))
        self.sim_changed.set()
        if m.error != sit.E_SUCCESS:
            await self.refresh_sim()
            raise RuntimeError("PIN rejected (%s); %s tries left" % (
                sit.ERRORS.get(m.error, m.error), self.state["sim"].get("pin1_retries")))
        return True

    # ---- registration --------------------------------------------------------

    async def poll_registration(self):
        m = await self.try_req(sit.GET_CS_REG_STATE)
        if m is not None:
            r = sit.parse_cs_reg(m)
            self.set("voice", {"reg": sit.REG_STATES.get(r["reg"], "unknown"),
                               "rat": sit.RATS.get(r["rat"], str(r["rat"]))})
        m = await self.try_req(sit.GET_PS_REG_STATE)
        if m is not None:
            r = sit.parse_ps_reg(m)
            new = {"reg": sit.REG_STATES.get(r["reg"], "unknown"),
                   "rat": sit.RATS.get(r["rat"], str(r["rat"]))}
            if r["reg"] == 3:
                new["reject_cause"] = r["reject"]
            if new != self.state["data_reg"]:
                log.info("data registration: %s, %s", new["reg"], new["rat"])
            self.set("data_reg", new)
        if self.state["voice"]["reg"] in ("home", "roaming") or self.state["data_reg"]["reg"] in ("home", "roaming"):
            m = await self.try_req(sit.GET_OPERATOR)
            if m is not None:
                op = sit.parse_operator(m)
                if op != self.state["operator"]:
                    log.info("operator: %s (%s)", op["long"] or op["short"] or "?", op["plmn"])
                self.set("operator", op)
        else:
            self.set("operator", {})
        m = await self.try_req(sit.GET_SIGNAL_STRENGTH)
        if m is not None:
            self.set("signal", {"raw_len": len(m.raw) - sit.REQ_HDR, "decoded": False, "source": "poll"})

    # ---- data ------------------------------------------------------------------

    def _data_allowed(self):
        reg = self.state["data_reg"]["reg"]
        return reg == "home" or (reg == "roaming" and self.cfg.bool("data", "roaming"))

    async def manage_data(self):
        d = self.state["data"]
        if not d["enabled"]:
            if self.call:
                await self.deactivate()
            return
        if self.call or not self._data_allowed() or self.state["sim"]["state"] != "ready":
            if not self.call and d["state"] not in ("failed", "unsupported"):
                self.set("data.state", "waiting")
            return
        if d["state"] == "unsupported" or time.monotonic() < self.data_retry_at:
            return
        apn = self.cfg.apn_for(self.imsi)
        if not apn["apn"]:
            self.set("data", dict(d, state="failed", error="no APN configured"))
            return
        cid = self.cfg.int("data", "cid")
        self.set("data.state", "connecting")
        log.info("data call: setting up CID %d", cid)
        try:
            m = await self.req(sit.SETUP_DATA_CALL, sit.build_setup_data_call(
                cid, apn["apn"], apn["user"], apn["password"], apn["auth"], apn["pdp"]))
            call = sit.parse_data_call(m)
        except sit.Unsupported as e:
            log.warning("data call: %s; see MODEM-CLIENT.md (v11 data call)", e)
            self._dump_unknown(m)
            self.set("data", dict(self.state["data"], state="unsupported", error=str(e)))
            return
        except (RequestFailed, TimeoutError) as e:
            self._data_failed(str(e))
            return
        if call["status"] != 0 or not call["active"] or not (call["ipv4"] or call["ipv6"]):
            self._data_failed("data call refused (cause %d, active %d)" % (call["status"], call["active"]))
            return
        call["cid"] = call["cid"] or cid
        call["iface"] = "%s%d" % (self.cfg.get("data", "netdev_prefix"), call["cid"] - 1)
        try:
            self.netconf_up(call)
        except Exception as e:
            log.warning("configuring %s: %s", call["iface"], e)
            self.call = call
            await self.deactivate()
            self._data_failed("netdev: %s" % e)
            return
        self.call = call
        self.data_retry_at = 0
        log.info("data call: CID %d up on %s", call["cid"], call["iface"])
        self.set("data", {"enabled": True, "state": "connected", "iface": call["iface"],
                          "ipv4": call["ipv4"], "ipv6": call["ipv6"], "dns": call["dns"]})

    def _data_failed(self, why):
        retry = self.cfg.float("data", "retry")
        log.warning("data call failed: %s; retrying in %d s", why, retry)
        self.data_retry_at = time.monotonic() + retry
        self.set("data", dict(self.state["data"], state="failed", error=why))

    def _dump_unknown(self, m):
        """With OMANDROID_SIT_DUMP=1, keep an undecoded payload in $RUN (mode
        0600) for offline reading. It holds addresses: never commit it."""
        if os.environ.get("OMANDROID_SIT_DUMP") != "1":
            return
        p = os.path.join(self.run_dir, "unknown-%04x-%d.bin" % (m.id, int(time.time())))
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(m.raw)

    async def deactivate(self):
        call = self.call
        if not call:
            return
        await self.try_req(sit.DEACT_DATA_CALL, sit.build_deact_data_call(call["cid"]))
        await self.drop_data("deactivated")

    async def drop_data(self, why):
        if self.call:
            try:
                self.netconf_down(self.call)
            except Exception as e:
                log.warning("deconfiguring %s: %s", self.call["iface"], e)
            log.info("data call: CID %d down (%s)", self.call["cid"], why)
            self.call = None
        enabled = self.state["data"]["enabled"]
        self.set("data", {"enabled": enabled, "state": "waiting" if enabled else "off"})

    async def check_data_calls(self):
        """IND_DATA_CALL_LIST_CHANGED: the network may have dropped our call.
        The list layout is the same item as the setup response (medium), so
        only a short-form, single-call list is trusted; anything else
        re-establishes the call to be safe."""
        if not self.call or not self.link:
            return
        m = await self.try_req(sit.GET_DATA_CALL_LIST)
        alive = False
        if m is not None:
            try:
                c = sit.parse_data_call(m)
                alive = c["cid"] == self.call["cid"] and c["active"] and c["status"] == 0
            except sit.Unsupported:
                alive = True     # can't tell: keep it, the next poll retries on failure
        if not alive:
            await self.drop_data("dropped by the network")
            self.kick.set()

    async def set_data_enabled(self, on):
        self.set("data.enabled", bool(on))
        try:
            os.makedirs(self.state_dir, exist_ok=True)
            with open(os.path.join(self.state_dir, "mobile-data"), "w") as f:
                f.write("on\n" if on else "off\n")
        except OSError as e:
            log.warning("saving the mobile data switch: %s", e.strerror)
        if self.link:
            await self.try_req(sit.SET_PS_SERVICE, sit.build_ps_service(on))
        if not on:
            if self.call:
                await self.deactivate()
            self.set("data.state", "off")
        else:
            self.data_retry_at = 0
            if self.state["data"]["state"] in ("off", "failed"):
                self.set("data", {"enabled": True, "state": "waiting"})
        self.kick.set()

    # ---- netdev ----------------------------------------------------------------

    def _ip(self, *a):
        ip = shutil.which("ip")
        if not ip:
            raise RuntimeError("no ip(8) (iproute2)")
        r = subprocess.run([ip, *a], capture_output=True, text=True, timeout=10)
        if r.returncode:
            raise RuntimeError("ip %s: %s" % (" ".join(a[:3]), r.stderr.strip()))

    def netconf_up(self, call):
        """Static configuration from the response: rmnet is raw IP with no
        link layer (spec 3.5), so the address is /32 (IPv6 /64), and the
        default routes point at the device with a metric above Wi-Fi's."""
        dev, metric = call["iface"], self.cfg.get("data", "metric")
        self._ip("addr", "flush", "dev", dev)
        mtu = self.cfg.get("data", "mtu")
        if mtu:
            self._ip("link", "set", "dev", dev, "mtu", mtu)
        self._ip("link", "set", "dev", dev, "up")
        if call["ipv4"]:
            self._ip("addr", "add", call["ipv4"] + "/32", "dev", dev)
            self._ip("route", "replace", "default", "dev", dev, "metric", metric)
        if call["ipv6"]:
            self._ip("-6", "addr", "add", call["ipv6"] + "/64", "dev", dev, "nodad")
            self._ip("-6", "route", "replace", "default", "dev", dev, "metric", metric)
        self.dns_up(dev, call["dns"])

    def netconf_down(self, call):
        dev = call["iface"]
        self.dns_down(dev)
        self._ip("addr", "flush", "dev", dev)
        self._ip("link", "set", "dev", dev, "down")

    def _dns_mode(self):
        mode = self.cfg.get("data", "dns")
        if mode == "auto":
            mode = "resolvectl" if shutil.which("resolvectl") else "file"
        return mode

    def dns_up(self, dev, servers):
        mode = self._dns_mode()
        if not servers or mode == "none":
            return
        if mode == "resolvectl":
            subprocess.run(["resolvectl", "dns", dev, *servers], check=True, timeout=10,
                           capture_output=True)
            subprocess.run(["resolvectl", "domain", dev, "~."], check=True, timeout=10,
                           capture_output=True)
        else:
            with open(os.path.join(self.run_dir, "resolv.conf"), "w") as f:
                f.writelines("nameserver %s\n" % s for s in servers)

    def dns_down(self, dev):
        mode = self._dns_mode()
        if mode == "resolvectl":
            subprocess.run(["resolvectl", "revert", dev], timeout=10, capture_output=True)
        elif mode == "file":
            try:
                os.unlink(os.path.join(self.run_dir, "resolv.conf"))
            except OSError:
                pass

    # ---- SMS ---------------------------------------------------------------------

    async def on_new_sms(self, m):
        _fmt, pdu = sit.parse_new_sms(m)
        ok = True
        try:
            msg = sit.decode_deliver(pdu)
        except (ValueError, IndexError) as e:
            log.warning("SMS: undecodable PDU (%d bytes): %s", len(pdu), e)
            msg, ok = None, True       # still ack: the PDU arrived, a retry won't decode better
        if self.link:
            await self.try_req(sit.SEND_SMS_ACK, sit.build_sms_ack(ok))
        if msg is None:
            return
        log.info("SMS received (%d characters%s)", len(msg["text"]),
                 ", part %d of %d" % (msg["concat"]["seq"], msg["concat"]["total"]) if msg["concat"] else "")
        self.store_sms(msg)

    def store_sms(self, msg):
        c = msg.pop("concat")
        if c and c["total"] > 1:
            key = (msg["from"], c["ref"], c["total"])
            parts = self.concat.setdefault(key, {})
            parts[c["seq"]] = msg["text"]
            if len(parts) < c["total"]:
                return
            del self.concat[key]
            msg["text"] = "".join(parts[i] for i in sorted(parts))
        msg["received"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        if self.cfg.bool("sms", "store"):
            d = os.path.join(self.state_dir, "sms")
            os.makedirs(d, mode=0o700, exist_ok=True)
            name = "%d-%06d.json" % (time.time(), os.getpid() % 1000000 + len(os.listdir(d)))
            fd = os.open(os.path.join(d, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(msg, f)
        self.set("sms.received", self.state["sms"]["received"] + 1)

    def list_sms(self):
        d = os.path.join(self.state_dir, "sms")
        out = []
        try:
            names = sorted(n for n in os.listdir(d) if n.endswith(".json"))
        except OSError:
            return out
        for n in names:
            try:
                with open(os.path.join(d, n)) as f:
                    out.append(dict(json.load(f), id=n[:-5]))
            except (OSError, ValueError):
                pass
        return out

    async def send_sms(self, to, text):
        if self.link is None:
            raise RuntimeError("no modem")
        if self.state["voice"]["reg"] not in ("home", "roaming") and \
                self.state["data_reg"]["reg"] not in ("home", "roaming"):
            raise RuntimeError("not registered")
        async with self.sms_lock:
            self.sms_ref = (self.sms_ref + 1) & 0xFF
            tpdus = sit.encode_submit(to, text, self.sms_ref)
            refs = []
            for n, tpdu in enumerate(tpdus):
                mid = sit.SEND_SMS if n == len(tpdus) - 1 else sit.SEND_SMS_EXPECT_MORE
                m = await self.req(mid, sit.build_send_sms(tpdu))
                refs.append(sit.parse_send_sms(m)["ref"])
            log.info("SMS sent (%d part(s))", len(tpdus))
            return refs

    # ---- control socket ------------------------------------------------------------

    def _privileged(self, writer):
        s = writer.get_extra_info("socket")
        try:
            _pid, uid, _gid = struct.unpack("3i", s.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                                               struct.calcsize("3i")))
        except OSError:
            return False
        if uid in (0, os.getuid()):
            return True
        try:
            user = pwd.getpwuid(uid).pw_name
            g = grp.getgrnam(self.cfg.get("control", "group"))
            return user in g.gr_mem or pwd.getpwuid(uid).pw_gid == g.gr_gid
        except KeyError:
            return False

    async def handle_client(self, reader, writer):
        priv = self._privileged(writer)
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                try:
                    req = json.loads(line)
                    reply = await self.command(req, priv, writer)
                except Exception as e:
                    reply = {"ok": False, "error": redact(str(e))}
                if reply is None:            # watch: the connection streams state
                    return
                writer.write((json.dumps(reply) + "\n").encode())
                await writer.drain()
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            if writer not in self.watchers:
                writer.close()

    async def command(self, req, priv, writer):
        cmd = req.get("cmd")
        if cmd == "status":
            return {"ok": True, "state": self.state}
        if cmd == "watch":
            self.watchers.add(writer)
            writer.write((json.dumps(self.state, sort_keys=True) + "\n").encode())
            return None
        if not priv:
            raise PermissionError("%s needs root or the %s group" % (cmd, self.cfg.get("control", "group")))
        if cmd == "data":
            await self.set_data_enabled(bool(req.get("enable")))
            return {"ok": True, "data": self.state["data"]}
        if cmd == "radio":
            if self.link is None:
                raise RuntimeError("no modem")
            await self.set_radio(bool(req.get("on")))
            self.kick.set()
            return {"ok": True, "radio": self.state["radio"]}
        if cmd == "sms-send":
            refs = await self.send_sms(str(req["to"]), str(req["text"]))
            return {"ok": True, "parts": len(refs)}
        if cmd == "sms-list":
            return {"ok": True, "messages": self.list_sms()}
        if cmd == "sms-delete":
            n = os.path.basename(str(req["id"]))
            os.unlink(os.path.join(self.state_dir, "sms", n + ".json"))
            self.set("sms.received", self._count_inbox())
            return {"ok": True}
        if cmd == "pin":
            await self.verify_pin(str(req["pin"]))
            return {"ok": True}
        raise ValueError("unknown command %r" % cmd)


async def amain(args):
    cfg = Config(args.config if os.path.exists(args.config) else None)
    os.makedirs(args.run_dir, exist_ok=True)
    os.makedirs(args.state_dir, mode=0o700, exist_ok=True)
    d = Daemon(cfg, args)
    sock_path = os.path.join(args.run_dir, "control")
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass
    server = await asyncio.start_unix_server(d.handle_client, path=sock_path)
    os.chmod(sock_path, 0o666)     # commands past status/watch check the peer's credentials
    loop = asyncio.get_running_loop()
    main = asyncio.ensure_future(d.run())

    def stop():
        d.stopping = True
        main.cancel()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop)
    try:
        await main
    except asyncio.CancelledError:
        pass
    finally:
        log.info("stopping")
        await d.drop_data("stopping")
        if d.link:
            d.link.close()
        server.close()
        d.set("daemon", "stopped")


def main(argv=None):
    p = argparse.ArgumentParser(prog="omandroid-sitd", description=__doc__.split("\n")[0])
    p.add_argument("--config", default=os.environ.get("OMANDROID_SIT_CONFIG", DEFAULT_CONFIG))
    p.add_argument("--device", help="the SIT channel (default from the config: /dev/umts_ipc0); "
                   "unix:PATH for tools/sit-sim")
    p.add_argument("--run-dir", default=os.environ.get("OMANDROID_SIT_RUN", DEFAULT_RUN))
    p.add_argument("--state-dir", default=os.environ.get("OMANDROID_SIT_STATE", DEFAULT_STATE))
    p.add_argument("--allow-pin", action="store_true",
                   help="accept a SIM PIN over the control socket (never with the last try left)")
    p.add_argument("--radio-off", action="store_true", help="leave the radio off (first runs)")
    p.add_argument("-v", "--verbose", action="store_true", help="log every message ID")
    args = p.parse_args(argv)
    h = logging.StreamHandler(sys.stderr)
    h.setFormatter(RedactingFormatter("%(message)s"))
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, handlers=[h])
    asyncio.run(amain(args))


if __name__ == "__main__":
    main()
