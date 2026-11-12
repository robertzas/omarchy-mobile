#!/bin/sh
# SPDX-License-Identifier: MIT
# Bring up the stock Tachyon chain on this Linux userspace without poisoning
# the host shell. tools/tpu-tachyon-run's `export LD_PRELOAD` makes every host
# child (sleep, pkill, chroot itself) load bionic shims and segfault, so the
# services are started through /root/tpu-exec.py instead: python keeps a clean
# environment and only the exec'd bionic binary sees LD_PRELOAD.
#
# Run as root on the phone:  sh /root/tpu-chain-exec.sh
# Restarts every layer; safe to run repeatedly in the same boot (one TPU
# power-up only: tpu-hold is left running if it already is).
set -u
R=/usr/lib/omamobile-vendor/edgetpu/root
SVC="/system/lib64/libsegvshim.so /system/lib64/libnosid.so /system/lib64/liblazysvc.so /system/lib64/libpermissionshim.so /system/lib64/libabortshim.so /system/lib64/liblogstderr.so /system/lib64/libselinuxshim.so /system/lib64/libpropsshim.so"
CL="/system/lib64/libnosid.so /system/lib64/liblogstderr.so /system/lib64/libselinuxshim.so /system/lib64/libpropsshim.so"
SM="/system/lib64/liblogstderr.so /system/lib64/libselinuxshim.so /system/lib64/libpropsshim.so"

# Nodes the stack needs: binderfs, the dma heap, the TPU device.
mountpoint -q /dev/binderfs || mount -t binder binder /dev/binderfs
mountpoint -q "$R/dev/binderfs" || mount --bind /dev/binderfs "$R/dev/binderfs"
for n in binder hwbinder vndbinder; do ln -sfn /dev/binderfs/$n /dev/$n; done
ln -sfn janeiro /dev/edgetpu
ln -sfn janeiro /dev/edgetpu-soc
chown root:1000 /dev/janeiro 2>/dev/null
chmod 660 /dev/janeiro
chmod 666 /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder 2>/dev/null
[ -e /dev/dma_heap/system ] || mknod /dev/dma_heap/system c 249 0
chmod 666 /dev/dma_heap/system 2>/dev/null
mkdir -p "$R/dev/dma_heap" "$R/data/vendor/edgetpu/cache" \
	"$R/data/vendor/hal_neuralnetworks_darwinn" "$R/data/local/tmp"
[ -e "$R/dev/dma_heap/system" ] || mknod "$R/dev/dma_heap/system" c 249 0
for n in binder hwbinder vndbinder; do ln -sfn "binderfs/$n" "$R/dev/$n"; done
ln -sfn janeiro "$R/dev/edgetpu"
ln -sfn janeiro "$R/dev/edgetpu-soc"
chmod 777 "$R/data/vendor/edgetpu" "$R/data/vendor/edgetpu/cache" \
	"$R/data/local/tmp" "$R/data/vendor/hal_neuralnetworks_darwinn" 2>/dev/null
mountpoint -q "$R/proc" || mount -t proc proc "$R/proc"
mountpoint -q "$R/sys" || mount --rbind /sys "$R/sys"

pkill -x servicemanager 2>/dev/null
pkill -f vendor.google.edgetpu 2>/dev/null
pkill -x com.google.edge 2>/dev/null
pkill -f edgetpu_app_service 2>/dev/null
pkill -f power-service 2>/dev/null
sleep 1

PRELOAD="$SM" TPU_UID=0 TPU_GID=0 LOG=/tmp/sm.log \
	/root/tpu-exec.py daemon sm /system/bin/servicemanager /dev/vndbinder
sleep 2
POWER_HAL=$(ls "$R"/vendor/bin/hw/android.hardware.power-service* 2>/dev/null | head -1)
if [ -n "$POWER_HAL" ]; then
	PRELOAD="$SVC" TPU_UID=0 TPU_GID=0 LOG=/tmp/pw.log \
		/root/tpu-exec.py daemon power "${POWER_HAL#"$R"}"
	sleep 2
fi
PRELOAD="$SVC" TPU_UID=0 TPU_GID=0 LOG=/tmp/vs.log \
	/root/tpu-exec.py daemon vendor \
	/vendor/bin/hw/vendor.google.edgetpu_vendor_service@1.0-service
sleep 2
if ! pgrep -x tpu-hold >/dev/null; then
	setsid /root/tpu-hold </dev/null >/tmp/hold.log 2>&1 &
	sleep 2
fi
PRELOAD="$SVC" TPU_UID=1000 TPU_GID=1000 LOG=/tmp/ts.log \
	/root/tpu-exec.py daemon tachyon /vendor/bin/hw/com.google.edgetpu.tachyon-service
sleep 0.5
PRELOAD="$SVC" TPU_UID=1000 TPU_GID=1000 LOG=/tmp/as.log \
	/root/tpu-exec.py daemon app \
	/system_ext/bin/hw/vendor.google.edgetpu_app_service@1.0-service
sleep 2
printf 'servicemanager=%s power=%s vendor=%s tachyon=%s app=%s hold=%s\n' \
	"$(pgrep -x servicemanager | head -1)" \
	"$(pgrep -f power-service | head -1)" \
	"$(pgrep -f vendor.google.edgetpu_vendor | head -1)" \
	"$(pgrep -x com.google.edge | head -1)" \
	"$(pgrep -f edgetpu_app_service | head -1)" \
	"$(pgrep -x tpu-hold | head -1)"
