# SPDX-License-Identifier: MIT
# This phone at a glance, fastfetch style: the Linux facts the original read
# from Android and from Arch, from /proc, /sys, os-release, pacman and
# Hyprland. Read-only. Prints one JSON object.
# Ported from simonschubert/fetch in Simon Schubert's omarchy-widgets
# (MIT, Copyright (c) 2026 Simon Schubert and contributors; see README.md).
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


def main():
    rel = os_release()
    disk = shutil.disk_usage("/")
    pkgs = run(["pacman", "-Qq"]).count("\n")
    explicit = run(["pacman", "-Qqe"]).count("\n")
    upgraded = ""
    try:
        with open("/var/log/pacman.log", errors="replace") as f:
            for line in f:
                if "starting full system upgrade" in line:
                    upgraded = line[1:11]
    except OSError:
        pass
    sh = os.path.basename(os.environ.get("SHELL") or pwd.getpwuid(os.getuid()).pw_shell)
    version = run([sh, "--version"]).splitlines()
    m = re.search(r"\d+(\.\d+)+", version[0]) if version else None
    print(json.dumps({
        "user": pwd.getpwuid(os.getuid()).pw_name,
        "host": platform.node(),
        "model": read("/sys/firmware/devicetree/base/model"),
        "os": rel.get("PRETTY_NAME", ""),
        "kernel": platform.release(),
        "uptime": float((read("/proc/uptime") or "0").split()[0]),
        "pkgs": pkgs, "explicit": explicit, "upgraded": upgraded,
        "shell": sh + (" " + m.group(0) if m else ""),
        "cpu": cpu(), "memory": memory(),
        "storage": {"total": disk.total, "used": disk.total - disk.free},
        "display": display(), "battery": battery(), "theme": theme(),
        "locale": os.environ.get("LANG", ""), "timezone": time.strftime("%Z"),
    }))


main()
