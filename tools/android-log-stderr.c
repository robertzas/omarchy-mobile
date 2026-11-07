// SPDX-License-Identifier: MIT
// Make an Android binary's liblog messages visible on a Linux userspace where
// logd does not exist. LD_PRELOAD this and the LOG(FATAL) reason that only
// went to /dev/socket/logdw now reaches stderr.
//
// Freestanding: no libc, write(2) through a raw syscall, so it loads into a
// bionic process from any chroot without a matching libc.
#include <stdarg.h>

static long sys_write(int fd, const void *buf, unsigned long len)
{
	register long x0 asm("x0") = fd;
	register const void *x1 asm("x1") = buf;
	register unsigned long x2 asm("x2") = len;
	register long x8 asm("x8") = 64; /* __NR_write */

	asm volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
	return x0;
}

static unsigned long str_len(const char *s)
{
	unsigned long n = 0;

	while (s[n])
		n++;
	return n;
}

static void emit(const char *s)
{
	sys_write(2, s, str_len(s));
	sys_write(2, "\n", 1);
}

static void emit_tagged(const char *tag, const char *text)
{
	char buf[1024];
	int n = 0;
	int i;

	if (tag) {
		buf[n++] = '[';
		for (i = 0; tag[i] && n < 900; i++)
			buf[n++] = tag[i];
		buf[n++] = ']';
		buf[n++] = ' ';
	}
	for (i = 0; text && text[i] && n < 1000; i++)
		buf[n++] = text[i];
	buf[n] = 0;
	emit(buf);
}

// Minimal formatter: %s, %d, %u, %x and %% only. Enough for log lines.
static void vemit(const char *tag, const char *fmt, va_list ap)
{
	char buf[1024];
	int n = 0;
	int i;

	if (tag) {
		buf[n++] = '[';
		for (i = 0; tag[i] && n < 900; i++)
			buf[n++] = tag[i];
		buf[n++] = ']';
		buf[n++] = ' ';
	}
	for (i = 0; fmt && fmt[i] && n < 1000; i++) {
		if (fmt[i] != '%') {
			buf[n++] = fmt[i];
			continue;
		}
		i++;
		if (fmt[i] == 's') {
			const char *s = va_arg(ap, const char *);
			while (s && *s && n < 1000)
				buf[n++] = *s++;
		} else if (fmt[i] == 'd' || fmt[i] == 'u' || fmt[i] == 'x') {
			unsigned long v = va_arg(ap, unsigned long);
			char tmp[24];
			int k = 0, base = (fmt[i] == 'x') ? 16 : 10;
			int neg = (fmt[i] == 'd' && (long)v < 0);

			if (neg)
				v = -(long)v;
			do {
				tmp[k++] = "0123456789abcdef"[v % base];
				v /= base;
			} while (v && k < 20);
			if (neg)
				buf[n++] = '-';
			while (k > 0 && n < 1000)
				buf[n++] = tmp[--k];
		} else if (fmt[i] == '%') {
			buf[n++] = '%';
		}
	}
	buf[n] = 0;
	emit(buf);
}

__attribute__((constructor)) static void shim_loaded(void)
{
	emit("SHIM-LOADED");
}

int __android_log_print(int prio, const char *tag, const char *fmt, ...)
{
	va_list ap;

	(void)prio;
	va_start(ap, fmt);
	vemit(tag, fmt, ap);
	va_end(ap);
	return 0;
}

int __android_log_vprint(int prio, const char *tag, const char *fmt, va_list ap)
{
	(void)prio;
	vemit(tag, fmt, ap);
	return 0;
}

int __android_log_write(int prio, const char *tag, const char *text)
{
	(void)prio;
	emit_tagged(tag, text);
	return 0;
}

int __android_log_buf_write(int buf, int prio, const char *tag, const char *text)
{
	(void)buf;
	(void)prio;
	emit_tagged(tag, text);
	return 0;
}

void __android_log_assert(const char *cond, const char *tag, const char *fmt, ...)
{
	va_list ap;

	emit_tagged(tag, cond ? cond : "assert");
	va_start(ap, fmt);
	vemit(tag, fmt, ap);
	va_end(ap);
	__builtin_trap();
}
