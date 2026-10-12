<!-- SPDX-License-Identifier: MIT -->
# Modem client: omandroid-sitd, its integration, and the M4 runbook

Status (2026-10-12): **built and tested offline against a simulator; nothing
run on the phone.** `packages/omandroid-modem-sit` 0.1.0 holds
`omandroid-sitd` (the SIT client daemon) and `omandroid-sit` (its CLI);
`tools/sit-sim` is a scripted modem that speaks the same framing. The
protocol is [MODEM-SIT-RESEARCH.md](MODEM-SIT-RESEARCH.md); the modem has to
reach ONLINE first ([MODEM-PLAN.md](MODEM-PLAN.md) M3.4), so the M4 runbook
below waits on that.

---

## 1. What is built

| Path | What |
|---|---|
| `packages/omandroid-modem-sit/lib/sit.py` | The codec: headers, the send guard, request builders and response/indication parsers for the messages in MODEM-SIT-RESEARCH section 3, SMS PDUs (GSM 7-bit, UCS-2, concatenation) |
| `lib/sit_names.py` | All 602 message names, generated from the research appendix |
| `lib/sitd.py`, `bin/omandroid-sitd` | The daemon (Python 3, standard library only, asyncio) |
| `bin/omandroid-sit` | CLI: `status [--json]`, `watch`, `data on\|off`, `radio on\|off`, `sms send\|list\|delete`, `pin` |
| `etc/omandroid/modem-sit.conf` | APN, data switch default, roaming, poll intervals, the opt-in start-up requests |
| `systemd/omandroid-sitd.service` | Root, `CAP_NET_ADMIN` only, `DeviceAllow=/dev/umts_ipc0`. Installed, **not enabled** |
| `test/all` | Unit tests, then the daemon against `tools/sit-sim` (skipped from a copy of the package alone, as on the phone) |
| `tools/sit-sim` | The simulator |

Test it: `packages/omandroid-modem-sit/test/all` (about 15 s). `KEEP=1`
with `python3 -m unittest test/test_sim.py` keeps each run's directory
(daemon log, simulator transcript, the fake `ip`/`resolvectl` logs).

### 1.1 What the daemon does

The 11 steps of MODEM-SIT-RESEARCH section 5:

1. Opens `/dev/umts_ipc0`, polls `IOCTL_GET_CP_STATUS` once a second until
   ONLINE (4), retries a write on `EAGAIN` (INIT_END not done), and treats
   `EPERM`, a read error, IND_PHONE_RESET/IND_MODEM_RESTART or the CP
   leaving ONLINE as the end of a session: the data call's netdev is
   deconfigured, and it starts over at step 1.
2. One `read()` per message; responses resolve a pending request by token,
   indications go to a handler. `-v` logs every message by name.
3. Waits up to `radio_ready_timeout` for IND_RADIO_READY.
4. SET_MODEM_CONFIG, the slot mapping and SET_AP_SYSTEM_TIME are each **off
   by default** (`modem_config`, `slot_mapping`, `ap_time`): the spec says
   to try without them, and the runbook turns them on one per run only if
   the modem refuses radio power.
5. GET_RADIO_POWER, then SET_RADIO_POWER on (unless `--radio-off` or
   `radio = off`), and waits for IND_RADIO_STATE_CHANGED.
6. GET_SIM_STATUS. A SIM asking for its PIN stops the start-up there (see
   1.2).
7. GET_IMSI with the USIM's AID. The IMSI stays in memory, only to pick a
   per-PLMN APN section; it's never logged, written or exported.
8. SET_INITIAL_ATTACH_APN with the configured APN (if any).
9. SET_NTW_MODE_AUTO, then SET_PS_SERVICE with the mobile data switch.
10. Polls GET_CS_REG_STATE, GET_PS_REG_STATE, GET_OPERATOR (once registered)
    and GET_SIGNAL_STRENGTH every `poll_searching` seconds (10) until
    registered, then every `poll_registered` (60), and at once on every
    IND_NTW_STATE_CHANGED or IND_SIM_STATUS_CHANGED.
11. With mobile data on and the data registration home (or roaming with
    `roaming = yes`): SETUP_DATA_CALL with CID 1 and the APN. From the
    short-form response it configures `rmnet<CID-1>` statically: the IPv4
    address as /32, the IPv6 address as /64 (`nodad`), default routes on the
    device at metric 700 (Wi-Fi wins while it's up), and DNS through
    `resolvectl` (or `/run/omandroid-sit/resolv.conf` without
    systemd-resolved). IND_DATA_CALL_LIST_CHANGED re-reads the call list and
    drops a call the network ended. Failures retry every `retry` seconds.

SMS: IND_NEW_SMS is decoded, acked with SEND_SMS_ACK, reassembled if
concatenated, and stored as JSON in `/var/lib/omandroid-sit/sms` (mode 0600).
SEND_SMS goes out only on a control request (`omandroid-sit sms send`), with
no SMSC (the SIM's), GSM 7-bit or UCS-2, up to 8 parts. Sending needs a
registration.

### 1.2 Safety

- **Allow-list, then deny-list.** `sit.request()` builds every outgoing
  message and refuses any ID outside `sit.ALLOWED` (22 requests), and any
  ID on the spec's do-not-send list or in the VSIM (0x0e) and satellite
  (0x13) families, so a later edit to the allow-list can't let one
  through. GET_IMEI and GET_IMEISV aren't allowed: the daemon has no use for
  them. The tests check the two lists are disjoint, every denied ID is
  refused, and the simulator flags any denied, unknown or wrongly-sized
  request it receives.
- **No raw-send interface.** The control socket offers fixed commands only.
- **PIN.** A PIN-locked SIM stops the start-up at step 6. `pin` is refused
  unless the daemon runs with `--allow-pin`; with it, the daemon re-reads
  GET_SIM_STATUS for a fresh retry counter and **refuses when fewer than 2
  tries are left**, so Linux never spends the last one. PUK entry isn't
  implemented. Taking the PIN lock off in another phone is the better path.
- **Redaction.** Every log line goes through a filter that masks any run of
  seven or more digits (IMSI, IMEI, ICCID, phone numbers). Nothing logs on
  purpose: the IMSI is "read (not logged)", SMS are "received (14
  characters)", and the PIN is never logged. The tests fail if the
  simulator's IMSI, sender, message text or PIN appear in the daemon's log.
  `state.json` holds no identifiers (the operator's public PLMN and name,
  and the data call's addresses, are not ones).
- **Data off by default, roaming off by default.** `enabled = no` in the
  config; the switch persists in `/var/lib/omandroid-sit/mobile-data`.
- **Undecoded payloads** (the v11 data call) are written only with
  `OMANDROID_SIT_DUMP=1`, to `/run/omandroid-sit/unknown-*.bin` (0600).
  They hold addresses: read them offline, never commit them.
- **The NV rule holds.** The daemon talks only SIT on `umts_ipc0`; NV is
  rfsd's RAM copy (the modem profile).

### 1.3 Known gaps (read from the spec's open questions)

| Gap | Effect | Next step |
|---|---|---|
| The v11 data call item (open question 3) | A response of 0x90 bytes or more is reported as `data.state = "unsupported"` instead of being guessed at | Capture one with `OMANDROID_SIT_DUMP=1` on the phone, or read `DataCallUtil::FillDataCallListFromModemPayload`; then a `parse_data_call_v11()` |
| Signal strength layout (3.4, low) | `signal` reports only `raw_len` and `decoded: false` | Read `SignalStrengthAdapter::Fill{Lte,Nr}*` |
| SIM card/app state values (open question 2) | `ready` is app state 5, PIN states as Android's RIL; medium confidence | Confirm on the first GET_SIM_STATUS (M4.2) |
| SIM_IO (ICCID, SPN) not decoded | No ICCID read at all (and none wanted for now) | Only if a front end needs the SPN |
| Prefix lengths, MTU | IPv4 /32, IPv6 /64 with the kernel's RA handling; MTU only from the config | The v11 item carries MTU; RA behaviour seen in M4.5 |
| SIM slot 1 / eSIM (`umts_ipc1`) | Not handled | Later |
| Voice calls | None (AoC voice path, MODEM-PLAN M5) | M5 |

---

## 2. The state and control interface

`omandroid-sitd` publishes in two places:

- **`/run/omandroid-sit/state.json`** (0644), rewritten atomically on every
  change. Readers that only poll (the shell) use this or `omandroid-sit
  status --json`, which falls back to it when the daemon doesn't answer.
- **`/run/omandroid-sit/control`**, a stream Unix socket, one JSON object
  per line in each direction. `status` and `watch` are open to everyone;
  every other command needs root or membership in the `[control] group`
  (`wheel`), checked with `SO_PEERCRED`.

| Request | Reply |
|---|---|
| `{"cmd": "status"}` | `{"ok": true, "state": {...}}` |
| `{"cmd": "watch"}` | the state now, then one line per change, until the client closes |
| `{"cmd": "data", "enable": true}` | `{"ok": true, "data": {...}}` |
| `{"cmd": "radio", "on": false}` | `{"ok": true, "radio": "off"}` |
| `{"cmd": "sms-send", "to": "+…", "text": "…"}` | `{"ok": true, "parts": 1}` |
| `{"cmd": "sms-list"}` / `{"cmd": "sms-delete", "id": "…"}` | messages / ok |
| `{"cmd": "pin", "pin": "…"}` | ok, or the reason it was refused |

Errors are `{"ok": false, "error": "…"}`. The state:

```jsonc
{
  "daemon": "running",            // starting | waiting | running | stopped
  "cp": "online",                 // CP state from IOCTL_GET_CP_STATUS, or absent/unknown
  "radio": "on",                  // on | off | unavailable | unknown
  "sim": {"state": "ready", "pin1": "disabled", "pin1_retries": 3, "puk1_retries": 10,
          "card_state": 1, "apps": 1, "imsi_read": true},
                                  // state: unknown | absent | pin-required | puk-required | not-ready | ready
  "voice":    {"reg": "home", "rat": "LTE"},
  "data_reg": {"reg": "home", "rat": "LTE"},   // reg: not-registered | home | searching | denied | unknown | roaming
  "operator": {"plmn": "00101", "short": "Test", "long": "Test Network"},
  "signal":   {"raw_len": 40, "decoded": false, "source": "poll"},
  "data": {"enabled": true, "state": "connected", "iface": "rmnet0",
           "ipv4": "192.0.2.2", "ipv6": "2001:db8::2", "dns": ["192.0.2.53"]},
                                  // state: off | waiting | connecting | connected | failed | unsupported (+ "error")
  "sms": {"received": 1},
  "updated": 1791849281
}
```

### 2.1 The quick-settings "Mobile data" tile

`packages/omandroid-shell`'s `QuickSettings.qml` has a `mobileData` stub
(`available`, `enabled`, `status`, `toggle()`); this note doesn't change the
shell. Wiring it later, in the style of the Location tile (which runs
`omandroid-gnss status --json`):

- **Read:** a `Process` running `omandroid-sit status --json` on the
  sheet's refresh (or a long-lived `omandroid-sit watch`, one JSON line per
  change, for live updates). Exit status 1 with `{"daemon": "absent"}` means
  no modem client.
- **Map:**
  - `available` = `daemon == "running"` and `radio == "on"` and
    `sim.state == "ready"`;
  - `enabled` = `data.enabled`;
  - `status` = `"No modem"` without the daemon; `"SIM locked"` for
    `pin-required`/`puk-required`; `"No SIM"` for `absent`; `"Off"` when
    data is off; `operator.short` (or `long`) plus `data_reg.rat` when
    `data.state == "connected"`; `"Searching"` while `data_reg.reg` is
    `searching`; `"Roaming off"` when `data_reg.reg == "roaming"` and no call
    comes up; `"Connecting"` otherwise.
- **Toggle:** `Quickshell.execDetached(["omandroid-sit", "data", enabled ?
  "off" : "on"])`. The phone's user needs to be in the control group
  (`wheel` by default; `[control] group` in the config).

This contract (`status --json`, `watch`, `data on|off`) is what stays
stable: when an oFono or ModemManager front end replaces the daemon, the
CLI moves onto it (2 below) and the tile doesn't change.

---

## 3. Integration: oFono driver or ModemManager plugin

Only one process may own `/dev/umts_ipc0` (SIT has no multiplexing; two
clients would steal each other's responses). So a front end either **talks
to the modem itself**, replacing `omandroid-sitd`, or **talks to the
daemon** over the control socket.

### 3.1 oFono driver (the natural fit)

oFono's model is a modem driver (`plugins/`) that probes a device, plus
atom drivers (`drivers/<vendor>/`) for each capability. SIT's families map
onto atoms one to one:

| oFono atom | SIT |
|---|---|
| modem (`set_online`, `enable`) | SET_RADIO_POWER, IND_RADIO_STATE_CHANGED, CP status ioctl |
| sim (`read_file_*`, `query_passwd_state`, `send_passwd`, `query_pin_retries`) | GET_SIM_STATUS, VERIFY_SIM_PIN (gated as in 1.2), SIM_IO, GET_IMSI |
| netreg (`registration_status`, `current_operator`, `strength`) | GET_CS_REG_STATE, GET_OPERATOR, GET_SIGNAL_STRENGTH, IND_NTW_STATE_CHANGED |
| gprs (`attached_status`, `set_attached`) | GET_PS_REG_STATE, SET_PS_SERVICE |
| gprs-context (`activate_primary`, `deactivate_primary`) | SETUP_DATA_CALL, DEACT_DATA_CALL; oFono reports the address and the interface (`rmnet<CID-1>`) and its connection manager (ConnMan, or our own hook) configures it |
| sms (`submit`, `sca_query`) | SEND_SMS, IND_NEW_SMS, SEND_SMS_ACK |
| devinfo | GET_BASEBAND_VERSION only: **not** the IMEI |

Work: a `sitmodem` plugin (udev match on the CPIF `umts_ipc0` node, the
CP status wait, the reader on GLib's main loop) and `drivers/sitmodem/`
with the codec ported from `sit.py` to C, the send guard included. About
2-3 weeks once the protocol is settled by `omandroid-sitd` on real hardware,
as the research note estimated. oFono's D-Bus API (`org.ofono.Modem`,
`NetworkRegistration`, `ConnectionManager.Powered`, `MessageManager`) then
gives the tile, SMS apps and later voice a standard interface.

### 3.2 ModemManager plugin

ModemManager drives modems through ports of a known kind (AT, QMI, MBIM,
plus net and GPS ports); its plugins pick port types and vendor quirks, but
the protocol engines (`MMBroadbandModem`, `MMBroadbandModemQmi`/`Mbim`) live
in its core. SIT fits none of them, so the choices are:

- a new port type and an `MMBroadbandModemSit` in ModemManager's core
  (upstream would have to want it; 3-4 weeks and a long review), or
- a shim that translates SIT into QMI or MBIM for ModemManager: the whole
  of a QMI or MBIM service model, a bigger job than the client itself, or
- an AT shim, only if SET_FORWARDING_AT_COMMAND (research open question 5)
  turns out to reach a real AT parser. It is on the do-not-send list until
  a plan says otherwise.

ModemManager matters for desktop stacks that expect it (NetworkManager's
WWAN support, GNOME's settings), and Omarchy ships neither by default.

### 3.3 Recommendation

1. **M4 with `omandroid-sitd`**: settle the start-up order, the v11 data
   call item and the signal layout on hardware, with a small Python
   program that's quick to change.
2. **Then an oFono driver** (`sitmodem`), with `sit.py` and `tools/sit-sim`
   as its reference and test bench: the simulator speaks the same framing,
   so oFono's driver can run against it before the phone. `omandroid-sitd`
   stays for bring-up and diagnosis; the two never run at once
   (`Conflicts=` between the units).
3. **The tile and `omandroid-sit` move to oFono's D-Bus API** behind the
   same CLI contract (2.1).
4. **ModemManager only through a SIT port type upstream**, if NetworkManager
   integration is ever needed; not a shim.

---

## 4. M4 runbook: first registration, a data call, SMS (needs M3.4)

**Preconditions:** M3.4 passed (CP ONLINE, rfsd serving the RAM copies);
the M3.5 checksums match; the phone runs the int kernel with the CPIF port.
A SIM in the slot with its PIN lock off (in another phone) if at all
possible. The human runs or approves each step. After every step: `dmesg |
grep -c ufshcd_err_handler` against the count before it (AGENTS: UFS
errors around modem power changes), and check any log excerpt for digit
runs before quoting it here.

**Second terminal for M4.2 onwards:**
`tools/phone-ssh 'dmesg -w' | tee logs/m4-kmsg.log`

```sh
# M4.0 install, enable nothing (risk: none)
tools/phone-install-package packages/omandroid-modem-sit
tools/phone-ssh 'pacman -Q omandroid-modem-sit; systemctl is-enabled omandroid-sitd'
#   pass: 0.1.0; "disabled"
#   stop: the package's check fails on the phone (send the output)

# M4.1 config (risk: none). The human writes the carrier's APN; data stays off.
tools/phone-ssh 'sed -n "/^\[data\]/,/^\[sms\]/p" /etc/omandroid/modem-sit.conf'
#   pass: apn = <the carrier APN>, enabled = no, roaming = no

# M4.2 first contact, radio OFF (risk: low; reads SIM status and the IMSI only)
#   precondition: the modem profile is running and CP is ONLINE (M3.4)
tools/phone-ssh 'timeout 60 omandroid-sitd --radio-off -v' 2>&1 | tee logs/m4.2-sitd.log
#   expect: "CP: online"; "modem: radio ready" (or "no IND_RADIO_READY yet");
#           "-> GET_RADIO_POWER" with a response; "SIM: ready (card state 1, ...)",
#           "IMSI read (not logged)"; no "write refused"; no "session ended"
#   record: the card state, app count, PIN1 state and the GET_RADIO_POWER value
#   stop: any "session ended", CP leaving ONLINE, a new ufshcd_err_handler, a modem crash in dmesg
#   rollback: the timeout ends it; stop the modem profile if the CP misbehaves
#   if "SIM: pin-required": stop here. Take the PIN lock off in another phone (preferred), or M4.4.

# M4.3 radio ON (risk: medium: the radio transmits for the first time from Linux).
#   Announce it; the phone may register and receive calls/SMS from here on.
tools/phone-ssh 'timeout 300 omandroid-sitd -v' 2>&1 | tee logs/m4.3-sitd.log
#   expect: "radio power on requested", "modem: radio state start-network",
#           "data registration: searching, ..." then "home, LTE" (or NR) within about 2 minutes,
#           "operator: <name> (<PLMN>)"
#   pass: omandroid-sit status (another shell) shows voice and data "home": FIRST REGISTRATION
#   stop: SET_RADIO_POWER refused (then M4.3b); registration "denied" (record reject_cause);
#         a modem reset; a new ufshcd_err_handler
#   rollback: tools/phone-ssh 'omandroid-sit radio off'; then the timeout or Ctrl-C
# M4.3b only if SET_RADIO_POWER is refused: one change per run, in this order, rerunning M4.3:
#   modem_config = yes; then slot_mapping = yes; then ap_time = yes  ([modem] in the config)

# M4.4 SIM PIN, only if M4.2 stopped at a PIN and the human chose this path (risk: medium: PIN tries)
#   read the counter first: omandroid-sit status shows "PIN1 tries left: N"; N must be 3
tools/phone-ssh 'omandroid-sitd --allow-pin -v'      # foreground, terminal 1
tools/phone-ssh -t 'omandroid-sit pin'               # terminal 2: the human types the PIN
#   pass: "VERIFY_SIM_PIN: SUCCESS", then "SIM: ready"
#   stop: any rejection. Never retry blind: the daemon refuses with one try left anyway.

# M4.5 data call (risk: low-medium: mobile data use; Wi-Fi keeps the default route while up)
tools/phone-ssh 'systemd-run --unit=x-sit-deadman --on-active=600 /usr/bin/omandroid-sit data off'
tools/phone-ssh 'omandroid-sit data on; sleep 10; omandroid-sit status; ip -br addr show rmnet0; ip route'
#   pass: "mobile data: on, connected on rmnet0"; rmnet0 UP with the address; a default route
#         "dev rmnet0 metric 700"
tools/phone-ssh 'ping -c3 -I rmnet0 9.9.9.9; resolvectl query -i rmnet0 example.org'
#   pass: replies over rmnet0; the name resolves through the carrier's DNS
#   if "unsupported (... v11 ...)": the long data call form. Rerun with
#     OMANDROID_SIT_DUMP=1 to keep the payload in /run/omandroid-sit (0600), copy it to
#     ~/android/reference/ (never the repo), and decode it offline (1.3)
#   stop: "data call refused (cause N)": record N; a modem reset; UFS errors
#   rollback: omandroid-sit data off; systemctl stop x-sit-deadman.timer

# M4.6 SMS (risk: low; sending costs whatever the plan charges)
#   receive: the human texts the phone from another one
tools/phone-ssh 'omandroid-sit status | grep SMS'
#   pass: "SMS received: 1"; "omandroid-sit sms list" shows it (contains a number: don't paste it)
#   send, on the human's explicit go only, to a number of theirs:
tools/phone-ssh 'omandroid-sit sms send <NUMBER> "omandroid test"'
#   pass: exit 0, the message arrives

# M4.7 stop (risk: none), then M3.5
tools/phone-ssh 'omandroid-sit data off; omandroid-sit radio off'   # then end the daemon
#   M3.5: the six partitions' checksums against the backup (MODEM-PLAN)

# M4.8 the service, only after M4.2-M4.6 pass and once more after a reboot
tools/phone-ssh 'systemctl enable --now omandroid-sitd'
#   (ordering after the modem profile's unit comes with packaging that profile)
```

Results (fill in with the date and `uname -r`):

| Step | Date | Kernel | Result |
|---|---|---|---|
| M4.0-M4.8 | | | not run (waits on M3.4) |
