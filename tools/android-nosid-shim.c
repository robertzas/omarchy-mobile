// SPDX-License-Identifier: MIT
// Keep published binder nodes from demanding a security context.
//
// Android's libbinder sets FLAT_BINDER_FLAG_TXN_SECURITY_CTX on every service
// node it publishes (`AIBinder_setRequestingSid`), so the kernel must translate
// the caller's secid into an LSM context for each transaction to that node.
// This mainline kernel has no LSM that implements secid_to_secctx -- SELinux is
// not built in, and /sys/kernel/security/lsm reads "capability,landlock" -- so
// drivers/android/binder.c:3366 fails the transaction with BR_FAILED_REPLY and
// -ENOTSUP: dmesg says "binder: N:N failed to get security context". That is
// why nothing could register on /dev/vndbinder and why every service aborted in
// AidlLazyServiceRegistrar's CHECK.
//
// Dropping the flag is safe here: the chroot runs as one user and no LSM
// enforces labels on this kernel.
//
// Build: clang --target=aarch64-linux-android30 -shared -fPIC -nostdlib \
//          -fno-stack-protector -o libnosid.so android-nosid-shim.c
typedef unsigned long size_t;

extern long write(int, const void *, size_t);

static void mark(const char *what)
{
	write(2, "NOSID-SHIM ", 11);
	while (*what)
		write(2, what++, 1);
	write(2, "\n", 1);
}

// The NDK entry point: AIDL plumbing turns the flag on here.
void AIBinder_setRequestingSid(void *binder, _Bool enable)
{
	(void)binder;
	mark(enable ? "AIBinder_setRequestingSid(1) dropped"
		    : "AIBinder_setRequestingSid(0)");
}

// libbinder_ndk also reaches the C++ object directly. The symbol is exported by
// libbinder.so, so this definition is what the PLT resolves to.
void bbinder_set_requesting_sid(void *self, _Bool enable)
	__asm__("_ZN7android7BBinder16setRequestingSidEb");
void bbinder_set_requesting_sid(void *self, _Bool enable)
{
	(void)self;
	mark(enable ? "BBinder::setRequestingSid(1) dropped"
		    : "BBinder::setRequestingSid(0)");
}
