// SPDX-License-Identifier: MIT
//
// android-vlog-shim: raise the Tachyon core's vlog level when the service
// loads, before the service parses any command. The core keeps why it
// refuses an import or a register to itself unless the level is up.
//
// Run through tools/tpu-tachyon-run with TPU_VLOG=5 (the run script copies it
// into the chroot and prepends it to the services' LD_PRELOAD). See
// device/cheetah/TPU-PLAN.md U123.
//
// No libc headers: the chroot's libc is bionic, and the host headers are not
// for this target. The core is a DT_NEEDED of the service, but a preload's
// constructor runs before that mapping is searched by dlsym(RTLD_DEFAULT), so
// dlopen the core by name instead: it is already mapped, and this returns the
// same handle.

extern char *getenv(const char *);
extern void *dlsym(void *, const char *);
extern void *dlopen(const char *, int);
extern int atoi(const char *);
extern long write(int, const void *, unsigned long);

#define RTLD_DEFAULT ((void *)0)
#define RTLD_NOW 2

__attribute__((constructor)) static void raise_vlog(void) {
	void *core = dlopen("libtachyon_core.so", RTLD_NOW);
	void (*set_level)(int) = (void (*)(int))dlsym(core ? core : RTLD_DEFAULT,
						     "TachyonCore_SetVlogLevel");
	const char *want = getenv("TPU_VLOG");
	int level = 5;

	if (!set_level)
		set_level = (void (*)(int))dlsym(RTLD_DEFAULT,
						"TachyonCore_SetVlogLevel");
	if (!set_level) {
		write(2, "vlog:nosym\n", 11);
		return;
	}
	if (want && *want) level = atoi(want);
	set_level(level);
	write(2, "vlog:set\n", 9);
}
