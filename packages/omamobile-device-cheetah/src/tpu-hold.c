// SPDX-License-Identifier: MIT
// Hold the Edge TPU driver wakelock across the vendor HAL's detachable probe.
//
// The HAL enumerates the device by creating a group with the detachable flag
// and no wakelock; the driver then powers the TPU down at finalize. The next
// group's power-up is the second of the boot, and on this port it wedges the
// PSM (PSM0_STATUS=0x5644c13, LPM_CONTROL=0x1240). Taking the wakelock first
// makes the first power-up the only one: the HAL's probe and the delegate's
// group both reuse the powered device.
//
// Freestanding aarch64: raw openat/ioctl/nanosleep syscalls, no libc, so it
// runs on the Arch userspace outside the vendor chroot.
#if !defined(__aarch64__)
/* aarch64-only at runtime. The package's tests compile its tools on the build
 * host, where this file still has to compile, so elsewhere it is empty. */
int main(void)
{
	return 0;
}
#else

typedef unsigned long u64;

static long sc(long n, long a, long b, long c, long d, long e, long f)
{
	register long x0 asm("x0") = a;
	register long x1 asm("x1") = b;
	register long x2 asm("x2") = c;
	register long x3 asm("x3") = d;
	register long x4 asm("x4") = e;
	register long x5 asm("x5") = f;
	register long x8 asm("x8") = n;

	asm volatile("svc #0"
		     : "+r"(x0)
		     : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x8)
		     : "memory");
	return x0;
}

static void put(const char *s)
{
	const char *p = s;
	u64 n = 0;

	while (p[n])
		n++;
	sc(64, 2, (long)p, (long)n, 0, 0, 0); /* write */
}

static void putdec(long v)
{
	char buf[24];
	int i = 0;
	int neg = v < 0;

	if (neg)
		v = -v;
	do {
		buf[i++] = (char)('0' + v % 10);
		v /= 10;
	} while (v && i < 20);
	if (neg)
		buf[i++] = '-';
	while (i > 0) {
		char c = buf[--i];

		sc(64, 2, (long)&c, 1, 0, 0, 0); /* write */
	}
}

__attribute__((noreturn)) void _start(void)
{
	struct {
		long sec;
		long nsec;
	} ts = {3600, 0};
	long fd = sc(56, -100, (long)"/dev/edgetpu", 2, 0, 0, 0); /* openat */
	long r;

	put("tpu-hold: fd ");
	putdec(fd);
	put("\n");
	if (fd >= 0) {
		/* EDGETPU_ACQUIRE_WAKE_LOCK = _IO(0xED, 26) = 0xed1a */
		r = sc(29, fd, 0xed1a, 0, 0, 0, 0);
		put("tpu-hold: wakelock -> ");
		putdec(r);
		put("\n");
	} else {
		put("tpu-hold: open failed\n");
	}
	for (;;)
		sc(101, (long)&ts, 0, 0, 0, 0, 0); /* nanosleep */
}

#endif /* __aarch64__ */
