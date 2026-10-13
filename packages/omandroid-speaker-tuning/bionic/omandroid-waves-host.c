// SPDX-License-Identifier: MIT
/*
 * omandroid-waves-host: drive Waves' speaker tuning controller
 * (libmahalcontroller.so, from the user's own vendor image) from line
 * commands, and hand every buffer it wants to send to the AoC to our
 * daemon instead. It never touches the AoC itself: it runs in the "waves"
 * vendor chroot, which has no device nodes besides null, zero and urandom.
 * device/cheetah/AOC-TUNING-RESEARCH.md, section 2.7 (the API) and 3.1.
 *
 * Nothing of Google's or Waves' is linked at build time: the controller is
 * dlopen()ed at run time and every entry point is looked up by name.
 *
 * Protocol (text lines; stdin is ours, stdout is the daemon's):
 *   daemon -> host  commands, one per line:
 *     version NAME             ma_get_version(NAME), e.g. "dsp"
 *     begin                    ma_wait_for_flush (stock calls it before a batch)
 *     wake                     ma_on_dsp_wakeup (first batch, after an AoC restart)
 *     bypass 0|1               ma_set_data type 6 (u8)
 *     volume V                 ma_set_data type 0 (double, 0..1)
 *     orientation 0|90|180|270 ma_set_data type 1 (u32 degrees)
 *     route DEV MODE THROTTLE  ma_set_data type 258 (u32[3]: custom action
 *                              258, audio_devices_t, audio_mode_t,
 *                              throttle state 0 enabled/1 disabled/2 bypassed)
 *     flush                    ma_flush (sends the batch)
 *     quit
 *   host -> daemon  answers: "ok CMD", "fail CMD REASON", "version NAME TEXT",
 *     "ready INSTANCE" once the controller is initialised, and for every
 *     buffer the controller sends:
 *     send INSTANCE LEN HEX    then blocks until the daemon answers on stdin:
 *   daemon -> host  "reply RC HEX" or "reply RC -" (RC: the AoC's return
 *     code, 0 or a negative errno; HEX: the bulk reply payload, if any).
 *
 * Waves' libraries write to stdout too, so the protocol uses a private copy
 * of fd 1 and fd 1 itself goes to stderr. liblog's __android_log_* calls
 * bind to the copies below (this executable is first in the global lookup
 * group) and go to stderr, filtered by OMANDROID_WAVES_LOGLEVEL (Android
 * priorities: 3 debug .. 6 error; default 5).
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MAX_PAYLOAD	16384	/* the AoC's output bulk buffer */
#define MAX_LINE	(2 * MAX_PAYLOAD + 64)
#define VERSION_LEN	256	/* what stock passes to ma_get_version */
#define QUEUE_LEN	16

/* ma_set_data types (audio_waves_aoc.so's calls, AOC-TUNING-RESEARCH 2.7) */
#define MA_DATA_VOLUME		0
#define MA_DATA_ORIENTATION	1
#define MA_DATA_BYPASS		6
#define MA_DATA_ACTION_258	258

typedef int (*ma_sender_t)(uint64_t handle, uint32_t instance,
			   const void *buf, uint32_t len, void *reply,
			   uint32_t *reply_len, void *user);

static struct {
	bool (*create)(uint64_t *handle, void *user);
	bool (*destroy)(uint64_t *handle);
	bool (*initialize)(uint64_t handle, const char *mps, const char *extra,
			   const char *ini, ma_sender_t sender);
	bool (*get_version)(uint64_t handle, uint32_t instance, const char *name,
			    char *out, uint32_t size);
	bool (*wait_for_flush)(uint64_t handle, uint32_t instance);
	bool (*flush)(uint64_t handle, uint32_t instance);
	bool (*on_dsp_wakeup)(uint64_t handle, uint32_t instance);
	bool (*set_data)(uint64_t handle, uint32_t instance, uint32_t type,
			 const void *data, uint32_t size);
} ma;

static int out_fd = -1;			/* the daemon's end (a copy of fd 1) */
static int log_level = 5;
static long reply_timeout_ms = 10000;
static uint32_t instance = 1;

static pthread_mutex_t out_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t send_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t in_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t in_cond = PTHREAD_COND_INITIALIZER;

/* filled by the stdin reader, under in_lock */
static char *queue[QUEUE_LEN];
static int q_head, q_count;
static char *reply_line;
static bool want_reply, in_eof;

static void say(int prio, const char *fmt, ...)
	__attribute__((format(printf, 2, 3)));

static void say(int prio, const char *fmt, ...)
{
	va_list ap;

	if (prio < log_level)
		return;
	va_start(ap, fmt);
	fputs("omandroid-waves-host: ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}

/* liblog, to stderr (see the header comment) */
__attribute__((visibility("default"), format(printf, 3, 0)))
int __android_log_vprint(int prio, const char *tag, const char *fmt, va_list ap);

__attribute__((visibility("default"), format(printf, 3, 4)))
int __android_log_print(int prio, const char *tag, const char *fmt, ...);

__attribute__((visibility("default"), format(printf, 4, 5)))
int __android_log_buf_print(int buf, int prio, const char *tag, const char *fmt, ...);

int __android_log_vprint(int prio, const char *tag, const char *fmt, va_list ap)
{
	if (prio < log_level)
		return 0;
	fprintf(stderr, "[%s] ", tag ? tag : "?");
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	return 1;
}

int __android_log_print(int prio, const char *tag, const char *fmt, ...)
{
	va_list ap;
	int r;

	va_start(ap, fmt);
	r = __android_log_vprint(prio, tag, fmt, ap);
	va_end(ap);
	return r;
}

__attribute__((visibility("default")))
int __android_log_write(int prio, const char *tag, const char *text)
{
	return __android_log_print(prio, tag, "%s", text ? text : "");
}

__attribute__((visibility("default")))
int __android_log_buf_write(int buf, int prio, const char *tag, const char *text)
{
	(void)buf;
	return __android_log_write(prio, tag, text);
}

int __android_log_buf_print(int buf, int prio, const char *tag, const char *fmt, ...)
{
	va_list ap;
	int r;

	(void)buf;
	va_start(ap, fmt);
	r = __android_log_vprint(prio, tag, fmt, ap);
	va_end(ap);
	return r;
}

static int write_all(int fd, const char *p, size_t n)
{
	while (n) {
		ssize_t w = write(fd, p, n);

		if (w < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		p += w;
		n -= (size_t)w;
	}
	return 0;
}

static void emit(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

static void emit(const char *fmt, ...)
{
	char line[512];
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(line, sizeof(line) - 1, fmt, ap);
	va_end(ap);
	if (n < 0)
		return;
	if ((size_t)n > sizeof(line) - 2)
		n = sizeof(line) - 2;
	line[n++] = '\n';
	pthread_mutex_lock(&out_lock);
	if (write_all(out_fd, line, (size_t)n))
		say(6, "stdout: %s", strerror(errno));
	pthread_mutex_unlock(&out_lock);
}

static int hexval(char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

/* Decode HEX into out (at most cap bytes); -1 on bad input. */
static long unhex(const char *hex, uint8_t *out, size_t cap)
{
	size_t n = strlen(hex), i;

	if (n % 2 || n / 2 > cap)
		return -1;
	for (i = 0; i < n / 2; i++) {
		int hi = hexval(hex[2 * i]), lo = hexval(hex[2 * i + 1]);

		if (hi < 0 || lo < 0)
			return -1;
		out[i] = (uint8_t)(hi << 4 | lo);
	}
	return (long)(n / 2);
}

/* stdin: replies go to the waiting sender, everything else is a command */
static void *reader(void *arg)
{
	char *line = malloc(MAX_LINE + 2);
	size_t len = 0;

	(void)arg;
	if (!line)
		abort();
	for (;;) {
		int c = getchar();

		if (c == EOF)
			break;
		if (c != '\n') {
			if (len < MAX_LINE + 1)
				line[len++] = (char)c;
			continue;
		}
		if (len > MAX_LINE) {
			say(6, "input line too long, dropped");
			len = 0;
			continue;
		}
		line[len] = '\0';
		len = 0;
		pthread_mutex_lock(&in_lock);
		if (!strncmp(line, "reply ", 6)) {
			if (want_reply && !reply_line)
				reply_line = strdup(line + 6);
			else
				say(5, "unexpected reply, dropped");
		} else if (q_count < QUEUE_LEN) {
			queue[(q_head + q_count++) % QUEUE_LEN] = strdup(line);
		} else {
			say(6, "command queue full, dropped");
		}
		pthread_cond_broadcast(&in_cond);
		pthread_mutex_unlock(&in_lock);
	}
	pthread_mutex_lock(&in_lock);
	in_eof = true;
	pthread_cond_broadcast(&in_cond);
	pthread_mutex_unlock(&in_lock);
	free(line);
	return NULL;
}

/*
 * The controller's buffer sender: one exchange with the AoC, done by the
 * daemon. Returns 0 on success (the controller treats anything else as a
 * failure), the AoC's or the daemon's negative errno otherwise.
 */
static int sender(uint64_t handle, uint32_t inst, const void *buf, uint32_t len,
		  void *reply, uint32_t *reply_len, void *user)
{
	static const char digits[] = "0123456789abcdef";
	const uint8_t *p = buf;
	struct timespec dl;
	char *line, *rep = NULL, *end;
	size_t n = 0, i;
	long rc;
	int err;

	(void)handle;
	(void)user;
	if (!buf || !len || len > MAX_PAYLOAD) {
		say(6, "refusing a %u-byte buffer", len);
		return -EINVAL;
	}
	line = malloc(2 * (size_t)len + 64);
	if (!line)
		return -ENOMEM;
	pthread_mutex_lock(&send_lock);
	n = (size_t)snprintf(line, 64, "send %u %u ", inst, len);
	for (i = 0; i < len; i++) {
		line[n++] = digits[p[i] >> 4];
		line[n++] = digits[p[i] & 15];
	}
	line[n++] = '\n';

	pthread_mutex_lock(&in_lock);
	want_reply = true;
	free(reply_line);
	reply_line = NULL;
	pthread_mutex_unlock(&in_lock);

	pthread_mutex_lock(&out_lock);
	err = write_all(out_fd, line, n);
	pthread_mutex_unlock(&out_lock);
	free(line);

	clock_gettime(CLOCK_REALTIME, &dl);
	dl.tv_sec += reply_timeout_ms / 1000;
	dl.tv_nsec += (reply_timeout_ms % 1000) * 1000000L;
	if (dl.tv_nsec >= 1000000000L) {
		dl.tv_sec++;
		dl.tv_nsec -= 1000000000L;
	}
	pthread_mutex_lock(&in_lock);
	while (!err && !reply_line && !in_eof)
		if (pthread_cond_timedwait(&in_cond, &in_lock, &dl) == ETIMEDOUT)
			break;
	rep = reply_line;
	reply_line = NULL;
	want_reply = false;
	pthread_mutex_unlock(&in_lock);
	pthread_mutex_unlock(&send_lock);

	if (err) {
		say(6, "send: %s", strerror(errno));
		return -EPIPE;
	}
	if (!rep) {
		say(5, "no reply from the daemon");
		return -ETIMEDOUT;
	}
	errno = 0;
	rc = strtol(rep, &end, 10);
	if (errno || end == rep || *end != ' ' || rc > 0 || rc < -4095) {
		say(6, "bad reply line");
		free(rep);
		return -EPROTO;
	}
	end++;
	if (rc == 0 && strcmp(end, "-")) {
		uint8_t *data = malloc(MAX_PAYLOAD);
		long got = data ? unhex(end, data, MAX_PAYLOAD) : -1;

		if (got < 0) {
			say(6, "bad reply payload");
			rc = -EPROTO;
		} else if (reply && reply_len && *reply_len >= (uint32_t)got) {
			/* as stock: copy only when it fits */
			memcpy(reply, data, (size_t)got);
			*reply_len = (uint32_t)got;
		}
		free(data);
	}
	free(rep);
	return (int)rc;
}

static bool parse_u32(const char *s, uint32_t max, uint32_t *out)
{
	unsigned long v;
	char *end;

	if (!s || !*s)
		return false;
	errno = 0;
	v = strtoul(s, &end, 10);
	if (errno || *end || v > max)
		return false;
	*out = (uint32_t)v;
	return true;
}

/* One command line; answers on stdout. Returns false on "quit". */
static bool command(uint64_t h, char *line)
{
	char *save = NULL, *cmd = strtok_r(line, " ", &save);
	char *a1 = strtok_r(NULL, " ", &save), *a2 = strtok_r(NULL, " ", &save);
	char *a3 = strtok_r(NULL, " ", &save), *extra = strtok_r(NULL, " ", &save);
	bool ok;

	if (!cmd)
		return true;
	if (extra) {
		emit("fail %s arguments", cmd);
		return true;
	}
	if (!strcmp(cmd, "quit")) {
		emit("ok quit");
		return false;
	} else if (!strcmp(cmd, "version")) {
		char v[VERSION_LEN] = "";
		size_t i;

		if (!a1 || a2 || strlen(a1) > 32) {
			emit("fail version arguments");
			return true;
		}
		if (!ma.get_version(h, instance, a1, v, sizeof(v))) {
			emit("fail version %s", a1);
			return true;
		}
		v[sizeof(v) - 1] = '\0';
		for (i = 0; v[i]; i++)
			if (v[i] < 0x20 || v[i] > 0x7e)
				v[i] = '?';
		emit("version %s %s", a1, v[0] ? v : "-");
		return true;
	} else if (!strcmp(cmd, "begin") && !a1) {
		ok = ma.wait_for_flush(h, instance);
	} else if (!strcmp(cmd, "wake") && !a1) {
		ok = ma.on_dsp_wakeup(h, instance);
	} else if (!strcmp(cmd, "flush") && !a1) {
		ok = ma.flush(h, instance);
	} else if (!strcmp(cmd, "bypass") && a1 && !a2) {
		uint32_t v;
		uint8_t b;

		if (!parse_u32(a1, 1, &v)) {
			emit("fail bypass arguments");
			return true;
		}
		b = (uint8_t)v;
		ok = ma.set_data(h, instance, MA_DATA_BYPASS, &b, sizeof(b));
	} else if (!strcmp(cmd, "volume") && a1 && !a2) {
		char *end;
		double v;

		errno = 0;
		v = strtod(a1, &end);
		if (errno || *end || !(v >= 0.0 && v <= 1.0)) {
			emit("fail volume arguments");
			return true;
		}
		ok = ma.set_data(h, instance, MA_DATA_VOLUME, &v, sizeof(v));
	} else if (!strcmp(cmd, "orientation") && a1 && !a2) {
		uint32_t deg;

		if (!parse_u32(a1, 270, &deg) || deg % 90) {
			emit("fail orientation arguments");
			return true;
		}
		ok = ma.set_data(h, instance, MA_DATA_ORIENTATION, &deg, sizeof(deg));
	} else if (!strcmp(cmd, "route") && a3) {
		uint32_t v[3];

		if (!parse_u32(a1, UINT32_MAX, &v[0]) || !parse_u32(a2, 255, &v[1]) ||
		    !parse_u32(a3, 2, &v[2])) {
			emit("fail route arguments");
			return true;
		}
		ok = ma.set_data(h, instance, MA_DATA_ACTION_258, v, sizeof(v));
	} else {
		emit("fail %s unknown", cmd);
		return true;
	}
	if (ok)
		emit("ok %s", cmd);
	else
		emit("fail %s controller", cmd);
	return true;
}

static void *sym(void *lib, const char *name)
{
	void *p = dlsym(lib, name);

	if (!p) {
		emit("fail init %s", name);
		say(6, "%s: %s", name, dlerror());
		_exit(1);
	}
	return p;
}

static void usage(void)
{
	fputs("usage: omandroid-waves-host [--lib SO] [--mps FILE] [--ini FILE] [--instance N] [--timeout-ms MS]\n",
	      stderr);
	exit(2);
}

int main(int argc, char **argv)
{
	const char *lib_path = "/vendor/lib64/libmahalcontroller.so";
	const char *mps = "/vendor/etc/waves_preset.mps";
	const char *ini = "/vendor/etc/waves_config.ini";
	const char *lvl = getenv("OMANDROID_WAVES_LOGLEVEL");
	uint64_t handle = 0;
	pthread_t th;
	void *lib;
	int i;

	for (i = 1; i < argc; i += 2) {
		const char *v = i + 1 < argc ? argv[i + 1] : NULL;

		if (!v)
			usage();
		if (!strcmp(argv[i], "--lib"))
			lib_path = v;
		else if (!strcmp(argv[i], "--mps"))
			mps = v;
		else if (!strcmp(argv[i], "--ini"))
			ini = v;
		else if (!strcmp(argv[i], "--instance")) {
			if (!parse_u32(v, 255, &instance))
				usage();
		} else if (!strcmp(argv[i], "--timeout-ms")) {
			uint32_t t;

			if (!parse_u32(v, 600000, &t) || !t)
				usage();
			reply_timeout_ms = t;
		} else {
			usage();
		}
	}
	if (lvl && *lvl >= '2' && *lvl <= '7' && !lvl[1])
		log_level = *lvl - '0';

	/* our protocol gets a private fd; fd 1 (Waves' printf) goes to stderr */
	out_fd = dup(1);
	if (out_fd < 0 || dup2(2, 1) < 0) {
		perror("omandroid-waves-host: dup");
		return 1;
	}

	if (pthread_create(&th, NULL, reader, NULL)) {
		emit("fail init thread");
		return 1;
	}

	lib = dlopen(lib_path, RTLD_NOW | RTLD_LOCAL);
	if (!lib) {
		emit("fail init dlopen");
		say(6, "%s", dlerror());
		return 1;
	}
	ma.create = sym(lib, "ma_create");
	ma.destroy = sym(lib, "ma_destroy");
	ma.initialize = sym(lib, "ma_initialize");
	ma.get_version = sym(lib, "ma_get_version");
	ma.wait_for_flush = sym(lib, "ma_wait_for_flush");
	ma.flush = sym(lib, "ma_flush");
	ma.on_dsp_wakeup = sym(lib, "ma_on_dsp_wakeup");
	ma.set_data = sym(lib, "ma_set_data");

	/* the user pointer comes back to the sender, which does not need it */
	if (!ma.create(&handle, &instance)) {
		emit("fail init ma_create");
		return 1;
	}
	/* stock passes "" as the third argument */
	if (!ma.initialize(handle, mps, "", ini, sender)) {
		emit("fail init ma_initialize");
		return 1;
	}
	emit("ready %u", instance);

	for (;;) {
		char *line = NULL;
		bool more;

		pthread_mutex_lock(&in_lock);
		while (!q_count && !in_eof)
			pthread_cond_wait(&in_cond, &in_lock);
		if (q_count) {
			line = queue[q_head];
			q_head = (q_head + 1) % QUEUE_LEN;
			q_count--;
		}
		pthread_mutex_unlock(&in_lock);
		if (!line)
			break;
		more = command(handle, line);
		free(line);
		if (!more)
			break;
	}
	/*
	 * No ma_destroy: the controller's worker threads may still be in a
	 * send, and the process ends here anyway.
	 */
	_exit(0);
}
