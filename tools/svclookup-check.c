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
extern void *AServiceManager_addService(void *binder, const char *instance);
extern int AStatus_isOk(const void *status);
extern int AStatus_getExceptionCode(const void *status);

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
	"android.hardware.power.IPower/default",
	"google.hardware.power.extension.pixel.IPowerExt/default",
	"com.google.edgetpu.tachyon.IComputeService/default",
	"android.frameworks.stats.IStats/default",
};

static void putdec(long v)
{
	char b[24];
	int i = 23, neg = v < 0;
	unsigned long u = neg ? (unsigned long)-v : (unsigned long)v;

	b[i--] = 0;
	do {
		b[i--] = '0' + u % 10;
		u /= 10;
	} while (u);
	if (neg)
		b[i--] = '-';
	out(&b[i + 1]);
}

static void probe_add(void)
{
	void *st;
	void *b;

	/* servicemanager logs its VINTF hit before it looks at the binder. If a
	 * NULL binder is what the Power HAL passes, this reproduces the
	 * "Found ..." line with a failed status and no service. */
	st = AServiceManager_addService(0, "android.hardware.power.IPower/default");
	out("ADD null ok=");
	out(st && AStatus_isOk(st) ? "1" : "0");
	out(" ex=");
	putdec(st ? AStatus_getExceptionCode(st) : -999);
	out("\n");

	/* The same add with a real (proxy) binder: if this one is found below,
	 * servicemanager's path is fine and the Power HAL's binder is the
	 * difference. */
	b = AServiceManager_getService("com.google.edgetpu.tachyon.IComputeService/default");
	out("ADD proxy binder=");
	if (!b) {
		out("no binder\n");
		return;
	}
	st = AServiceManager_addService(b, "android.hardware.power.IPower/default");
	out("ok=");
	out(st && AStatus_isOk(st) ? "1" : "0");
	out(" ex=");
	putdec(st ? AStatus_getExceptionCode(st) : -999);
	out("\n");
}

static void probe(void)
{
	unsigned long i;

	/* probe_add() crashes client-side on a NULL binder (fault 0xfffffffd),
	 * which is itself the finding: see TPU-PLAN U71. */
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
