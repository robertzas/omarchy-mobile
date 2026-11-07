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
// The return value of AServiceManager_addService is NOT always an AStatus* in
// this chroot: the vendor service received 0xffffff7f, which is -129
// (EX_TRANSACTION_FAILED) as a value, and calling AStatus_getExceptionCode() on
// it faulted at exactly that address. So the shim only ever *prints* the raw
// value and never dereferences it: the registrar's own CHECK on the status is
// what the caller does with it.
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

// Print the raw return value as hex. No accessor call: the value is not
// guaranteed to be a pointer (see the comment above).
static void dump_ret(const char *name, AStatus *status)
{
	static const char hex[] = "0123456789abcdef";
	char line[] = "LAZYSVC-SHIM ret 0x0000000000000000\n";
	unsigned long v = (unsigned long)status;
	int i, at = 31, j;

	for (i = 0; name[i] && i < 24; i++)
		line[i] = name[i];
	line[i] = ' ';
	for (j = 31; j > 31 - 16; j--, v >>= 4)
		line[j] = hex[v & 0xf];
	line[15] = ' ';
	write(2, line, sizeof(line) - 1);
}

AStatus *AServiceManager_registerLazyService(AIBinder *binder, const char *instance)
{
	AStatus *status;

	mark("registerLazyService");
	status = AServiceManager_addService(binder, instance);
	dump_ret("registerLazyService", status);
	return status;
}

AStatus *AServiceManager_registerLazyServiceWithFlags(AIBinder *binder,
						      const char *instance, uint32_t flags)
{
	AStatus *status;

	mark("registerLazyServiceWithFlags");
	(void)flags;
	status = AServiceManager_addService(binder, instance);
	dump_ret("registerLazyServiceWithFlags", status);
	return status;
}

AStatus *AServiceManager_registerLazyServiceWithCallback(AIBinder *binder,
							 const char *instance,
							 AIBinder *callback)
{
	AStatus *status;

	mark("registerLazyServiceWithCallback");
	(void)callback;
	status = AServiceManager_addService(binder, instance);
	dump_ret("registerLazyServiceWithCallback", status);
	return status;
}
