// SPDX-License-Identifier: MIT
// Make AIDL lazy service registration work on a servicemanager that does not
// implement IServiceManager::registerLazyService.
//
// The vendor Edge TPU services register through AidlLazyServiceRegistrar, which
// calls AServiceManager_registerLazyService[_WithFlags] and then
// registerClientCallback. Our stock servicemanager answers those transactions
// with ENOTSUP, so every service aborts in a CHECK. Registering eagerly gives
// the same visible result for our purposes: the name is published and stays
// published, which is what a development session wants anyway.
//
// The marker on stderr proves the shim was actually interposed, rather than
// the call being resolved inside libbinder_ndk.
//
// Build: clang --target=aarch64-linux-android30 -shared -fPIC -nostdlib \
//          -fno-stack-protector -o liblazysvc.so android-lazysvc-shim.c
#include <stdint.h>

typedef struct AIBinder AIBinder;
typedef struct AStatus AStatus;

extern AStatus *AServiceManager_addService(AIBinder *binder, const char *instance);
extern long write(int fd, const void *buf, unsigned long count);

static void mark(const char *what)
{
	write(2, "LAZYSVC-SHIM ", 13);
	while (*what)
		write(2, what++, 1);
	write(2, "\n", 1);
}

// Ask libbinder_ndk for the exception code: AStatus is opaque and reading its
// fields directly faulted, so use the exported accessor.
extern int32_t AStatus_getExceptionCode(AStatus *status);

static void dump_status(AStatus *status)
{
	static const char hex[] = "0123456789abcdef";
	char line[] = "LAZYSVC-SHIM exception 0x00000000\n";
	unsigned int v;
	int i, at;

	if (!status) {
		write(2, "LAZYSVC-SHIM exception null\n", 28);
		return;
	}
	v = (unsigned int)AStatus_getExceptionCode(status);
	for (i = 0, at = 27; i < 8; i++, at--)
		line[at] = hex[(v >> (4 * i)) & 0xf];
	write(2, line, sizeof(line) - 1);
}

AStatus *AServiceManager_registerLazyService(AIBinder *binder, const char *instance)
{
	AStatus *status;

	mark("registerLazyService");
	status = AServiceManager_addService(binder, instance);
	dump_status(status);
	return status;
}

AStatus *AServiceManager_registerLazyServiceWithFlags(AIBinder *binder,
						      const char *instance, uint32_t flags)
{
	AStatus *status;

	mark("registerLazyServiceWithFlags");
	(void)flags;
	status = AServiceManager_addService(binder, instance);
	dump_status(status);
	return status;
}

AStatus *AServiceManager_registerLazyServiceWithCallback(AIBinder *binder,
							 const char *instance,
							 AIBinder *callback)
{
	mark("registerLazyServiceWithCallback");
	(void)callback;
	return AServiceManager_addService(binder, instance);
}
