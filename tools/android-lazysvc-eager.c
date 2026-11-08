// SPDX-License-Identifier: MIT
// android-lazysvc-eager: publish an AidlLazyServiceRegistrar service eagerly.
//
// The stock servicemanager answers registerLazyService* with ENOTSUP, so the
// Power HAL's registrar fails and nothing publishes
// android.hardware.power.IPower/default; the Darwinn HAL and the Tachyon core
// then log "Unable to connect to Power HAL". Ask the real AServiceManager for
// an eager registration instead (uid 1000 is accepted; a uid-10000 caller is
// not). Preload into the Power HAL only.
#include <stdint.h>

typedef struct AIBinder AIBinder;
typedef struct AStatus AStatus;

extern AStatus *AServiceManager_addService(AIBinder *binder, const char *instance);
extern AStatus *AStatus_newOk(void);
extern long write(int fd, const void *buf, unsigned long count);

static void mark(const char *what)
{
	write(2, "LAZYSVC-EAGER ", 14);
	while (*what)
		write(2, what++, 1);
	write(2, "\n", 1);
}

AStatus *AServiceManager_registerLazyService(AIBinder *binder,
					     const char *instance)
{
	AStatus *status = AServiceManager_addService(binder, instance);

	mark(instance ? instance : "(null)");
	return status ? status : AStatus_newOk();
}

AStatus *AServiceManager_registerLazyServiceWithFlags(AIBinder *binder,
						      const char *instance,
						      uint32_t flags)
{
	AStatus *status;

	(void)flags;
	status = AServiceManager_addService(binder, instance);
	mark(instance ? instance : "(null)");
	return status ? status : AStatus_newOk();
}
