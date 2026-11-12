// SPDX-License-Identifier: MIT
// gxp-tachyon-start: start the GXP's Tachyon firmware through the stock
// /dev/gxp ABI.
//
// Why: the TPU's one-time setup is produced by the Tachyon firmware on GXP
// core 0 (TPU-PLAN U179). The stock GXP driver runs that firmware only when a
// client allocates a virtual device and takes the BLOCK + VIRTUAL_DEVICE
// wakelocks (gxp_vd_run -> gxp_firmware_run). The vendor stack drives
// janeiro and never opens /dev/gxp, so nothing starts the producer. This is
// the missing caller: open /dev/gxp, allocate one core, take both wakelocks,
// then hold the fd so the firmware keeps running.
//
// The ABI values are from Google's GPL-2.0 gxp.h (GXP_INTERFACE_VERSION 1.28);
// this copy is only the two ioctls used here.
//
// Build and run on the phone as root:
//   gcc -O2 -o gxp-tachyon-start tools/gxp-tachyon-start.c
//   ./gxp-tachyon-start [cores] [hold-seconds]
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

struct gxp_wake_ioctl {
	uint32_t components_to_wake;
	uint32_t gxp_power_state;
	uint32_t memory_power_state;
	uint32_t vd_timeout_us;
	uint32_t flags;
};

#define GXP_ALLOCATE_VD _IOWR(0xEE, 6, struct gxp_vd_ioctl)
#define GXP_ACQUIRE_WAKE _IOW(0xEE, 25, struct gxp_wake_ioctl)
#define GXP_RELEASE_WAKE _IOW(0xEE, 19, uint32_t)

#define WAKELOCK_BLOCK 1u
#define WAKELOCK_VD 2u
#define GXP_POWER_STATE_UUD 1u

int main(int argc, char **argv)
{
	struct gxp_vd_ioctl vd = {0};
	struct gxp_wake_ioctl wl = {0};
	unsigned int cores = argc > 1 ? (unsigned int)atoi(argv[1]) : 1;
	unsigned int hold = argc > 2 ? (unsigned int)atoi(argv[2]) : 30;
	int fd, ret;

	fd = open("/dev/gxp", O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open /dev/gxp: %s\n", strerror(errno));
		return 1;
	}

	vd.core_count = (uint8_t)cores;
	ret = ioctl(fd, GXP_ALLOCATE_VD, &vd);
	printf("allocate_vd cores %u -> %d (%s) vdid %u\n", cores, ret,
	       ret ? strerror(errno) : "ok", vd.vdid);
	if (ret)
		return 1;

	wl.components_to_wake = WAKELOCK_BLOCK | WAKELOCK_VD;
	wl.gxp_power_state = GXP_POWER_STATE_UUD;
	wl.memory_power_state = 0;
	wl.vd_timeout_us = 1000000;
	ret = ioctl(fd, GXP_ACQUIRE_WAKE, &wl);
	printf("acquire_wake -> %d (%s)\n", ret, ret ? strerror(errno) : "ok");
	if (ret)
		return 1;

	printf("tachyon running, holding %u s\n", hold);
	sleep(hold);

	return 0;
}
