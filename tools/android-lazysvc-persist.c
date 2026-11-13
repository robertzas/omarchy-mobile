// SPDX-License-Identifier: MIT
// android-lazysvc-persist: keep a lazy AIDL service registered.
//
// libbinder_ndk.so implements the lazy registrar on top of the C++
// android::binder::LazyServiceRegistrar in libbinder.so, which the service
// process tears down as soon as servicemanager reports zero clients (the
// tachyon service logs "Unregistered all clients and exiting" about a second
// after it registers). LazyServiceRegistrar::forcePersist(true) is the
// supported way to hold a service open: it sets a flag that tryUnregister()
// checks, so no client-count notification can take the service down.
//
// Preload this into the service. Every LazyServiceRegistrar::getInstance()
// call (a direct, interposable import that libbinder_ndk makes) then returns a
// registrar that has been force-persisted.
#include <stdint.h>

typedef void *(*getInstance_fn)(void);
typedef void (*forcePersist_fn)(void *, int);

extern void *dlsym(void *handle, const char *name);
#define RTLD_NEXT ((void *)-1L)

#define SYM_GET_INSTANCE "_ZN7android6binder20LazyServiceRegistrar11getInstanceEv"
#define SYM_FORCE_PERSIST "_ZN7android6binder20LazyServiceRegistrar12forcePersistEb"

static void mark(const char *what)
{
	extern long write(int, const void *, unsigned long);
	const char *p;

	write(2, "LAZYSVC-PERSIST ", 16);
	for (p = what; *p; p++)
		write(2, p, 1);
	write(2, "\n", 1);
}

static getInstance_fn real_get_instance;
static forcePersist_fn real_force_persist;

__attribute__((constructor)) static void persist_loaded(void)
{
	mark("loaded");
}

/*
 * Same mangled name and version as libbinder.so's definition, so a versioned
 * reference from libbinder_ndk.so resolves here first.
 */
void *persist_get_instance(void)
	__asm__("_ZN7android6binder20LazyServiceRegistrar11getInstanceEv");

void *persist_get_instance(void)
{
	void *registrar;

	if (!real_get_instance)
		real_get_instance = (getInstance_fn)dlsym(RTLD_NEXT, SYM_GET_INSTANCE);
	if (!real_get_instance) {
		mark("getInstance not found");
		return 0;
	}

	registrar = real_get_instance();
	if (!registrar)
		return 0;

	if (!real_force_persist)
		real_force_persist =
			(forcePersist_fn)dlsym(RTLD_NEXT, SYM_FORCE_PERSIST);
	if (real_force_persist) {
		real_force_persist(registrar, 1);
		mark("forcePersist(1) on getInstance");
	} else {
		mark("forcePersist not found");
	}
	return registrar;
}
