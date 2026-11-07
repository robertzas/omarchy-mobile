// SPDX-License-Identifier: MIT
// Name a vendor binary's LOG(FATAL) when gdb cannot unwind bionic.
//
// libbase's DefaultAborter() calls android_set_abort_message() with the
// formatted message and then abort(). gdb follows the exec but its backtrace
// stops at a corrupt frame ("previous frame identical ... corrupt stack?"),
// and the message itself only reaches the crash reporter. Interposing the
// setter prints it, which is how servicemanager's
// "Check failed: selinux_status_open(true) >= 0" and "Did not get context from
// PID N" were read (TPU-PLAN U36/U37).
//
// Build: clang --target=aarch64-linux-android30 -shared -fPIC -nostdlib \
//          -fno-stack-protector -o libabortshim.so android-abort-msg.c
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

static void put(const char *s, u64 n)
{
	sc3(64 /* write */, 2, (long)s, (long)n);
}

static void puts_(const char *s)
{
	u64 n = 0;

	while (s[n])
		n++;
	put(s, n);
}

void android_set_abort_message(const char *msg)
{
	puts_("ABORT-MSG ");
	puts_(msg ? msg : "(null)");
	puts_("\n");
}

// Do not let the abort take the process down before the message is flushed.
void abort(void)
{
	puts_("ABORT-SHIM called\n");
	sc3(94 /* exit_group */, 134, 0, 0);
	for (;;)
		;
}
