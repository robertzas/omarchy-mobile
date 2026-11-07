/*
 * Ask servicemanager whether the Tachyon compute service is registered.
 *
 * A constructor in a shared object, run inside the vendor chroot next to the
 * other shims:
 *   LD_PRELOAD="/system/lib64/svclookup.so ..." chroot $R /vendor/bin/edgetpu-run
 * It resolves AServiceManager_getService from libbinder_ndk, so it needs the
 * real Android runtime and nothing from the host.
 */

extern void *AServiceManager_getService(const char *instance);
extern int AIBinder_isAlive(const void *binder);

static long sys_write(int fd, const void *buf, unsigned long len)
{
	register long x0 __asm__("x0") = fd;
	register const void *x1 __asm__("x1") = buf;
	register unsigned long x2 __asm__("x2") = len;
	register long x8 __asm__("x8") = 64;

	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
	return x0;
}

static unsigned long slen(const char *s)
{
	unsigned long n = 0;

	while (s[n])
		n++;
	return n;
}

static void out(const char *s)
{
	sys_write(2, s, slen(s));
}

static const char *const names[] = {
	"com.google.edgetpu.tachyon.IComputeService/default",
	"com.google.edgetpu.tachyon.IComputeService",
	"android.frameworks.stats.IStats/default",
};

static void probe(void)
{
	unsigned long i;

	for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		void *b = AServiceManager_getService(names[i]);

		out("SVC ");
		out(names[i]);
		if (!b) {
			out(" NULL\n");
		} else {
			out(" FOUND alive=");
			out(AIBinder_isAlive(b) ? "1" : "0");
			out("\n");
		}
	}
}

// Entry point so this can be a standalone PIE: preloads are unreliable when
// the linker cannot find its configuration, and the probe needs no crt.
void _start(void)
{
	register long x8 __asm__("x8") = 94; /* exit_group */
	register long x0 __asm__("x0") = 0;

	probe();
	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8));
	for (;;)
		;
}
