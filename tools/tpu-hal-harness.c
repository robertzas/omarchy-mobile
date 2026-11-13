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
//   MODE=census|create|create2|opts|entry ENTRY=n LD_PRELOAD=/system/lib64/libhalharness.so
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

static void putb(unsigned char v) {
  const char *h = "0123456789abcdef";
  char b[2];

  b[0] = h[v >> 4];
  b[1] = h[v & 0xf];
  write(2, b, 2);
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

/* The service passes a thunk (0x8d10) as arg 3 and a 0x80-byte object as arg
   4; a zeroed pair faults at 0. A no-op callback and a context with the same
   fields (byte +0x10 = 1, word +0x7c = 2000) keep those two arguments valid
   while the options layout is still unknown. */
static int harness_cb(void *ctx) {
  (void)ctx;
  return 0;
}
typedef int (*fn0)(void);

static const char devpath[] = "/dev/edgetpu";
static unsigned long hal_base;

extern int backtrace(void **, int);
extern void (*signal(int, void (*)(int)))(int);
extern int kill(int, int);
extern int usleep(unsigned int);
extern long ptrace(int, int, void *, void *);
struct iov {
  void *b;
  unsigned long l;
};

extern long process_vm_readv(int, const struct iov *, unsigned long,
                             const struct iov *, unsigned long, unsigned long);
extern int __errno(void);

#define PT_ATTACH 16
#define PT_DETACH 17
#define PT_PEEKDATA 2
#define PT_GETREGSET 0x4204

static unsigned long map_base(const char *needle);

/* The child blocks in a futex, so its kernel stack names only the futex.
   The library keeps x29 frame pointers, so a ptrace walk of the blocked
   thread's user stack names the waiting function. backtrace() deadlocks
   here (U296); ptrace from the parent does not. */
static void dump_child(int pid) {
  unsigned long regs[34], fp, sp, ra, prev;
  struct iov io, rm, lm;
  unsigned long va[2];
  long n;
  int i;

  put("bt hal_base=");
  puthex(hal_base);
  put("\n");
  if (ptrace(PT_ATTACH, pid, 0, 0) < 0) {
    put("attach failed\n");
    return;
  }
  waitpid(pid, 0, 0);
  io.b = regs;
  io.l = sizeof(regs);
  if (ptrace(PT_GETREGSET, pid, (void *)1, &io) < 0) {
    put("getregset failed\n");
    ptrace(PT_DETACH, pid, 0, 0);
    return;
  }
  put("pc=");
  puthex(regs[32]);
  put(" x29=");
  puthex(regs[29]);
  put(" sp=");
  puthex(sp);
  put("\n");
  /* x29 is 0xffffffff in the blocked thread (U302), so no frame chain exists.
     The stack itself is valid: scan it for return addresses into the HAL and
     into libc, which names the callers without a frame pointer. */
  {
    unsigned long words[512];
    unsigned long libc = map_base("/apex/com.android.runtime/lib64/bionic/libc.so");
    unsigned long i2;
    long got;
    struct iov l2, r2;

    l2.b = words;
    l2.l = sizeof(words);
    r2.b = (void *)sp;
    r2.l = sizeof(words);
    got = process_vm_readv(pid, &l2, 1, &r2, 1, 0);
    put("stack got=");
    putdec(got);
    put(" libc_base=");
    puthex(libc);
    put("\n");
    for (i2 = 0; i2 < sizeof(words) / 8; i2++) {
      unsigned long w = words[i2];
      if (w >= hal_base && w < hal_base + 0x400000) {
        put("  stk hal+");
        puthex(w - hal_base);
        put("\n");
      } else if (libc && w >= libc && w < libc + 0x200000) {
        put("  stk libc+");
        puthex(w - libc);
        put("\n");
      }
    }
  }
  ptrace(PT_DETACH, pid, 0, 0);
}

/* The child blocks in userspace (futex), so the kernel stack names only the
   futex. The alarm's frame list, offset by the HAL's own base, names the
   library function that is waiting. */
static void on_alarm(int sig) {
  (void)sig;
  put("\nalarm: still inside the call\n");
  _exit(3);
}

/* The service builds the factory's options itself, in its own code at
   0x11660: it reads ro.board.platform, compares it with gs101/gs201/zuma/
   zumapro, and returns a status word plus 16 payload bytes. Calling that
   function inside the service process gives the exact bytes the service
   would pass, instead of a guess at the layout. */
static char mapsbuf[16384];

static int hasword(const char *s, const char *w) {
  int i;

  for (; *s; s++) {
    for (i = 0; w[i] && s[i] == w[i]; i++)
      ;
    if (!w[i]) return 1;
  }
  return 0;
}

static unsigned long hexnum(const char *s) {
  unsigned long v = 0;

  for (;; s++) {
    char c = *s;

    if (c >= '0' && c <= '9') v = v * 16 + (unsigned long)(c - '0');
    else if (c >= 'a' && c <= 'f') v = v * 16 + (unsigned long)(c - 'a' + 10);
    else break;
  }
  return v;
}

static unsigned long map_base(const char *needle) {
  long n;
  int fd = open("/proc/self/maps", 0);
  char *p;
  unsigned long best = 0;

  if (fd < 0) return 0;
  n = read(fd, mapsbuf, sizeof(mapsbuf) - 1);
  if (n <= 0) return 0;
  mapsbuf[n] = 0;
  p = mapsbuf;
  while (*p) {
    char *line = p;

    while (*p && *p != '\n') p++;
    if (*p) *p++ = 0;
    if (hasword(line, needle)) {
      unsigned long a = hexnum(line);

      if (a && (!best || a < best)) best = a;
    }
  }
  return best;
}

static unsigned long exe_base(void) { return map_base("/vendor/bin/edgetpu-run"); }

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
static int call_create_opts(unsigned long *t, unsigned char *opts,
                           unsigned long *out, int flags) {
  unsigned char ctx[0x80];
  void *cb = (flags & 1) ? (void *)harness_cb : 0;
  void *cp = 0;
  int i;

  for (i = 0; i < (int)sizeof(ctx); i++) ctx[i] = 0;
  ctx[0x10] = 1;
  ctx[0x7c] = (char)(2000 & 0xff);
  ctx[0x7d] = (char)((2000 >> 8) & 0xff);
  if (flags & 2) cp = ctx;
  *out = 0;
  return ((fn4)t[2])(opts, (void **)out, cb, cp);
}

static int call_create(unsigned long *t, unsigned long *out, int with_cb) {
  unsigned char opts[64];
  int i;

  for (i = 0; i < (int)sizeof(opts); i++) opts[i] = 0;
  return call_create_opts(t, opts, out, with_cb ? 3 : 0);
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
  hal_base = map_base("/vendor/lib64/libdarwinn_dba_hal_runtime.so");
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

  if (mode[0] == 'b') {
    n = -1;
  } else if (mode[0] == 'o' && mode[1] == 'p') {
    n = -1;
  } else if (mode[0] == 'o') {
    n = 0;
  } else if (mode[0] == 'c') {
    n = 2;
  } else if (mode[0] == 'e') {
    const char *es = envget("ENTRY");

    n = 2;
    while (*es && (*es >= '0' && *es <= '9')) n = n * 10 + (*es++ - '0');
  }

  pid = fork();
  if (pid == 0) {
    signal(14, on_alarm);
    if (mode[0] != 'b' && !fileget("/tmp/tpu-noalarm")) alarm(3);
    put("calling entry ");
    putdec(n);
    put(" with zeroed options\n");
    if (n == -1) {
      /* The builder's success path (0x11a00-0x11a14) writes status 0 and
         {u32 1, u32 <platform>, const char *0x50a2}. Synthesize exactly that;
         the pointer stays inside the service image, so the HAL can read it. */
      unsigned char opts[16];
      unsigned int *o = (unsigned int *)opts;
      int i;

      o[0] = 1;
      o[1] = 1;
      *(unsigned long *)(opts + 8) = (unsigned long)devpath;
      put("opts2=");
      for (i = 0; i < 16; i++) putb(opts[i]);
      put(" str=");
      put(devpath);
      put("\n");
      rc = call_create_opts(t, opts, &out, 1 + 2 * (mode[4] != '3'));
      if (out) {
        unsigned long *v = *(unsigned long **)out;

        put("hal=");
        puthex(out);
        put(" vtable=");
        puthex((unsigned long)v);
        put("\n");
      }
    } else if (n == 0) {
      unsigned long base = exe_base();
      unsigned char sb[32], opts[16];
      int i;

      for (i = 0; i < 32; i++) sb[i] = 0;
      put("exe base=");
      puthex(base);
      put("\n");
      if (!base) _exit(0);
      put("builder enter\n");
      ((void (*)(void *))(base + 0x11660))(sb);
      put("builder return\n");
      put("builder status=");
      puthex(*(unsigned long *)sb);
      put("\nopts=");
      for (i = 0; i < 16; i++) putb(sb[8 + i]);
      put("\n");
      for (i = 0; i < 16; i++) opts[i] = sb[8 + i];
      rc = call_create_opts(t, opts, &out, 1 + 2 * (mode[4] != '3'));
    } else if (n == 2) {
      rc = call_create(t, &out, mode[0] == 'c' && mode[6] == '2');
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
  if (mode[0] == 'b') {
    usleep(2500000);
    dump_child(pid);
    kill(pid, 9);
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
