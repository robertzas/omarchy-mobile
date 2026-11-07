/*
 * A constructor that tries to load the vendor Edge TPU client libraries, so
 * one cold boot tells us whether the delegate's fallback to direct ioctls is
 * a dlopen failure or a choice inside the delegate.
 *
 * Built as a shared object and LD_PRELOADed into any chroot binary:
 *   LD_PRELOAD=/root/dlopenprobe.so chroot $R /system/bin/sh -c true
 * Freestanding: raw write(2), dlopen through the loader's own symbols, so it
 * needs no crt and no libc at link time.
 */

extern void *dlopen(const char *name, int flags);
extern char *dlerror(void);
extern int dlsym(void *, const char *);

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

static void out_c(char c)
{
	sys_write(2, &c, 1);
}

static const char *const libs[] = {
	"/vendor/lib64/libedgetpu_client.google.so",
	"/vendor/lib64/libedgetpu_tachyon.google.so",
	"/vendor/lib64/libtachyon_core.so",
	"/vendor/lib64/com.google.edgetpu.tachyon-ndk.so",
	"/vendor/lib64/com.google.edgetpu_vendor_service-V2-ndk.so",
};

__attribute__((constructor)) static void probe(void)
{
	unsigned long i;

	for (i = 0; i < sizeof(libs) / sizeof(libs[0]); i++) {
		void *h = dlopen(libs[i], 2 /* RTLD_NOW */);

		out("PROBE ");
		out(libs[i]);
		if (h) {
			out(" OK\n");
		} else {
			const char *e = dlerror();

			out(" FAIL: ");
			out(e ? e : "(no message)");
			out_c('\n');
		}
	}
}
