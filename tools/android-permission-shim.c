// SPDX-License-Identifier: MIT
// android-permission-shim: grant android::checkPermission() in the chroot.
//
// The Edge TPU app service host calls android::checkPermission() before it
// hands a client the device fd. The real symbol lives in libandroid.so and
// asks ActivityManager, which does not exist in this minimal vendor chroot.
// The host has no other libandroid import, so the chain drops that NEEDED and
// loads this shim instead. Development only: the phone runs no untrusted apps
// while the TPU stack is brought up by hand.
#include <stdint.h>

int permission_check(const void *permission, int32_t pid, int32_t uid,
		     int32_t enforce)
	__asm__("_ZN7android15checkPermissionERKNS_8String16Eijb");

int permission_check(const void *permission, int32_t pid, int32_t uid,
		     int32_t enforce)
{
	(void)permission;
	(void)pid;
	(void)uid;
	(void)enforce;
	return 0; /* PERMISSION_GRANTED */
}
