#!/bin/sh
# SPDX-License-Identifier: MIT
# tpu-fwsetup: submit a setup payload straight to the firmware through the
# driver (EDGETPU_MAP_BUFFER + one VII element), then read the firmware's own
# log from dmesg. No Tachyon core: the core sends only its own legacy setup
# once, so this is the only way to iterate the type-1 payload (TPU-PLAN U173).
#
# Usage on the phone: sh /root/tpu-fwsetup.sh PAYLOAD [CODE]
# The payload path is inside the vendor chroot (edgetpu-run runs chrooted):
# pass /vendor/etc/... and the script copies it there first.
set -u
R=/usr/lib/omamobile-vendor/edgetpu/root
SRC=${1:-/root/setup-t1.bin}
CODE=${2:-0}
NAME=${SRC##*/}
PAYLOAD=/vendor/etc/fwsetup-$NAME

cp "$SRC" "$R$PAYLOAD"

pkill -x com.google.edge 2>/dev/null
pkill -x servicemanager 2>/dev/null
pkill -f 'vendor.google.edgetpu' 2>/dev/null
pkill -f 'edgetpu_app_service' 2>/dev/null
pkill -f 'power-service' 2>/dev/null
sleep 1

echo "payload: $SRC -> $PAYLOAD ($(wc -c <"$SRC") bytes) code=$CODE"

PRELOAD="/system/lib64/libnosid.so /system/lib64/liblogstderr.so \
/system/lib64/libselinuxshim.so /system/lib64/libpropsshim.so"
if [ "${MODE:-mapped}" = "cmdsweep" ]; then
	# The 32-slot Command table: two patterns over all slots, so the firmware's
	# "command of type N" names the vtable slot it reads as the type.
	TPU_TIMEOUT="${UTIMEOUT:-40}" PRELOAD="$PRELOAD" TPU_UID=0 TPU_GID=0 \
		/root/tpu-exec.py run /vendor/bin/edgetpu-run cmdsweep
else
	TPU_TIMEOUT="${UTIMEOUT:-20}" PRELOAD="$PRELOAD" TPU_UID=0 TPU_GID=0 \
		/root/tpu-exec.py run /vendor/bin/edgetpu-run mapped "$CODE" 0 "$PAYLOAD"
fi

echo "=== firmware log"
dmesg | grep -iE 'vii|setup|scratch|command of type|payload' | tail -22
