// SPDX-License-Identifier: MIT
// tpu-hal-harness: call the DBA HAL's function table in-process, with no
// binder, no servicemanager and no AIDL.
//
// The DBA service is the reference client (TPU-PLAN Appendix B): it calls
// GetDarwinnHalFunctions, checks the version word, calls entry +8 (init), then
// entry +16 with (const DarwinnHalOptions*, DarwinnHal**, callback, context).
// This harness replays that sequence from inside the vendor chroot, one step
// per MODE, so a bad call costs one process.
//
// Build as a preloaded object (no crt in this toolchain):
//   clang --target=aarch64-linux-android30 -DPROBE_AS_SO -shared -fPIC \
//         -nostdlib -o out/tpu-client/libhalharness.so tools/tpu-hal-harness.c
// Run:
//   MODE=census|create|entry ENTRY=n LD_PRELOAD=/system/lib64/libhalharness.so
//     chroot $R /vendor/bin/edgetpu-run
#include <stddef.h>

typedef unsigned long size_t;

extern long write(int, const void *, size_t);
extern void *dlopen(const char *, int);
extern void *dlsym(void *, const char *);
extern char *getenv(const char *);
extern int open(const char *, int, ...);
extern long read(int, void *, size_t);
extern int fork(void);
extern int waitpid(int, int *, int);
extern unsigned int alarm(unsigned int);
extern void _exit(int) __attribute__((noreturn));

#define RTLD_NOW 2
#define RTLD_GLOBAL 0x100

static void put(const char *s) {
  size_t n = 0;

  if (!s) s = "(null)";
  while (s[n]) n++;
  write(2, s, n);
}

static void puthex(unsigned long v) {
  char b[18];
  int i = 17;

  b[i--] = 0;
  do {
    b[i--] = "0123456789abcdef"[v & 0xf];
    v >>= 4;
  } while (v);
  b[i--] = 'x';
  b[i--] = '0';
  put(&b[i + 1]);
}

static void putdec(long v) {
  char b[24];
  int i = 23, neg = v < 0;
  unsigned long u = neg ? (unsigned long)-v : (unsigned long)v;

  b[i--] = 0;
  do {
    b[i--] = '0' + (char)(u % 10);
    u /= 10;
  } while (u);
  if (neg) b[i--] = '-';
  put(&b[i + 1]);
}

/* A preloaded constructor can run before the loader hands bionic its
   environment, and bionic does not export __environ to a namespace, so a
   one-word file is the channel that always works. */
static char fbuf[256];

static const char *fileget(const char *path) {
  long n;
  int fd = open(path, 0);

  if (fd < 0) return 0;
  n = read(fd, fbuf, sizeof(fbuf) - 1);
  if (n <= 0) return 0;
  fbuf[n] = 0;
  while (n > 0 && (fbuf[n - 1] == '\n' || fbuf[n - 1] == '\r' ||
                   fbuf[n - 1] == ' '))
    fbuf[--n] = 0;
  return fbuf;
}

static const char *envget(const char *name) {
  const char *v = fileget(name[0] == 'M' ? "/tmp/tpu-mode" : "/tmp/tpu-entry");

  return v ? v : getenv(name);
}

static void eq(const char *k, const char *v) {
  put(k);
  put("=");
  put(v ? v : "(unset)");
  put(" ");
}

typedef int (*fn4)(void *, void **, void *, void *);
typedef int (*fn0)(void);

static unsigned long *table(void) {
  void *h = dlopen("/vendor/lib64/libdarwinn_dba_hal_runtime.so",
                   RTLD_NOW | RTLD_GLOBAL);
  void *(*get)(void);

  if (!h) {
    put("dlopen failed\n");
    return 0;
  }
  get = (void *(*)(void))dlsym(h, "GetDarwinnHalFunctions");
  if (!get) {
    put("no GetDarwinnHalFunctions\n");
    return 0;
  }
  return (unsigned long *)get();
}

/* The factory (word 2) takes a 16-byte options object, per the service's own
   call site; 64 bytes leaves room to grow it without a rebuild. */
static int call_create(unsigned long *t, unsigned long *out) {
  unsigned char opts[64];
  int i;

  for (i = 0; i < (int)sizeof(opts); i++) opts[i] = 0;
  *out = 0;
  return ((fn4)t[2])(opts, (void **)out, 0, 0);
}

int main(int argc, char **argv) { (void)argc; (void)argv; return 0; }

__attribute__((constructor)) static void start(void) {
  const char *mode = envget("MODE");
  unsigned long *t = table();
  int pid, st, rc;
  unsigned long out = 0;
  int n = 1;

  if (!t) {
    put("no table\n");
    _exit(1);
  }
  put("tpu-hal-harness ");
  eq("MODE", mode ? mode : "census");
  eq("env", getenv("MODEL") ? "yes" : "no");
  put("\n");
  put("version=");
  putdec((long)t[0]);
  put("\n");

  if (!mode || (mode[0] == 'c' && mode[1] == 'e' && mode[2] == 'n')) {
    /* census: entry +8 is the logging init; it touches no device. Init is
       one-shot (init_google.cc:641), so this branch must not fall through. */
    rc = ((fn0)t[1])();
    put("init(entry 1) rc=");
    putdec(rc);
    put("\n");
    _exit(0);
  }

  if (mode[0] == 'c') {
    n = 2;
  } else if (mode[0] == 'e') {
    const char *es = envget("ENTRY");

    n = 2;
    while (*es && (*es >= '0' && *es <= '9')) n = n * 10 + (*es++ - '0');
  }

  pid = fork();
  if (pid == 0) {
    alarm(3);
    put("calling entry ");
    putdec(n);
    put(" with zeroed options\n");
    if (n == 2) {
      rc = call_create(t, &out);
    } else {
      unsigned char opts[64];
      int i;

      for (i = 0; i < (int)sizeof(opts); i++) opts[i] = 0;
      rc = ((fn4)t[n])(opts, (void **)&out, 0, 0);
    }
    put("entry ");
    putdec(n);
    put(" rc=");
    putdec(rc);
    put(" out=");
    puthex(out);
    put("\n");
    _exit(0);
  }
  st = 0;
  waitpid(pid, &st, 0);
  put("child status=");
  putdec(st);
  put(" signal=");
  putdec(st & 0x7f);
  put(" exit=");
  putdec((st >> 8) & 0xff);
  put("\n");
  _exit(0);
}
