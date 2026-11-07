/*
 * android-stackchk.c: an LD_PRELOAD shim for the vendor Edge TPU delegate.
 *
 * The delegate aborts with "stack corruption detected (-fstack-protector)" a
 * tenth of a second after OPEN_DEVICE. gdb follows the exec but cannot load
 * bionic's symbols, so its backtrace names nothing. This shim takes the abort
 * over before libc's handler runs: it prints the return address (the address
 * inside the function whose canary fired) and the process's maps, so the
 * address can be turned into a file offset and symbolized on the laptop.
 *
 * Freestanding: raw syscalls, no libc, so it cannot recurse into the failing
 * path. Build: clang --target=aarch64-linux-android30 -shared -fPIC -nostdlib
 */

typedef unsigned long u64;

static long sc3(long n, long a, long b, long c)
{
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
	return x0;
}

static long sc1(long n, long a)
{
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8) : "memory");
	return x0;
}

static void put(const char *s, u64 len)
{
	sc3(64 /* write */, 2, (long)s, (long)len);
}

static void puts_(const char *s)
{
	u64 n = 0;

	while (s[n])
		n++;
	put(s, n);
}

static void puthex(u64 v)
{
	char b[19];
	int i;

	b[0] = '0';
	b[1] = 'x';
	for (i = 17; i >= 2; i--) {
		unsigned d = v & 0xf;

		b[i] = d < 10 ? '0' + d : 'a' + d - 10;
		v >>= 4;
	}
	put(b, sizeof(b));
}

static u64 strlen_(const char *s)
{
	u64 n = 0;

	while (s[n])
		n++;
	return n;
}

static int has(const char *hay, u64 hn, const char *needle)
{
	u64 nn = strlen_(needle);
	u64 i, j;

	if (nn > hn)
		return 0;
	for (i = 0; i + nn <= hn; i++) {
		for (j = 0; j < nn; j++)
			if (hay[i + j] != needle[j])
				break;
		if (j == nn)
			return 1;
	}
	return 0;
}

/* Print /proc/self/maps, keeping only the executable's own regions, so the
 * log stays small but still carries the load base of the delegate. */
static void dump_maps(void)
{
	static char buf[16384];
	long fd, n;

	fd = sc3(56 /* openat */, -100 /* AT_FDCWD */,
		 (long)"/proc/self/maps", 0 /* O_RDONLY */);
	if (fd < 0) {
		puts_("STACKCHK maps: openat failed errno=");
		puthex((u64)-fd);
		puts_("\n");
		return;
	}
	while ((n = sc3(63 /* read */, fd, (long)buf, sizeof(buf) - 1)) > 0) {
		long off = 0, i;

		buf[n] = 0;
		for (i = 0; i < n; i++) {
			if (buf[i] == '\n') {
				put(buf + off, i - off + 1);
				off = i + 1;
			}
		}
	}
	sc1(57 /* close */, fd);
}

void __stack_chk_fail(void)
{
	u64 lr = (u64)__builtin_return_address(0);

	puts_("\nSTACKCHK lr=");
	puthex(lr);
	puts_("\nSTACKCHK maps:\n");
	dump_maps();
	puts_("STACKCHK end\n");
	sc1(94 /* exit_group */, 134);
	for (;;)
		;
}

void __stack_chk_fail_local(void)
{
	__stack_chk_fail();
}
