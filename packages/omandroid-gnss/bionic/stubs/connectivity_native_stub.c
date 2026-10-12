// SPDX-License-Identifier: MIT
/*
 * Stand-in for libcom.android.tethering.connectivity_native.so, which lives
 * in Android's (compressed) tethering APEX. Stock libandroid_net imports one
 * function from it; nothing in a vendor chroot can be blocked by Android's
 * per-UID network policy, so the answer is always "not blocked" (0).
 */
#include <stdint.h>

#define EXPORT __attribute__((visibility("default")))

EXPORT int AConnectivityNative_getNetworkBlockedReason(uint64_t net_handle,
						       int uid, int *reason)
{
	(void)net_handle;
	(void)uid;
	if (reason)
		*reason = 0;
	return 0;
}
