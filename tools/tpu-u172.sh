#!/bin/sh
# SPDX-License-Identifier: MIT
# tpu-u172: replay the U171 register experiment (DGC0 container, inline buffer
# descriptor, third import for the dependent handle) and keep the tachyon
# service's own log, which says what the VD is waiting for.
#
# Run on the phone as root. The TPU must already be up (tpu-hold); restarting
# the chain does not power-cycle it.
set -u
R=/usr/lib/omamobile-vendor/edgetpu/root
CL=${CL:-/vendor/bin/tpu-tachyon-client.u173}

echo "client scratch2 knob present: $(strings -a "$R$CL" | grep -c 'sendFileDescriptors scratch2')"

sh /root/tpu-chain-exec.sh >/tmp/chain.out 2>&1
echo "chain: $(tail -1 /tmp/chain.out)"
sleep 1

CLPRE="/system/lib64/libnosid.so /system/lib64/liblogstderr.so \
/system/lib64/libselinuxshim.so /system/lib64/libpropsshim.so"

HANDLE=1 FDH=1 TYPES=1,2,5,5,5,7 SETUP=1 UORDER=HDIJV \
	H2=2 FDH2=2 H3="${H3:-1048584}" FDH3="${H3:-1048584}" IVH=1 \
	SSIZE=1048576 GFILE=/vendor/etc/graph-dgc0.bin DELAY=1 POLL=60 \
	TPU_TIMEOUT=40 PRELOAD="$CLPRE" TPU_UID=0 TPU_GID=0 \
	/root/tpu-exec.py run "$CL"

echo "=== service log"
tail -35 /tmp/ts.log
echo "=== dmesg"
dmesg | grep -iE 'edgetpu|janeiro' | tail -8
