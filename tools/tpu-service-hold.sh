#!/bin/sh
# SPDX-License-Identifier: MIT
# Keep com.google.edgetpu.tachyon.IComputeService registered.
#
# Why: tachyon registers through AidlLazyServiceRegistrar, which unregisters
# and exits as soon as its last client goes away (TPU-PLAN Phase A). The app
# service is its only real client and connects once, so every restart of the
# chain leaves tachyon gone and getService answering with no binder object.
# Here a raw client is already looping getService before tachyon starts, takes
# the handle the moment it appears, BC_ACQUIREs it and holds it, so the
# registrar sees a client for the client's whole lifetime.
#
# Run as root on the phone, from this file (never inline over ssh: pkill -f
# would match the ssh shell's own command line, which is how two earlier
# attempts killed their own session):
#   tools/phone-ssh 'cat > /root/tpu-service-hold.sh' < tools/tpu-service-hold.sh
#   tools/phone-ssh 'sh /root/tpu-service-hold.sh [HOLD_SECONDS]'
#
# The client's lifetime caps the hold: it runs under `timeout 60`, so the
# handle lives 60 s, which is Phase A's done-when. Logs: /tmp/j2-client.log,
# /tmp/ts2.log.
set -u
R=${R:-/usr/lib/omamobile-vendor/edgetpu/root}
N=$R/dev/binderfs/vndbinder
HOLD=${1:-300}
SVC="/system/lib64/libsegvshim.so /system/lib64/libnosid.so \
/system/lib64/libpersist.so /system/lib64/liblazysvc.so \
/system/lib64/libpermissionshim.so /system/lib64/libabortshim.so \
/system/lib64/liblogstderr.so /system/lib64/libselinuxshim.so \
/system/lib64/libpropsshim.so"
NAME=com.google.edgetpu.tachyon.IComputeService/default

mountpoint -q /dev/binderfs || mount -t binder binder /dev/binderfs
mountpoint -q "$R/dev/binderfs" || mount --bind /dev/binderfs "$R/dev/binderfs"

# Kill the previous tachyon by its argv[0] only. pkill -f would also match
# this script's text (if it is ever passed inline) and tpu-exec.py's command
# line; a /proc scan cannot match a shell.
for p in /proc/[0-9]*; do
	[ -r "$p/cmdline" ] || continue
	a=$(tr '\0' '\n' <"$p/cmdline" 2>/dev/null | head -1)
	case $a in
	*/com.google.edgetpu.tachyon-service)
		echo "kill ${p#/proc/}"
		kill "${p#/proc/}" 2>/dev/null
		;;
	esac
done
sleep 0.5

: >/tmp/ts2.log
PRELOAD=$SVC TPU_UID=1000 TPU_GID=1000 LOG=/tmp/ts2.log \
	/root/tpu-exec.py daemon tachyon \
	/vendor/bin/hw/com.google.edgetpu.tachyon-service

# A fresh process per attempt, started after the service so one of them
# catches it: this kernel needs a fresh binder fd for every getService (a
# second transaction in the same process never answers, TPU-PLAN U247).
# Started before tachyon the loop would spend all its attempts on "no
# service" and leave nobody holding the handle.
: >/tmp/j2-client.log
i=0
while [ "$i" -lt 200 ]; do
	NAME=$NAME TRIES=1 HOLD=$HOLD timeout 120 \
		/root/tpu-binder-client "$N" >/tmp/j2-client.log 2>&1 </dev/null &
	cpid=$!
	sleep 0.25
	if grep -qE 'getService try 0: rc 0 handle [1-9]' /tmp/j2-client.log 2>/dev/null; then
		echo "client $cpid holds the service"
		break
	fi
	kill "$cpid" 2>/dev/null
	i=$((i + 1))
done

i=0
while [ "$i" -lt 30 ]; do
	n=$(pgrep -c -f 'com\.google\.edgetpu\.tachyon-servic[e]' 2>/dev/null || true)
	c=$(pgrep -c -x tpu-binder-clie 2>/dev/null || true)
	echo "t=$i tachyon=$n client=$c"
	[ "$n" = "0" ] && break
	i=$((i + 1))
	sleep 0.2
done

echo "=== client ==="
tail -40 /tmp/j2-client.log
echo "=== tachyon ==="
tail -12 /tmp/ts2.log
