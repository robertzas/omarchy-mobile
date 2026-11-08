// SPDX-License-Identifier: MIT
// android-addservice-shim: let a chroot HAL "register" without servicemanager.
//
// The Darwinn NNAPI HAL registers android.hardware.neuralnetworks.IDevice/
// google-edgetpu and aborts when servicemanager refuses a uid-10000 caller.
// Nothing in the TPU bring-up needs that NNAPI name: the delegate reaches the
// device through the Tachyon service (the app service owns the fd), so the
// registration only has to succeed locally for the HAL to keep starting.
//
// This shim answers the NDK registration calls with an OK status. It must be
// preloaded into the HAL alone (HAL_PRELOAD in tools/tpu-tachyon-run): the
// services that really must be visible keep the real AServiceManager.
#include <stdint.h>

typedef struct AIBinder AIBinder;
typedef struct AStatus AStatus;

extern AStatus *AStatus_newOk(void);
extern long write(int fd, const void *buf, unsigned long count);

static void mark(const char *what)
{
	write(2, "ADDSVC-SHIM ", 12);
	while (*what)
		write(2, what++, 1);
	write(2, "\n", 1);
}

AStatus *AServiceManager_addService(AIBinder *binder, const char *instance)
{
	(void)binder;
	mark(instance ? instance : "(null)");
	return AStatus_newOk();
}

/*
 * The Darwinn HAL imports this one (LIBBINDER_NDK34), not the plain call,
 * and tests the return as a 32-bit status: a pointer is never zero, which is
 * why the OK-filled AStatus above still logged "Could not register". Return
 * 0 (OK) so the HAL reaches its thread pool.
 */
int AServiceManager_addServiceWithFlags(AIBinder *binder,
					const char *instance, uint32_t flags)
{
	(void)binder;
	(void)flags;
	mark(instance ? instance : "(null)");
	return 0;
}

AStatus *AServiceManager_registerLazyService(AIBinder *binder,
					     const char *instance)
{
	(void)binder;
	mark(instance ? instance : "(null)");
	return AStatus_newOk();
}

AStatus *AServiceManager_registerLazyServiceWithFlags(AIBinder *binder,
						      const char *instance,
						      uint32_t flags)
{
	(void)binder;
	(void)flags;
	mark(instance ? instance : "(null)");
	return AStatus_newOk();
}
