// SPDX-License-Identifier: MIT
// gxp-tpu-connect: stock's TPU<->GXP interop handshake through the stock
// /dev/gxp ABI.
//
// Why: the TPU firmware refuses every command with the setup gate ("Setup is
// not done yet ... type 0", response 0xf000009) until something registers the
// TPU with the Tachyon firmware on GXP core 0 (TPU-PLAN U179, U223-U225).
// Stock does it from userspace: libgxp's GxpCapi_ConnectTpu, whose kernel
// side is GXP_MAP_TPU_MBX_QUEUE. That ioctl asks the TPU driver for the DSP
// external mailbox (ALLOCATE_EXTERNAL_MAILBOX, edgetpu_ext_driver_cmd), then
// maps its cmd/rsp queue pair into the virtual device's GXP address space at
// GXP_IOVA_TPU_MBX_BUFFER(core) (gxp_dma_map_tpu_buffer), so the firmware can
// read the TPU's queues directly. Our vendor chain speaks janeiro and never
// opens /dev/gxp, so the mapping has never existed on this port.
//
// The TPU must already be powered (tpu-hold) before this runs: the VD
// allocation fails with EINVAL while the TPU is off (U224/U225).
//
// The ABI values are from Google's GPL-2.0 gxp.h (GXP_INTERFACE_VERSION
// 1.28) and gxp-common-platform.c; attr_ptr = 0 makes the TPU driver use the
// group's mailbox attributes, as it does for the VII mailbox.
//
// Build and run on the phone as root:
//   gcc -O2 -o gxp-tpu-connect tools/gxp-tpu-connect.c
//   ./gxp-tpu-connect [cores] [hold-seconds]
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

struct gxp_vd_ioctl {
	uint8_t core_count;
	uint8_t flags;
	uint8_t reserved[6];
	uint32_t vdid;
};

struct gxp_tpu_mbx_ioctl {
	uint32_t tpu_fd;	/* fd of the opened TPU device */
	uint32_t virtual_core_list; /* deprecated: all cores are mapped */
	uint64_t attr_ptr;	/* edgetpu_mailbox_attr __user *, 0 = defaults */
};

struct gxp_wake_ioctl {
	uint32_t components_to_wake;
	uint32_t gxp_power_state;
	uint32_t memory_power_state;
	uint32_t vd_timeout_us;
	uint32_t flags;
};

#define GXP_ALLOCATE_VD _IOWR(0xEE, 6, struct gxp_vd_ioctl)
#define GXP_MAP_TPU_MBX _IOW(0xEE, 13, struct gxp_tpu_mbx_ioctl)
#define GXP_ACQUIRE_WAKE _IOW(0xEE, 25, struct gxp_wake_ioctl)

#define WAKELOCK_BLOCK 1u
#define WAKELOCK_VD 2u
#define GXP_POWER_STATE_UUD 1u

int main(int argc, char **argv)
{
	struct gxp_vd_ioctl vd = {0};
	struct gxp_tpu_mbx_ioctl mbx = {0};
	struct gxp_wake_ioctl wl = {0};
	unsigned int cores = argc > 1 ? (unsigned int)atoi(argv[1]) : 1;
	unsigned int hold = argc > 2 ? (unsigned int)atoi(argv[2]) : 30;
	int gxp, tpu, ret;

	setvbuf(stdout, NULL, _IONBF, 0);

	gxp = open("/dev/gxp", O_RDWR);
	if (gxp < 0) {
		fprintf(stderr, "open /dev/gxp: %s\n", strerror(errno));
		return 1;
	}

	tpu = open("/dev/edgetpu", O_RDWR);
	printf("tpu fd %d%s\n", tpu,
	       tpu < 0 ? strerror(errno) : "");
	if (tpu < 0)
		return 1;

	vd.core_count = (uint8_t)cores;
	ret = ioctl(gxp, GXP_ALLOCATE_VD, &vd);
	printf("allocate_vd cores %u -> %d (%s) vdid %u\n", cores, ret,
	       ret ? strerror(errno) : "ok", vd.vdid);
	if (ret)
		return 1;

	mbx.tpu_fd = (uint32_t)tpu;
	mbx.virtual_core_list = 1;
	mbx.attr_ptr = 0;
	errno = 0;
	ret = ioctl(gxp, GXP_MAP_TPU_MBX, &mbx);
	printf("map_tpu_mbx_queue fd %u -> %d (%s)\n", mbx.tpu_fd, ret,
	       ret ? strerror(errno) : "ok");

	wl.components_to_wake = WAKELOCK_BLOCK | WAKELOCK_VD;
	wl.gxp_power_state = GXP_POWER_STATE_UUD;
	wl.memory_power_state = 0;
	wl.vd_timeout_us = 1000000;
	ret = ioctl(gxp, GXP_ACQUIRE_WAKE, &wl);
	printf("acquire_wake -> %d (%s)\n", ret, ret ? strerror(errno) : "ok");

	printf("holding %u s\n", hold);
	sleep(hold);

	return 0;
}
