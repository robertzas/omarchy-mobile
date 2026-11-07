// SPDX-License-Identifier: MIT
/*
 * The stock Edge TPU delegate calls AServiceManager_isDeclared() while it
 * creates its metrics logger. On Android that reaches servicemanager through
 * binder; on a Linux userspace there is no servicemanager, and libbase waits
 * for its property in a loop, so DarwinnDelegate_CreateVirtualDevice never
 * returns (TPU-PLAN U23). Pretending no service is declared skips the stats
 * client and lets device creation continue.
 *
 * Usage in the vendor chroot:
 *   LD_PRELOAD=/vendor/lib64/libnometrics.so /vendor/bin/edgetpu-run MODEL
 */
#include <stdbool.h>

bool AServiceManager_isDeclared(const char *name)
{
	(void)name;
	return false;
}
