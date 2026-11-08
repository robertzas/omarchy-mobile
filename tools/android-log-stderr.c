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

static void put_hex(char *buf, int *n, unsigned long v, int prefix)
{
	char tmp[24];
	int k = 0;

	if (prefix && *n < 998) {
		buf[(*n)++] = '0';
		buf[(*n)++] = 'x';
	}
	do {
		tmp[k++] = "0123456789abcdef"[v & 15];
		v >>= 4;
	} while (v && k < 20);
	while (k > 0 && *n < 1000)
		buf[(*n)++] = tmp[--k];
}

static void put_dec(char *buf, int *n, unsigned long v, int base)
{
	char tmp[24];
	int k = 0;

	do {
		tmp[k++] = "0123456789abcdef"[v % base];
		v /= base;
	} while (v && k < 20);
	while (k > 0 && *n < 1000)
		buf[(*n)++] = tmp[--k];
}

// Formatter for log lines. It is not libc's printf: it consumes every
// conversion's argument, including %p, length modifiers and * width/precision,
// so a format the shim does not print cannot misalign the va_list and turn a
// later %s into a wild pointer (the tachyon service crashed exactly that way).
static void vemit(const char *tag, const char *fmt, va_list ap)
{
	char buf[1024];
	int n = 0;
	int i = 0;

	if (tag) {
		buf[n++] = '[';
		for (i = 0; tag[i] && n < 900; i++)
			buf[n++] = tag[i];
		buf[n++] = ']';
		buf[n++] = ' ';
	}
	i = 0;
	while (fmt && fmt[i] && n < 1000) {
		char conv;
		int lmod = 0;

		if (fmt[i] != '%') {
			buf[n++] = fmt[i++];
			continue;
		}
		i++;
		if (fmt[i] == '%') {
			buf[n++] = '%';
			i++;
			continue;
		}
		while (fmt[i] == '-' || fmt[i] == '+' || fmt[i] == ' ' ||
		       fmt[i] == '#' || fmt[i] == '0')
			i++;
		if (fmt[i] == '*') {
			(void)va_arg(ap, int);
			i++;
		} else {
			while (fmt[i] >= '0' && fmt[i] <= '9')
				i++;
		}
		if (fmt[i] == '.') {
			i++;
			if (fmt[i] == '*') {
				(void)va_arg(ap, int);
				i++;
			} else {
				while (fmt[i] >= '0' && fmt[i] <= '9')
					i++;
			}
		}
		for (;;) {
			if (fmt[i] == 'l' && fmt[i + 1] == 'l') {
				lmod = 2;
				i += 2;
			} else if (fmt[i] == 'l' || fmt[i] == 'z' ||
				   fmt[i] == 'j' || fmt[i] == 't') {
				lmod = 1;
				i++;
			} else if (fmt[i] == 'h') {
				lmod = 1;
				i++;
				if (fmt[i] == 'h')
					i++;
			} else {
				break;
			}
		}
		conv = fmt[i];
		if (!conv)
			break;
		i++;
		if (conv == 's') {
			const char *s = va_arg(ap, const char *);

			while (s && *s && n < 1000)
				buf[n++] = *s++;
		} else if (conv == 'c') {
			int v = va_arg(ap, int);

			if (n < 1000)
				buf[n++] = (char)v;
		} else if (conv == 'd' || conv == 'i') {
			long v = va_arg(ap, long);

			if (v < 0) {
				if (n < 1000)
					buf[n++] = '-';
				put_dec(buf, &n, (unsigned long)-v, 10);
			} else {
				put_dec(buf, &n, (unsigned long)v, 10);
			}
		} else if (conv == 'u' || conv == 'x' || conv == 'X' ||
			   conv == 'o') {
			unsigned long v = va_arg(ap, unsigned long);

			put_dec(buf, &n, v, (conv == 'o') ? 8 :
				(conv == 'u' ? 10 : 16));
		} else if (conv == 'p') {
			put_hex(buf, &n, (unsigned long)va_arg(ap, void *), 1);
		} else if (conv == 'f' || conv == 'e' || conv == 'g' ||
			   conv == 'a' || conv == 'A' || conv == 'E' ||
			   conv == 'F' || conv == 'G') {
			(void)va_arg(ap, double);
			if (n < 1000)
				buf[n++] = '?';
		} else {
			// Unknown conversion: keep the character, consume no argument
			// (the format is already beyond what the shim understands).
			(void)lmod;
			if (n < 1000)
				buf[n++] = conv;
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
	// No trap: a vendor HAL's fatal check is often the state a bring-up needs
	// to look past, and the stock liblog's abort would take the process (and
	// any service it already published) down. Log it and let the caller go on.
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
	emit_tagged(0, msg ? msg : "abort");
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
