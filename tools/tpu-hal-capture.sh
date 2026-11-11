#!/bin/sh
# SPDX-License-Identifier: MIT
# tpu-hal-capture: run the A17 HAL's own device-creation path and capture the
# VII element/payload the driver logs to dmesg. The HAL is the only stock
# producer of the firmware's type-1 setup (TPU-PLAN U162), and the driver prints
# every VII payload it sends, so the exact bytes come out here even if the HAL
# then crashes. Copy the payload out and submit it with tools/tpu-fwsetup.sh.
#
# A script file, not an inline SSH command: `pkill -f edgetpu_app_service` in an
# inline command matches the SSH shell's own command line (TPU-PLAN U172).
set -u
R=/usr/lib/omamobile-vendor/edgetpu/root

pkill -x com.google.edge 2>/dev/null
pkill -x servicemanager 2>/dev/null
pkill -x android.hardwar 2>/dev/null
pkill -f 'vendor.google.edgetpu' 2>/dev/null
pkill -f 'edgetpu_app_service' 2>/dev/null
pkill -f 'power-service' 2>/dev/null
sleep 1

BEFORE=$(dmesg | grep -c 'vii-payload')
echo "vii-payload lines before: $BEFORE"

# No liblazysvc here: that shim provides AServiceManager_addService for the
# services, and this client does not define it ("cannot locate symbol
# AServiceManager_addService"). The HAL client needs only the log, SELinux,
# property, abort and SIGSEGV shims.
PRELOAD="/system/lib64/libsegvshim.so /system/lib64/libnosid.so \
/system/lib64/libabortshim.so /system/lib64/liblogstderr.so \
/system/lib64/libselinuxshim.so /system/lib64/libpropsshim.so"
TPU_TIMEOUT="${UTIMEOUT:-25}" PRELOAD="$PRELOAD" TPU_UID=0 TPU_GID=0 \
	/root/tpu-exec.py run "${HAL:-/vendor/bin/tpu-a17-hal}" vd 2>&1 | tail -25

echo "=== dmesg VII lines"
dmesg | grep -iE 'vii-elem|vii-payload|Setup is not|No global|scratch' | tail -30
