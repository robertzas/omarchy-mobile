// SPDX-License-Identifier: MIT
// tpu-a14-hal: load the Android 14 stock Darwinn HAL by absolute path and call
// its function table, for TPU bring-up. The A17 HAL in the chroot is a rebuild
// with the Tachyon provider; the A14 HAL is the original 7 Pro stack, and its
// table entries sit at different offsets. Linking -ldarwinn_hal makes the
// dynamic linker pick the NEEDED A17 soname even with LD_LIBRARY_PATH set, so
// this client deliberately links only libc/libdl and dlopens the A14 file.
//
// Run inside the vendor chroot:
//   chroot ROOT /vendor/bin/tpu-a14-hal          # create device, hold 30 s
//   chroot ROOT /vendor/bin/tpu-a14-hal vd [B]   # then call table [5]
//
// [3] is CreateDevice. The HAL opens /dev/edgetpu itself, so the client
// interposes open() and takes EDGETPU_ACQUIRE_WAKE_LOCK on that fd: without the
// wakelock the driver skips the VII attach and the group finalize blocks.
// [5] is the virtual-device create, the first entry the runtime sends setup
// from; B is passed as the fifth argument (the cluster bitset candidate).
typedef unsigned long size_t;
typedef long ssize_t;

extern void __libc_init(void *, void *, int (*)(int, char **, char **), void *);
extern long write(int, const void *, size_t);
extern void *dlopen(const char *, int);
extern void *dlsym(void *, const char *);
extern char *dlerror(void);
extern long syscall(long, ...);
extern void _exit(int);
extern void *mmap(void *, size_t, int, int, int, long);
extern int pthread_create(unsigned long *, const void *,
                          void *(*)(void *), void *);
extern int ioctl(int, unsigned long, ...);
extern int *__errno(void);

#define RTLD_NOW 2
#define RTLD_LOCAL 0
#define RTLD_NEXT ((void *)-1)

// The runtime picks the chip family from ro.board.platform. A chroot has no
// Android property service, so answer that one property here.
int __system_property_get(const char *name, char *value) {
  static const char key[] = "ro.board.platform";
  static const char val[] = "gs201";
  int i = 0;

  while (key[i] && name[i] == key[i]) i++;
  if (key[i] || name[i]) {
    value[0] = 0;
    return 0;
  }
  for (i = 0; val[i]; i++) value[i] = val[i];
  value[i] = 0;
  return i;
}

// The HAL's metrics logger asks servicemanager whether the stats service is
// declared; on a chroot there is none, and libbinder waits forever for one.
int AServiceManager_isDeclared(const char *instance) {
  (void)instance;
  return 0;
}

void *AServiceManager_getService(const char *instance) {
  (void)instance;
  return 0;
}

void *AServiceManager_checkService(const char *instance) {
  (void)instance;
  return 0;
}

void *AServiceManager_waitForService(const char *instance) {
  (void)instance;
  return 0;
}

// bionic's crt is not in the vendor chroot; __libc_init does its job. It
// dereferences the structors array without a null check, so pass a zeroed one.
struct structors_array {
  void (**preinit_array)(void);
  size_t preinit_array_size;
  void (**init_array)(void);
  size_t init_array_size;
  void (**fini_array)(void);
  size_t fini_array_size;
};
struct structors_array structors;

__attribute__((naked)) void _start(void) {
  __asm__ volatile(
      "mov x0, sp\n"
      "mov x1, xzr\n"
      "adrp x2, main\n"
      "add x2, x2, :lo12:main\n"
      "adrp x3, structors\n"
      "add x3, x3, :lo12:structors\n"
      "bl __libc_init\n");
}

static void put(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  write(1, s, n);
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
    b[i--] = '0' + u % 10;
    u /= 10;
  } while (u);
  if (neg) b[i--] = '-';
  put(&b[i + 1]);
}

static void status(const char *what, long st) {
  put(what);
  put(": ");
  putdec(st);
  put("\n");
}

static int streq(const char *a, const char *b) {
  while (*a && *a == *b) a++, b++;
  return *a == *b;
}

static unsigned argdec(const char *s) {
  unsigned v = 0;

  while (*s >= '0' && *s <= '9') v = v * 10 + (unsigned)(*s++ - '0');
  return v;
}

// The stock HAL opens /dev/edgetpu itself. The driver only does the VII attach
// and the KCI group join at finalize when a wakelock is held on the device, so
// take one on the HAL's own fd. bionic's ioctl syscall is 29;
// EDGETPU_ACQUIRE_WAKE_LOCK is _IO(0xED, 26).
static int (*real_open)(const char *, int, ...);
static volatile int tpu_fd = -1;

static int interesting(const char *p) {
  int i;

  if (p[0] == '/' && p[1] == 'd' && p[2] == 'e' && p[3] == 'v' && p[4] == '/')
    return 1;
  for (i = 0; p[i]; i++) {
    if ((p[i] == 't' || p[i] == 'T') && p[i + 1] == 'a' && p[i + 2] == 'c')
      return 1;
    if ((p[i] == 'e' || p[i] == 'E') && p[i + 1] == 'd' && p[i + 2] == 'g')
      return 1;
    if ((p[i] == 'j' || p[i] == 'J') && p[i + 1] == 'a' && p[i + 2] == 'n')
      return 1;
  }
  return 0;
}

int open(const char *path, int flags, ...) {
  int fd;

  if (!real_open)
    real_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
  if (!real_open) return -1;
  fd = real_open(path, flags, 0);
  if (interesting(path)) {
    put("open ");
    put(path);
    put(" -> ");
    putdec(fd);
    put("\n");
  }
  if (fd >= 0 && streq(path, "/dev/edgetpu")) {
    long r = syscall(29, fd, 0xed1a, 0);

    tpu_fd = fd;
    put("runtime wakelock on fd ");
    putdec(fd);
    put(": ");
    putdec(r);
    put("\n");
  }
  return fd;
}

// Every ioctl the HAL issues on the device, with the argument bytes the driver
// gets (the _IOC size field gives the length). The setup path is the one call
// the firmware gate depends on, so nothing may go unseen.
static int (*real_ioctl)(int, unsigned long, ...);

int ioctl(int fd, unsigned long req, ...) {
  __builtin_va_list ap;
  unsigned long arg = 0;
  int r;

  __builtin_va_start(ap, req);
  arg = __builtin_va_arg(ap, unsigned long);
  __builtin_va_end(ap);
  if (!real_ioctl)
    real_ioctl = (int (*)(int, unsigned long, ...))dlsym(RTLD_NEXT, "ioctl");
  r = real_ioctl(fd, req, arg);
  if (fd == tpu_fd) {
    unsigned sz = (unsigned)((req >> 16) & 0x3fff);
    unsigned dir = (unsigned)((req >> 30) & 3);

    put("ioctl req ");
    puthex(req);
    put(" sz ");
    putdec(sz);
    put(" arg ");
    puthex(arg);
    if ((dir == 1 || dir == 3) && arg && sz && sz <= 0x4000) {
      unsigned char *p = (unsigned char *)arg;
      unsigned n = sz > 192 ? 192 : sz;
      unsigned i;

      put(" data");
      for (i = 0; i + 4 <= n; i += 4) {
        unsigned w = (unsigned)p[i] | ((unsigned)p[i + 1] << 8) |
                     ((unsigned)p[i + 2] << 16) | ((unsigned)p[i + 3] << 24);

        put(" ");
        puthex(w);
      }
    }
    put(" -> ");
    putdec(r);
    if (r < 0) {
      put(" errno ");
      putdec(*__errno());
    }
    put("\n");
  }
  return r;
}

static void putch(char c) { write(1, &c, 1); }

// The HAL's CreateDevice reaches group create/finalize and attaches the
// mailbox, then blocks: the A14 stack is the first client seen to send VII from
// create. Dump the command queue, its elements, the responses and the firmware
// log ring 8 s in, then exit so the group is released; the blocked call never
// returns to print anything of its own.
static void *watch_queues(void *arg) {
  struct {
    long sec;
    long nsec;
  } ts = {8, 0};
  unsigned *csr, *cq, *rq;
  unsigned char *log;
  int fd, i, e;

  (void)arg;
  syscall(101, &ts, 0); /* nanosleep */
  fd = tpu_fd;
  put("watch: fd ");
  putdec(fd);
  put("\n");
  if (fd < 0) {
    put("watch: no device fd yet\n");
    _exit(0);
  }
  csr = mmap(0, 0x1000, 3, 1, fd, 0x1800000);
  cq = mmap(0, 24 * 1024, 3, 1, fd, 0x1900000);
  rq = mmap(0, 12 * 1024, 3, 1, fd, 0x1a00000);
  log = mmap(0, 0x10000, 3, 1, fd, 0x1B00000);
  if ((long)csr < 0 || (long)cq < 0 || (long)rq < 0) {
    put("watch: queue mmap failed\n");
    _exit(0);
  }
  put("watch: csr");
  for (i = 0; i < 8; i++) {
    put(" ");
    puthex(csr[i]);
  }
  put("\nwatch: cq");
  for (i = 0; i < 96; i++) {
    put(" ");
    puthex(cq[i]);
  }
  put("\n");
  for (e = 0; e < 8; e++) {
    unsigned char *el = (unsigned char *)cq + e * 48;
    unsigned long seq = *(unsigned long *)(el + 0);
    unsigned code = *(unsigned short *)(el + 8);
    unsigned long addr = *(unsigned long *)(el + 16);
    unsigned long size = *(unsigned long *)(el + 24);

    if (!seq && !code && !addr && !size) continue;
    put("watch: el");
    putdec(e);
    put(" seq ");
    puthex(seq);
    put(" code ");
    putdec(code);
    put(" dma ");
    puthex(addr);
    put(" size ");
    puthex(size);
    put("\n");
  }
  put("watch: rq");
  for (i = 0; i < 24; i++) {
    put(" ");
    puthex(rq[i]);
  }
  put("\n");
  if ((long)log >= 0) {
    unsigned t = *(unsigned *)(log + 0x40);
    unsigned lim = (t & 0x10000) ? 0x10000 : (t & 0xffff);
    unsigned st;

    put("watch: fwlog head ");
    puthex(*(unsigned *)(log + 0));
    put(" tail ");
    puthex(t);
    put(" dropped ");
    putdec(*(unsigned *)(log + 0x44));
    put("\n");
    for (st = 128; st < lim;) {
      unsigned s2;

      while (st < lim && (log[st] < 0x20 || log[st] >= 0x7f)) st++;
      s2 = st;
      while (st < lim && log[st] >= 0x20 && log[st] < 0x7f) st++;
      if (st - s2 >= 12) {
        unsigned k;

        put("watch: log@");
        puthex(s2);
        put(": ");
        for (k = s2; k < st; k++) putch((char)log[k]);
        put("\n");
      }
    }
  }
  put("watch: done, exiting to release the group\n");
  _exit(0);
  return 0;
}

int main(int argc, char **argv) {
  void *h;
  void *(*get_table)(void);
  void **t;
  unsigned long dev = 0;
  long r;
  int i;

  h = dlopen("/vendor/a14/libdarwinn_hal.so", RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    char *e = dlerror();
    put("dlopen: ");
    put(e ? e : "?");
    put("\n");
    return 1;
  }
  get_table = (void *(*)(void))dlsym(h, "GetDarwinnHalFunctions");
  if (!get_table) {
    put("dlsym: GetDarwinnHalFunctions missing\n");
    return 1;
  }
  t = get_table();
  put("a14 table ");
  puthex((unsigned long)t);
  put(" version ");
  putdec((long)(unsigned)((unsigned *)t)[0]);
  put("\n");
  for (i = 0; i < 24; i++) {
    put("  [");
    putdec(i);
    put("] ");
    puthex((unsigned long)t[i]);
    put("\n");
  }

  {
    struct {
      unsigned version, flags;
      const char *path;
      unsigned long spawner;
      long fd;
    } cfg = {1, 1, "/dev/edgetpu", 0, -1};
    unsigned long th;

    if (!pthread_create(&th, 0, watch_queues, 0))
      put("a14: queue watcher armed\n");
    else
      put("a14: watcher did not start\n");
    r = ((long (*)(void *, unsigned long *))t[3])(&cfg, &dev);
    status("create_device", r);
    put("dev ");
    puthex(dev);
    put("\n");
  }

  if (!r && dev && argc > 1 && streq(argv[1], "vd")) {
    static unsigned char vcfg[0x1000];
    unsigned long vd = 0;
    unsigned bits = argc > 2 ? argdec(argv[2]) : 0;

    for (i = 0; i < (int)sizeof(vcfg); i++) vcfg[i] = 0;
    r = ((long (*)(unsigned long, void *, unsigned long *, unsigned long,
                   unsigned long))t[5])(dev, vcfg, &vd, 0, bits);
    status("create_vd5", r);
    put("vd ");
    puthex(vd);
    put(" bits ");
    putdec((long)bits);
    put("\n");
  }

  if (!r && dev) {
    struct {
      long sec;
      long nsec;
    } ts = {30, 0};

    put("holding the device open\n");
    syscall(101, &ts, 0); /* nanosleep */
  }
  return 0;
}
