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

// The rest of liblog's API, so this file can stand in for liblog.so itself.
// A preloaded shim cannot intercept liblog's internal hidden-alias calls, and
// one of them (the tag/property path) was the frame whose canary fired; with
// this file installed as liblog.so every call reaches us.
struct android_log_message {
	unsigned long struct_size;
	int buffer_id;
	int priority;
	const char *tag;
	const char *file;
	unsigned line;
	const char *message;
};

typedef int (*android_log_logger)(const struct android_log_message *);
typedef void (*android_log_aborter)(const char *);

static android_log_logger g_logger;
static android_log_aborter g_aborter;
static const char *g_default_tag = "";
static int g_min_prio;

int __android_log_logd_logger(const struct android_log_message *m)
{
	if (!m)
		return 0;
	emit_tagged(m->tag ? m->tag : g_default_tag, m->message ? m->message : "");
	return 0;
}

void __android_log_set_logger(android_log_logger logger)
{
	g_logger = logger;
}

void __android_log_set_default_tag(const char *tag)
{
	g_default_tag = tag ? tag : "";
}

void __android_log_set_aborter(android_log_aborter aborter)
{
	g_aborter = aborter;
}

void __android_log_call_aborter(const char *msg)
{
	if (g_aborter)
		g_aborter(msg ? msg : "abort");
	__builtin_trap();
}

int __android_log_set_minimum_priority(int prio)
{
	g_min_prio = prio;
	return 0;
}

int __android_log_get_minimum_priority(void)
{
	return g_min_prio;
}

int __android_log_write_log_message(const struct android_log_message *m)
{
	if (g_logger)
		return g_logger(m);
	return __android_log_logd_logger(m);
}

int __android_log_buf_print(int buf, int prio, const char *tag, const char *fmt, ...)
{
	va_list ap;

	(void)buf;
	(void)prio;
	va_start(ap, fmt);
	vemit(tag, fmt, ap);
	va_end(ap);
	return 0;
}

int __android_log_bswrite(int prio, const char *text)
{
	(void)prio;
	emit_tagged(0, text);
	return 0;
}

int __android_log_btwrite(int tag, int prio, const void *buf, unsigned long len)
{
	(void)tag;
	(void)prio;
	(void)buf;
	(void)len;
	return 0;
}

int __android_log_error_write(int tag, const char *sub_tag, int uid, const char *msg, unsigned len)
{
	(void)tag;
	(void)uid;
	(void)len;
	emit_tagged(sub_tag, msg);
	return 0;
}

int __android_log_is_loggable(int prio, const char *tag, int def)
{
	(void)prio;
	(void)tag;
	return def ? def : 1;
}

int __android_log_is_loggable_len(int prio, const char *tag, unsigned long len, int def)
{
	(void)prio;
	(void)tag;
	(void)len;
	return def ? def : 1;
}

int __android_log_security(void)
{
	return 0;
}

void __android_log_close(void)
{
}
