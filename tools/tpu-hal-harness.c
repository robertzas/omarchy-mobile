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
extern int sem_init(void *, int, unsigned int);
extern int sem_wait(void *);
static unsigned long selftest_sem[8];
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
extern int getpid(void);

/* S2b: the blockers. The HAL is in this address space, so an interposed
   pthread_cond_wait/sem_wait/pthread_join returns to the HAL call site and
   __builtin_return_address(0) names the waiting function directly: no ptrace,
   no unwinder, no deadlock. Print only in the child that calls the factory. */
static int watch_pid;

static void report(const char *what, unsigned long ra) {
  put("BLK ");
  put(what);
  put(" ra=");
  puthex(ra);
  if (ra >= hal_base && ra < hal_base + 0x400000) {
    put(" hal+");
    puthex(ra - hal_base);
  }
  put("\n");
}

typedef int (*cw_t)(void *, void *);
typedef int (*cwt_t)(void *, void *, const void *);
typedef int (*sw_t)(void *);
typedef int (*jw_t)(unsigned long, void **);

/* S7: /proc/<pid>/syscall names the syscall a blocked thread is inside, with
   its arguments and pc. Read from the parent: no threads, no ptrace, no
   signal handler, and it works while the child sits in a raw futex. */
static char *u2s(unsigned int v, char *p);
extern int open(const char *, int, ...);
extern int close(int);
extern int usleep(unsigned int);

static void sample_peer(int pid) {
  int k;
  for (k = 0; k < 3; k++) {
    char path[40];
    char buf[256];
    char *q = path;
    int fd, n;
    usleep(500000);
    *q++ = '/'; *q++ = 'p'; *q++ = 'r'; *q++ = 'o'; *q++ = 'c'; *q++ = '/';
    q = u2s((unsigned int)pid, q);
    *q++ = '/'; *q++ = 's'; *q++ = 'y'; *q++ = 's'; *q++ = 'c'; *q++ = 'a';
    *q++ = 'l'; *q++ = 'l'; *q = 0;
    fd = open(path, 0);
    n = fd >= 0 ? (int)read(fd, buf, sizeof(buf) - 1) : -1;
    if (fd >= 0) close(fd);
    if (n <= 0) {
      put("SYS read fail\n");
      continue;
    }
    buf[n] = 0;
    put("SYS ");
    put(buf);
    put("\n");
  }
}

/* S6: is the block a sleep or a spin? /proc/self/stat's state char and its
   utime/stime fields grow only if the thread is running. Sampling from a
   monitor thread needs no signal, no unwinder and no second process. */
extern int open(const char *, int, ...);
extern int close(int);
extern unsigned int sleep(unsigned int);
extern int pthread_create(unsigned long *, const void *, void *(*)(void *), void *);
extern int pthread_detach(unsigned long);

static char *u2s(unsigned int v, char *p) {
  char t[12];
  int i = 0;
  do {
    t[i++] = (char)('0' + v % 10);
    v /= 10;
  } while (v);
  while (i) *p++ = t[--i];
  *p = 0;
  return p;
}

static void stat_self(const char *tag) {
  char buf[400];
  int fd = open("/proc/self/stat", 0);
  int n = fd >= 0 ? (int)read(fd, buf, sizeof(buf) - 1) : -1;
  if (fd >= 0) close(fd);
  if (n <= 0) {
    put("STAT ");
    put(tag);
    put(" fail\n");
    return;
  }
  buf[n] = 0;
  put("STAT ");
  put(tag);
  put(" ");
  put(buf);
  put("\n");
}

static void *monitor(void *a) {
  (void)a;
  usleep(650000);
  stat_self("t0.65");
  usleep(650000);
  stat_self("t1.30");
  usleep(650000);
  stat_self("t1.95");
  return 0;
}

/* S5: name the fd and the call site of the block. These cannot be waited on
   through a PLT symbol (binder/io_uring/mailbox waits live in the kernel), so
   print before delegating: the last IO line is the blocking call. */
typedef long (*rd_t)(int, void *, unsigned long);
typedef int (*ew_t)(int, void *, int, int);
typedef int (*pw_t)(void *, unsigned long, int);
typedef long (*io_t)(int, unsigned long, void *);
typedef int (*sk_t)(int, int, int);
typedef int (*cn_t)(int, const void *, unsigned int);

static int io_budget = 200;

static void io_report(const char *w, int fd, long n, unsigned long ra) {
  if (getpid() != watch_pid || io_budget-- <= 0) return;
  put("IO ");
  put(w);
  put(" fd=");
  putdec(fd);
  if (n != -999) {
    put(" n=");
    putdec(n);
  }
  put(" ra=");
  puthex(ra);
  if (ra >= hal_base && ra < hal_base + 0x400000) {
    put(" hal+");
    puthex(ra - hal_base);
  }
  put("\n");
}

long read(int fd, void *b, unsigned long n) {
  rd_t f = (rd_t)dlsym((void *)-1, "read");
  io_report("read", fd, (long)n, (unsigned long)__builtin_return_address(0));
  return f(fd, b, n);
}

int epoll_wait(int ep, void *e, int mx, int to) {
  ew_t f = (ew_t)dlsym((void *)-1, "epoll_wait");
  io_report("epoll_wait", ep, (long)to, (unsigned long)__builtin_return_address(0));
  return f(ep, e, mx, to);
}

int poll(void *fds, unsigned long nf, int to) {
  pw_t f = (pw_t)dlsym((void *)-1, "poll");
  io_report("poll", -1, (long)to, (unsigned long)__builtin_return_address(0));
  return f(fds, nf, to);
}

long ioctl(int fd, unsigned long req, void *arg) {
  io_t f = (io_t)dlsym((void *)-1, "ioctl");
  io_report("ioctl", fd, (long)req, (unsigned long)__builtin_return_address(0));
  return f(fd, req, arg);
}

int socket(int d, int t, int p) {
  sk_t f = (sk_t)dlsym((void *)-1, "socket");
  io_report("socket", d, (long)t, (unsigned long)__builtin_return_address(0));
  return f(d, t, p);
}

/* S8: the retry loop. A HAL waiting for a device node retries openat/access
   and sleeps; none of those was interposed before, and `open` alone misses
   openat, which is what bionic's open() and the HAL both use. */
typedef int (*oa_t)(int, const char *, int, ...);
typedef int (*ac_t)(const char *, int);
typedef int (*ns_t)(const void *, void *);

int openat(int dfd, const char *path, int flags, ...) {
  oa_t f = (oa_t)dlsym((void *)-1, "openat");
  unsigned long ra = (unsigned long)__builtin_return_address(0);
  if (getpid() == watch_pid && io_budget-- > 0) {
    io_report("openat", dfd, (long)flags, ra);
    put("IO   path=");
    put(path);
    put("\n");
  }
  if (flags & 0100) return f(dfd, path, flags, 0600);
  return f(dfd, path, flags);
}

int access(const char *path, int mode) {
  ac_t f = (ac_t)dlsym((void *)-1, "access");
  if (getpid() == watch_pid && io_budget-- > 0) {
    io_report("access", -1, (long)mode, (unsigned long)__builtin_return_address(0));
    put("IO   path=");
    put(path);
    put("\n");
  }
  return f(path, mode);
}

int nanosleep(const void *req, void *rem) {
  ns_t f = (ns_t)dlsym((void *)-1, "nanosleep");
  io_report("nanosleep", -1, -999, (unsigned long)__builtin_return_address(0));
  return f(req, rem);
}

int connect(int fd, const void *sa, unsigned int len) {
  cn_t f = (cn_t)dlsym((void *)-1, "connect");
  if (getpid() == watch_pid && io_budget-- > 0) {
    const unsigned char *b = (const unsigned char *)sa;
    unsigned int i;
    io_report("connect", fd, (long)len, (unsigned long)__builtin_return_address(0));
    put("IO   addr=");
    for (i = 0; i < 16 && i < len; i++) putb(b[i]);
    put("\n");
  }
  return f(fd, sa, len);
}

int pthread_cond_wait(void *c, void *m) {
  cw_t f = (cw_t)dlsym((void *)-1, "pthread_cond_wait");

  if (getpid() == watch_pid) report("cond_wait", (unsigned long)__builtin_return_address(0));
  if (!f) _exit(9);
  return f(c, m);
}

int pthread_cond_timedwait(void *c, void *m, const void *a) {
  cwt_t f = (cwt_t)dlsym((void *)-1, "pthread_cond_timedwait");

  if (getpid() == watch_pid) report("cond_timedwait", (unsigned long)__builtin_return_address(0));
  if (!f) _exit(9);
  return f(c, m, a);
}

int sem_wait(void *s) {
  sw_t f = (sw_t)dlsym((void *)-1, "sem_wait");

  if (getpid() == watch_pid) report("sem_wait", (unsigned long)__builtin_return_address(0));
  if (!f) _exit(9);
  return f(s);
}

int pthread_mutex_lock(void *m) {
  static int (*tl)(void *);
  static int (*rl)(void *);
  int rc;

  if (!tl) {
    tl = (int (*)(void *))dlsym((void *)-1, "pthread_mutex_trylock");
    rl = (int (*)(void *))dlsym((void *)-1, "pthread_mutex_lock");
  }
  if (!tl || !rl) _exit(9);
  rc = tl(m);
  if (rc == 0) return 0;                 /* we hold it: the lock is done */
  if (getpid() == watch_pid)
    report("mutex_lock", (unsigned long)__builtin_return_address(0));
  return rl(m);
}

int pthread_join(unsigned long t, void **r) {
  jw_t f = (jw_t)dlsym((void *)-1, "pthread_join");

  if (getpid() == watch_pid) report("pthread_join", (unsigned long)__builtin_return_address(0));
  if (!f) _exit(9);
  return f(t, r);
}

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
  sample_peer(pid);
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

  if (mode[0] == 'b' || mode[0] == 'c' || mode[0] == 'n') {
    n = -1;
    if (mode[0] == 'c') {
      watch_pid = getpid();     /* the self-test gates on this: set it FIRST */
      sem_init(selftest_sem, 0, 1);
      sem_wait(selftest_sem);   /* must print BLK sem_wait: proof of interposition */
      put("selftest done\n");
      watch_pid = 0;            /* the parent is not the subject */
    }
  } else if (mode[0] == 'l') {
    n = -1;                     /* 'loop': create, but after a Looper exists */
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

  pid = (mode && mode[0] == 'n') ? 0 : (getenv("NOFORK") ? 0 : fork());
  if (pid == 0) {
    signal(14, on_alarm);
    if (mode[0] != 'b') {
      watch_pid = getpid();
      if (!fileget("/tmp/tpu-noalarm")) alarm(3);
    }
    if (mode[0] == 'l') {
      /* H1: does a prepared ALooper (and an initialised binder ProcessState)
         change where the factory waits? Both are what Android would have. */
      extern void *dlopen(const char *, int);
      put("loop: begin\n");
      (void)dlopen("liblog.so", 1);
      put("loop: liblog done\n");
      void *la = dlopen("libandroid.so", 1);
      put("loop: libandroid done\n");
      void *(*prep)(int) = la ? (void *(*)(int))dlsym(la, "ALooper_prepare") : 0;
      put("ALooper_prepare=");
      if (prep) { puthex((unsigned long)prep(0)); } else { put("missing"); }
      put("\n");
      if (getenv("PS")) {
        void *lb = dlopen("libbinder.so", 1);
        void *(*ps)(void) = lb ? (void *(*)(void))dlsym(lb, "_ZN7android12ProcessState4selfEv") : 0;
        put("ProcessState::self=");
        if (ps) { puthex((unsigned long)ps()); } else { put("missing"); }
        put("\n");
      }
    }
    {
      unsigned long mt = 0;
      int mrc = pthread_create(&mt, 0, monitor, 0);

      put("monitor rc=");
      putdec(mrc);
      put("\n");
      if (mrc == 0) (void)pthread_detach(mt);
    }
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
