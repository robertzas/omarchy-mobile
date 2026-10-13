# SPDX-License-Identifier: MIT
# This phone at a glance, fastfetch style: the Linux facts the original read
# from Android and from Arch, from /proc, /sys, os-release, pacman and
# Hyprland. Read-only. Prints one JSON object.
# Ported from simonschubert/fetch in Simon Schubert's omarchy-widgets
# (MIT, Copyright (c) 2026 Simon Schubert and contributors; see
# ../../LICENSE-omarchy-widgets).
import glob
import json
import os
import platform
import pwd
import re
import shutil
import subprocess
import time


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode(errors="replace").strip("\0\n ")
    except OSError:
        return ""


def run(argv, timeout=5):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def os_release():
    out = {}
    for line in read("/etc/os-release").splitlines():
        k, _, v = line.partition("=")
        out[k] = v.strip('"')
    return out


def cpu():
    info = read("/proc/cpuinfo")
    model = ""
    for key in ("model name", "Hardware"):
        m = re.search(r"^%s\s*:\s*(.+)$" % key, info, re.M)
        if m:
            model = m.group(1).strip()
            break
    compatible = read("/sys/firmware/devicetree/base/compatible").split("\0")
    soc = compatible[-1] if len(compatible) > 1 else ""
    mhz = 0
    for f in glob.glob("/sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq"):
        try:
            mhz = max(mhz, int(read(f)) // 1000)
        except ValueError:
            pass
    return {"model": model, "soc": soc, "cores": os.cpu_count() or 0, "arch": platform.machine(), "maxMhz": mhz}


def memory():
    m = {}
    for line in read("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        m[k] = int(v.split()[0]) * 1024 if v.split() else 0
    total = m.get("MemTotal", 0)
    return {"total": total, "used": total - m.get("MemAvailable", 0)}


def display():
    try:
        mons = json.loads(run(["hyprctl", "monitors", "-j"]) or "[]")
    except ValueError:
        return None
    if not mons:
        return None
    d = mons[0]
    return {"width": d.get("width"), "height": d.get("height"), "hz": round(d.get("refreshRate") or 0),
            "scale": d.get("scale")}


def theme():
    for p in ("~/.local/state/omarchy/current/theme.name", "~/.config/omarchy/current/theme.name"):
        name = read(os.path.expanduser(p))
        if name:
            return name
    for p in ("~/.local/state/omarchy/current/theme", "~/.config/omarchy/current/theme"):
        p = os.path.expanduser(p)
        if os.path.islink(p):
            return os.path.basename(os.path.realpath(p))
    return ""


def battery():
    for d in sorted(glob.glob("/sys/class/power_supply/*")):
        if read(d + "/type") != "Battery":
            continue
        out = {}
        for key in ("technology", "health", "cycle_count", "temp", "voltage_now"):
            value = read("%s/%s" % (d, key))
            if value:
                out[key] = value
        return out
    return None


def safe(fn, fallback=None):
    """One fact that can't be read must not cost the others."""
    try:
        return fn()
    except Exception:  # noqa: BLE001
        return fallback


def packages():
    """(all, explicit) from pacman's local database, as fastfetch counts
    them: no pacman run, so it is quick on a phone."""
    total = explicit = 0
    for desc in glob.glob("/var/lib/pacman/local/*/desc"):
        total += 1
        text = read(desc)
        if "%REASON%\n1" not in text:
            explicit += 1
    return total, explicit


def last_upgrade():
    """The last full upgrade's date, from the end of pacman's log."""
    try:
        with open("/var/log/pacman.log", "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - (2 << 20)))
            tail = f.read().decode(errors="replace")
    except OSError:
        return ""
    found = re.findall(r"^\[(\d{4}-\d\d-\d\d)[^\n]*starting full system upgrade", tail, re.M)
    return found[-1] if found else ""


def shell():
    sh = os.path.basename(os.environ.get("SHELL") or pwd.getpwuid(os.getuid()).pw_shell)
    version = run([sh, "--version"], timeout=3).splitlines()
    m = re.search(r"\d+(\.\d+)+", version[0]) if version else None
    return sh + (" " + m.group(0) if m else "")


def main():
    rel = safe(os_release, {})
    disk = safe(lambda: shutil.disk_usage("/"))
    pkgs, explicit = safe(packages, (0, 0))
    print(json.dumps({
        "user": safe(lambda: pwd.getpwuid(os.getuid()).pw_name, os.environ.get("USER", "")),
        "host": platform.node(),
        "model": read("/sys/firmware/devicetree/base/model"),
        "os": rel.get("PRETTY_NAME", "") or rel.get("NAME", ""),
        "kernel": platform.release(),
        "uptime": safe(lambda: float((read("/proc/uptime") or "0").split()[0]), 0),
        "pkgs": pkgs, "explicit": explicit, "upgraded": safe(last_upgrade, ""),
        "shell": safe(shell, ""),
        "cpu": safe(cpu, {"model": "", "soc": "", "cores": os.cpu_count() or 0, "arch": platform.machine(), "maxMhz": 0}),
        "memory": safe(memory, {"total": 0, "used": 0}),
        "storage": {"total": disk.total, "used": disk.total - disk.free} if disk else {"total": 0, "used": 0},
        "display": safe(display), "battery": safe(battery), "theme": safe(theme, ""),
        "locale": os.environ.get("LANG", ""), "timezone": time.strftime("%Z"),
    }))


main()
