// SPDX-License-Identifier: MIT
// edgetpu-run: drive the stock Jainero runtime (libedgetpu_util.so) against
// the mainline janeiro driver, for bring-up. It is not a general runtime.
//
// The vendor library exports a C API (DarwinnDelegate_*, DarwinnApi2_*). The
// prototypes below are the ones the phone's Abrolhos/Janeiro build uses; the
// arguments were checked against the library's disassembly. The client is
// freestanding on purpose: it builds with the pinned Android clang and the
// bionic libc from an extracted vendor chroot, with no NDK headers.
//
// Run it inside the vendor chroot:
//   chroot ROOT /vendor/bin/edgetpu-run /vendor/model.tflite
//
// It creates a virtual device on /dev/edgetpu, allocates a device buffer with
// the model (the graph container from an Edge TPU-compiled .tflite), registers
// the graph and prints the input/output tensor counts. No inference yet.
typedef unsigned long size_t;
typedef long ssize_t;

extern void __libc_init(void *, void *, int (*)(int, char **, char **), void *);
extern int open(const char *, int, ...);
extern void *mmap(void *, size_t, int, int, int, long);
extern long read(int, void *, size_t);
extern long lseek(int, long, int);
extern int close(int);
extern long write(int, const void *, size_t);
extern void *malloc(size_t);
extern void _exit(int);
extern void *dlsym(void *, const char *);
extern long syscall(long, ...);
extern int ioctl(int, unsigned long, ...);

// libdarwinn_hal.so is the stock NNAPI HAL runtime (self-contained: libc, libm,
// libdl, liblog). Its only exported entry point returns a table of function
// pointers whose first word is a version; the AIDL service calls entry [1]
// with an out pointer and entry [3] with the service object. "hal" mode just
// dumps the table so the entries can be mapped to file offsets; "halcall" then
// calls entries in that table.
extern void *GetDarwinnHalFunctions(void);

// A 16-byte std::shared_ptr<Buffer> as the C API passes it.
typedef struct {
  void *object;
  void *control;
} SharedPtr;

extern long DarwinnDelegate_CreateVirtualDevice(int, int, int, int,
                                                const char *const *, int,
                                                void **);
extern long DarwinnDelegate_GetDefaultDeviceSpec(int *, char *, int *, int *,
                                                 const char ***, int *);
extern void *DarwinnDelegate_EdgeTpuDevice_GetVirtualDevice(void *);
extern void *DarwinnApi2_VirtualDevice_GetBufferFactory(void *);
extern long DarwinnApi2_BufferFactory_AllocateBuffer(void *, size_t, void *,
                                                     void *, SharedPtr *);
extern long DarwinnApi2_Buffer_CopyFrom(SharedPtr *, const void *);
extern long DarwinnApi2_VirtualDevice_RegisterGraphByBuffer(void *, SharedPtr *,
                                                            void *, int, int,
                                                            void **);
extern int DarwinnApi2_Graph_NumInputTensors(void *);
extern int DarwinnApi2_Graph_NumOutputTensors(void *);

// The runtime picks the chip family from ro.board.platform. A chroot has no
// Android property service, so answer that one property here; the executable
// exports it and the vendor library's PLT binds to this definition.
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

// The runtime creates its metrics logger inside CreateVirtualDevice, and the
// logger asks Android's servicemanager whether the stats service is declared.
// A chroot has no servicemanager, and libbinder's defaultServiceManager() waits
// for one in a sleep(1) loop forever, which stalls CreateVirtualDevice before
// any TPU setup. Answer the NDK service-manager queries so the logger gives up
// quickly and the TPU path continues.
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

static void putc(char c) {
  write(1, &c, 1);
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

// The stock runtime opens /dev/edgetpu but, without Android's vendor service,
// does not take the driver wakelock. The driver then skips the VII attach and
// the KCI group join at finalize, and the runtime waits forever for a VII
// response. Interpose open() and take the wakelock on the runtime's own fd.
// bionic's ioctl syscall is 29; EDGETPU_ACQUIRE_WAKE_LOCK is _IO(0xED, 26).
static int (*real_open)(const char *, int, ...);

// The fd the stock HAL opened inside this process, so a watchdog thread can
// map the group the HAL created and dump its queues while the HAL is blocked.
static volatile int tpu_fd = -1;

int open(const char *path, int flags, ...) {
  __builtin_va_list ap;
  int mode = 0;
  int fd;

  if (!real_open) real_open = dlsym((void *)-1, "open");
  if (flags & 0100) {
    __builtin_va_start(ap, flags);
    mode = __builtin_va_arg(ap, int);
    __builtin_va_end(ap);
  }
  fd = real_open(path, flags, mode);
  if (fd >= 0 && streq(path, "/dev/edgetpu")) {
    tpu_fd = fd;
    long r = syscall(29, fd, 0xed1a, 0);
    put("runtime wakelock on fd ");
    putdec(fd);
    put(": ");
    putdec(r);
    put("\n");
  }
  return fd;
}

// The runtime may map the VII queues or mailbox registers. Log every mmap so a
// stall shows whether the runtime got as far as userspace queue access.
struct maprec {
  int fd;
  void *addr;
  size_t len;
};
static struct maprec maps[64];
static int nmaps;

struct iovec_l {
  void *base;
  unsigned long len;
};
extern long process_vm_readv(int pid, const struct iovec_l *local,
                             unsigned long liovcnt, const struct iovec_l *remote,
                             unsigned long riovcnt, unsigned long flags);
extern int getpid(void);

// Dump the head of every buffer the runtime mapped. process_vm_readv fails on a
// mapping that is gone instead of taking a SIGSEGV, so this is safe to run after
// a failed create.
static void dump_maps(void) {
  int i, j;

  for (i = 0; i < nmaps; i++) {
    unsigned char buf[64];
    struct iovec_l local = {buf, 64};
    struct iovec_l remote = {maps[i].addr, 64};
    long n = process_vm_readv(getpid(), &local, 1, &remote, 1, 0);

    put("map fd ");
    putdec(maps[i].fd);
    put(" at ");
    puthex((unsigned long)maps[i].addr);
    if (n != 64) {
      put(" unreadable\n");
      continue;
    }
    put(" bytes");
    for (j = 0; j < 64; j += 4)
      puthex(*(unsigned *)(buf + j));
    put("\n");
  }
}

static void *(*real_mmap)(void *, size_t, int, int, int, long);

void *mmap(void *addr, size_t len, int prot, int flags, int fd, long off) {
  void *r;

  if (!real_mmap) real_mmap = dlsym((void *)-1, "mmap");
  r = real_mmap ? real_mmap(addr, len, prot, flags, fd, off)
                : (void *)syscall(222, addr, len, prot, flags, fd, off);
  put("mmap fd ");
  putdec(fd);
  put(" len ");
  puthex(len);
  put(" off ");
  puthex((unsigned long)off);
  put(" -> ");
  puthex((unsigned long)r);
  put("\n");
  if (fd >= 0 && len >= 64 && r && (long)r != -1 && nmaps < 64) {
    maps[nmaps].fd = fd;
    maps[nmaps].addr = r;
    maps[nmaps].len = len;
    nmaps++;
  }
  return r;
}

// Log every runtime ioctl and its result, so a stall names the operation.
static int (*real_ioctl)(int, unsigned long, ...);

int ioctl(int fd, unsigned long req, ...) {
  __builtin_va_list ap;
  void *arg;
  long r;

  if (!real_ioctl) real_ioctl = dlsym((void *)-1, "ioctl");
  __builtin_va_start(ap, req);
  arg = __builtin_va_arg(ap, void *);
  __builtin_va_end(ap);
  r = real_ioctl ? real_ioctl(fd, req, arg) : syscall(29, fd, req, arg);
  put("ioctl fd ");
  putdec(fd);
  put(" req ");
  puthex(req);
  put(" -> ");
  putdec(r);
  // EDGETPU_SET_EVENTFD carries { u32 event_id; s32 fd; }.
  if (req == 0x4008ed05 && arg) {
    put(" event_id ");
    putdec(((int *)arg)[0]);
    put(" efd ");
    putdec(((int *)arg)[1]);
  }
  // EDGETPU_CREATE_GROUP carries struct edgetpu_mailbox_attr: the queue sizes
  // in KiB and the size of one command and response element in bytes. The
  // firmware reads the command queue in elements, so a wrong element size makes
  // it read a different command than the runtime wrote.
  if (req == 0x4014ed06 && arg) {
    unsigned *a = arg;

    put(" attr cmdq_kb ");
    putdec((int)a[0]);
    put(" rspq_kb ");
    putdec((int)a[1]);
    put(" cmd ");
    putdec((int)a[2]);
    put(" rsp ");
    putdec((int)a[3]);
    put(" flags ");
    puthex(a[4]);
  }
  // EDGETPU_MAP_BUFFER carries { host_address, size, device_address, flags,
  // die_index }.
  // EDGETPU_MAP_DMABUF: the same shape as MAP_BUFFER, with a dma-buf fd.
  if (req == 0xc028ed11 && arg && r == 0) {
    unsigned long *m = arg;
    int k;

    put(" dmabuf");
    for (k = 0; k < 5; k++) {
      put(" ");
      puthex(m[k]);
    }
  }
  if (req == 0xc020ed00 && arg) {
    unsigned long *m = arg;

    put(" host ");
    puthex(m[0]);
    put(" size ");
    puthex(m[1]);
    put(" dev ");
    puthex(m[2]);
    put(" flags ");
    puthex(m[3] & 0xffffffff);
  }
  put("\n");
  return (int)r;
}

// "raw": create and finalize a group ourselves, mmap the queues and the
// command-queue CSRs, then write candidate VII setup elements and ring the
// tail. The firmware reads a u16 at +8 and a u8 at +10 of the 48-byte element;
// the stock runtime writes a per-command type at +10 and leaves +8 zero, so the
// candidates vary +8 and keep +10 at the runtime's setup value (11). One boot
// per run: the group is left finalized and the module must be reloaded by a
// reboot.
static void raw_mode(void) {
  unsigned attr[5] = {24, 12, 48, 24, 0x58};
  int ev[2] = {0, -1};
  unsigned char *csr;
  unsigned char *cq;
  unsigned char *rq;
  int fd;
  int efd;
  int i;
  long r;

  fd = open("/dev/edgetpu", 2);
  put("raw: fd ");
  putdec(fd);
  put("\n");
  if (fd < 0)
    return;
  // The stock runtime holds the driver wakelock from open to close; without
  // it the driver skips the VII attach at finalize. EDGETPU_ACQUIRE_WAKE_LOCK
  // is _IO(0xED, 26).
  r = syscall(29, fd, 0xed1a, 0);
  put("raw: wakelock -> ");
  putdec(r);
  put("\n");
  efd = (int)syscall(19, 0, 0); /* eventfd(0, 0) */
  ev[1] = efd;
  r = ioctl(fd, 0x4008ed05, ev);
  put("raw: eventfd ");
  putdec(efd);
  put(" -> ");
  putdec(r);
  put("\n");
  r = ioctl(fd, 0x4014ed06, attr);
  put("raw: create_group -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  r = ioctl(fd, 0xed08, 0);
  put("raw: finalize -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  csr = mmap(0, 0x1000, 3, 1, fd, 0x1800000);
  cq = mmap(0, 24 * 1024, 3, 1, fd, 0x1900000);
  rq = mmap(0, 12 * 1024, 3, 1, fd, 0x1a00000);
  put("raw: csr ");
  puthex((unsigned long)csr);
  put(" cq ");
  puthex((unsigned long)cq);
  put(" rq ");
  puthex((unsigned long)rq);
  put("\n");
  if ((long)csr < 0 || (long)cq < 0 || (long)rq < 0)
    return;

  for (i = 0; i < 16; i++) {
    unsigned char *e = cq + i * 48;
    int k;
    int t;

    for (k = 0; k < 48; k++)
      e[k] = 0;
    *(unsigned long *)(e + 0) = (unsigned long)(i + 1);
    *(unsigned short *)(e + 8) = (unsigned short)i;
    e[10] = 11;
    *(unsigned long *)(e + 16) = 0xffeff000UL;
    *(unsigned long *)(e + 24) = 0x80;
    *(volatile unsigned *)(csr + 12) = (unsigned)(i + 1);
    *(volatile unsigned *)(csr + 0) = 1;
    for (t = 0; t < 400000; t++)
      __asm__ __volatile__("");
    put("raw: type8=");
    putdec(i);
    put(" rsp");
    for (t = 0; t < 24; t += 4) {
      put(" ");
      puthex(*(unsigned *)(rq + i * 24 + t));
    }
    put(" csr");
    for (t = 0; t < 16; t += 4) {
      put(" ");
      puthex(*(volatile unsigned *)(csr + t));
    }
    put("\n");
  }
}

static unsigned long argdec(const char *s) {
  unsigned long v = 0;

  while (*s >= '0' && *s <= '9')
    v = v * 10 + (unsigned long)(*s++ - '0');
  return v;
}

// "hold": take the driver wakelock and keep it. While it runs, later clients
// create and finalize groups without a hardware power cycle, so one boot can
// run several experiments; the TPU powers down (and stays wedged) when the
// holder exits.
static void hold_mode(void) {
  int fd = open("/dev/edgetpu", 2);

  put("hold: fd ");
  putdec(fd);
  put("\n");
  if (fd < 0)
    return;
  for (;;) {
    struct {
      long sec;
      long nsec;
    } ts = {3600, 0};

    syscall(101, &ts, 0); /* nanosleep */
  }
}

// "probe": create and finalize a group and submit one element whose every
// plausible type field carries a distinct marker. The firmware's own log line
// ("... received a command of type N") then names the value it read, which
// identifies the field: 17 = u16 +4, 34 = u16 +6, 51 = u16 +8, 85 = u8 +11,
// 102 = u16 +12, 119 = u16 +14, 21828 = u16 +10. Byte +10 is the command's
// priority (the firmware rejected 68 there, "Invalid priority"), so it holds
// the runtime's valid 11 instead of a marker.
static void probe_mode(void) {
  unsigned attr[5] = {24, 12, 48, 24, 0x58};
  int ev[2] = {0, -1};
  unsigned char *csr, *cq, *rq, *e;
  int fd, efd, i;
  long r;

  fd = open("/dev/edgetpu", 2);
  put("probe: fd ");
  putdec(fd);
  put("\n");
  if (fd < 0)
    return;
  r = syscall(29, fd, 0xed1a, 0);
  put("probe: wakelock -> ");
  putdec(r);
  put("\n");
  efd = (int)syscall(19, 0, 0);
  ev[1] = efd;
  ioctl(fd, 0x4008ed05, ev);
  r = ioctl(fd, 0x4014ed06, attr);
  put("probe: create_group -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  r = ioctl(fd, 0xed08, 0);
  put("probe: finalize -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  csr = mmap(0, 0x1000, 3, 1, fd, 0x1800000);
  cq = mmap(0, 24 * 1024, 3, 1, fd, 0x1900000);
  rq = mmap(0, 12 * 1024, 3, 1, fd, 0x1a00000);
  if ((long)csr < 0 || (long)cq < 0 || (long)rq < 0)
    return;
  e = cq;
  for (i = 0; i < 48; i++)
    e[i] = 0;
  *(unsigned long *)(e + 0) = 1;
  *(unsigned short *)(e + 4) = 0x0011;
  *(unsigned short *)(e + 6) = 0x0022;
  *(unsigned short *)(e + 8) = 0x0033;
  e[10] = 0x0b;
  e[11] = 0x55;
  *(unsigned short *)(e + 12) = 0x0066;
  *(unsigned short *)(e + 14) = 0x0077;
  *(unsigned long *)(e + 16) = 0xffeff000UL;
  *(unsigned long *)(e + 24) = 0x80;
  put("probe: element");
  for (i = 0; i < 48; i += 4) {
    put(" ");
    puthex(*(unsigned *)(e + i));
  }
  put("\n");
  *(volatile unsigned *)(csr + 12) = 1;
  *(volatile unsigned *)(csr + 0) = 1;
  for (i = 0; i < 400000; i++)
    __asm__ __volatile__("");
  put("probe: rsp");
  for (i = 0; i < 24; i += 4) {
    put(" ");
    puthex(*(unsigned *)(rq + i));
  }
  put("\n");
}

// "setup OFFSET WIDTH VALUE": one group, one element with VALUE stored at
// OFFSET as 1, 2 or 4 bytes, the runtime's setup payload arguments, and the
// response printed as bytes.
static void setup_mode(const char *off_s, const char *w_s, const char *val_s) {
  unsigned attr[5] = {24, 12, 48, 24, 0x58};
  int ev[2] = {0, -1};
  unsigned char *csr, *cq, *rq, *e;
  int off = (int)argdec(off_s);
  int w = (int)argdec(w_s);
  unsigned long val = argdec(val_s);
  int fd, efd, i;
  long r;

  fd = open("/dev/edgetpu", 2);
  put("setup: fd ");
  putdec(fd);
  put("\n");
  if (fd < 0)
    return;
  r = syscall(29, fd, 0xed1a, 0);
  put("setup: wakelock -> ");
  putdec(r);
  put("\n");
  efd = (int)syscall(19, 0, 0);
  ev[1] = efd;
  ioctl(fd, 0x4008ed05, ev);
  r = ioctl(fd, 0x4014ed06, attr);
  put("setup: create_group -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  r = ioctl(fd, 0xed08, 0);
  put("setup: finalize -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  csr = mmap(0, 0x1000, 3, 1, fd, 0x1800000);
  cq = mmap(0, 24 * 1024, 3, 1, fd, 0x1900000);
  rq = mmap(0, 12 * 1024, 3, 1, fd, 0x1a00000);
  if ((long)csr < 0 || (long)cq < 0 || (long)rq < 0)
    return;
  e = cq;
  for (i = 0; i < 48; i++)
    e[i] = 0;
  *(unsigned long *)(e + 0) = 1;
  if (w == 1)
    e[off] = (unsigned char)val;
  else if (w == 2)
    *(unsigned short *)(e + off) = (unsigned short)val;
  else
    *(unsigned *)(e + off) = (unsigned)val;
  *(unsigned long *)(e + 16) = 0xffeff000UL;
  *(unsigned long *)(e + 24) = 0x80;
  *(volatile unsigned *)(csr + 12) = 1;
  *(volatile unsigned *)(csr + 0) = 1;
  for (i = 0; i < 400000; i++)
    __asm__ __volatile__("");
  put("setup: rsp");
  for (i = 0; i < 24; i += 4) {
    put(" ");
    puthex(*(unsigned *)(rq + i));
  }
  put("\n");
}

// "payload": the element's DMA descriptor must point at memory the firmware can
// read. Userspace cannot read the queue's IOVA from the context CSRs (kernel
// only), but the driver prints it at group finalize, so parse /dev/kmsg for the
// newest "cmdq iova=0x...". The payload lives inside the command queue itself,
// at element 0 + 0x1000, so no dma-buf is needed.
static int kmsg_tail(void) {
  int fd = open("/dev/kmsg", 0x800);

  if (fd >= 0)
    lseek(fd, 0, 2);
  return fd;
}

static unsigned long read_cmdq_iova(int fd) {
  static char buf[8192];
  unsigned long best = 0;
  int i;

  for (i = 0; i < 400 && !best; i++) {
    long n = read(fd, buf, sizeof(buf) - 1);
    long k;

    if (n > 0) {
      buf[n] = 0;
      for (k = 0; k + 12 < n; k++) {
        if (buf[k] == 'c' && buf[k + 1] == 'm' && buf[k + 2] == 'd' &&
            buf[k + 3] == 'q' && buf[k + 4] == ' ' && buf[k + 5] == 'i' &&
            buf[k + 6] == 'o' && buf[k + 7] == 'v' && buf[k + 8] == 'a' &&
            buf[k + 9] == '=' && buf[k + 10] == '0' && buf[k + 11] == 'x') {
          unsigned long v = 0;
          long m;

          for (m = k + 12; m < n; m++) {
            char c = buf[m];
            int d;

            if (c >= '0' && c <= '9')
              d = c - '0';
            else if (c >= 'a' && c <= 'f')
              d = c - 'a' + 10;
            else
              break;
            v = (v << 4) | (unsigned)d;
          }
          best = v;
        }
      }
    } else {
      struct {
        long sec;
        long nsec;
      } ts = {0, 10000000};

      syscall(101, &ts, 0);
    }
  }
  return best;
}

static void payload_mode(unsigned code, unsigned p0) {
  unsigned attr[5] = {24, 12, 48, 24, 0x58};
  int ev[2] = {0, -1};
  unsigned char *csr, *cq, *rq, *e, *pl;
  unsigned long iova;
  int fd, efd, i, kfd;
  long r;

  kfd = kmsg_tail();
  fd = open("/dev/edgetpu", 2);
  put("payload: fd ");
  putdec(fd);
  put("\n");
  if (fd < 0)
    return;
  r = syscall(29, fd, 0xed1a, 0);
  put("payload: wakelock -> ");
  putdec(r);
  put("\n");
  efd = (int)syscall(19, 0, 0);
  ev[1] = efd;
  ioctl(fd, 0x4008ed05, ev);
  r = ioctl(fd, 0x4014ed06, attr);
  put("payload: create_group -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  r = ioctl(fd, 0xed08, 0);
  put("payload: finalize -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  iova = read_cmdq_iova(kfd);
  if (kfd >= 0)
    close(kfd);
  put("payload: cmdq iova ");
  puthex(iova);
  put("\n");
  if (!iova)
    return;
  csr = mmap(0, 0x1000, 3, 1, fd, 0x1800000);
  cq = mmap(0, 24 * 1024, 3, 1, fd, 0x1900000);
  rq = mmap(0, 12 * 1024, 3, 1, fd, 0x1a00000);
  if ((long)csr < 0 || (long)cq < 0 || (long)rq < 0)
    return;
  pl = cq + 0x1000;
  for (i = 0; i < 0x80; i++)
    pl[i] = 0;
  if (p0)
    *(unsigned *)(pl + 0) = p0;
  e = cq;
  for (i = 0; i < 48; i++)
    e[i] = 0;
  *(unsigned long *)(e + 0) = 1;
  *(unsigned short *)(e + 8) = (unsigned short)code;
  e[10] = 0x0b;
  *(unsigned long *)(e + 16) = iova + 0x1000;
  *(unsigned long *)(e + 24) = 0x80;
  put("payload: element");
  for (i = 0; i < 48; i += 4) {
    put(" ");
    puthex(*(unsigned *)(e + i));
  }
  put("\n");
  *(volatile unsigned *)(csr + 12) = 1;
  *(volatile unsigned *)(csr + 0) = 1;
  for (i = 0; i < 400000; i++)
    __asm__ __volatile__("");
  put("payload: rsp");
  for (i = 0; i < 24; i += 4) {
    put(" ");
    puthex(*(unsigned *)(rq + i));
  }
  put("\n");
}

// "mapped": the firmware only accepts a DMA descriptor whose address it can
// reach, and the command queue is not in that set ("Buffer cannot be reached by
// firmware"). EDGETPU_MAP_BUFFER pins a user page and returns the device
// address, so use that for the payload instead.
static void mapped_mode(unsigned code, unsigned p0, const char *file) {
  unsigned plen = 0x80;
  unsigned attr[5] = {24, 12, 48, 24, 0x58};
  int ev[2] = {0, -1};
  unsigned char *page, *csr, *cq, *rq, *e;
  unsigned long map[4];
  int fd, efd, i;
  long r;

  fd = open("/dev/edgetpu", 2);
  put("mapped: fd ");
  putdec(fd);
  put("\n");
  if (fd < 0)
    return;
  r = syscall(29, fd, 0xed1a, 0);
  put("mapped: wakelock -> ");
  putdec(r);
  put("\n");
  efd = (int)syscall(19, 0, 0);
  ev[1] = efd;
  ioctl(fd, 0x4008ed05, ev);
  r = ioctl(fd, 0x4014ed06, attr);
  put("mapped: create_group -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  r = ioctl(fd, 0xed08, 0);
  put("mapped: finalize -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  page = mmap(0, 0x1000, 3, 0x22, -1, 0);
  if ((long)page < 0) {
    put("mapped: page mmap failed\n");
    return;
  }
  for (i = 0; i < 0x1000; i++)
    page[i] = 0;
  if (p0)
    *(unsigned *)(page + 0) = p0;
  if (file) {
    long fsz;
    int ffd = (int)syscall(56, -100, file, 0, 0);

    if (ffd >= 0) {
      fsz = syscall(62, ffd, 0, 2);
      syscall(62, ffd, 0, 0);
      if (fsz > 0 && fsz <= 0x1000 && syscall(63, ffd, page, fsz) == fsz) {
        plen = (unsigned)fsz;
        put("mapped: payload ");
        putdec(plen);
        put(" bytes\n");
      }
      syscall(57, ffd);
    }
  }
  map[0] = (unsigned long)page;
  map[1] = 0x1000;
  map[2] = 0;
  map[3] = 0;
  r = ioctl(fd, 0xc020ed00, map);
  put("mapped: map_buffer -> ");
  putdec(r);
  put(" dev ");
  puthex(map[2]);
  put("\n");
  if (r || !map[2])
    return;
  csr = mmap(0, 0x1000, 3, 1, fd, 0x1800000);
  cq = mmap(0, 24 * 1024, 3, 1, fd, 0x1900000);
  rq = mmap(0, 12 * 1024, 3, 1, fd, 0x1a00000);
  if ((long)csr < 0 || (long)cq < 0 || (long)rq < 0)
    return;
  e = cq;
  for (i = 0; i < 48; i++)
    e[i] = 0;
  *(unsigned long *)(e + 0) = 1;
  *(unsigned short *)(e + 8) = (unsigned short)code;
  e[10] = 0x0b;
  *(unsigned long *)(e + 16) = map[2];
  *(unsigned long *)(e + 24) = plen;
  put("mapped: element");
  for (i = 0; i < 48; i += 4) {
    put(" ");
    puthex(*(unsigned *)(e + i));
  }
  put("\n");
  *(volatile unsigned *)(csr + 12) = 1;
  *(volatile unsigned *)(csr + 0) = 1;
  for (i = 0; i < 400000; i++)
    __asm__ __volatile__("");
  put("mapped: rsp");
  for (i = 0; i < 24; i += 4) {
    put(" ");
    puthex(*(unsigned *)(rq + i));
  }
  put("\n");
}

static void scratch_mode(unsigned code, unsigned flags) {
  unsigned attr[5] = {24, 12, 48, 24, 0x58};
  int ev[2] = {0, -1};
  unsigned char *page, *csr, *cq, *rq, *e;
  unsigned long map[4];
  int fd, efd, i;
  long r;

  fd = open("/dev/edgetpu", 2);
  put("mapped: fd ");
  putdec(fd);
  put("\n");
  if (fd < 0)
    return;
  r = syscall(29, fd, 0xed1a, 0);
  put("mapped: wakelock -> ");
  putdec(r);
  put("\n");
  efd = (int)syscall(19, 0, 0);
  ev[1] = efd;
  ioctl(fd, 0x4008ed05, ev);
  r = ioctl(fd, 0x4014ed06, attr);
  put("mapped: create_group -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  r = ioctl(fd, 0xed08, 0);
  put("mapped: finalize -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  page = mmap(0, 0x1000, 3, 0x22, -1, 0);
  if ((long)page < 0) {
    put("mapped: page mmap failed\n");
    return;
  }
  for (i = 0; i < 0x1000; i++)
    page[i] = 0;
  map[0] = (unsigned long)page;
  map[1] = 0x1000;
  map[2] = 0;
  map[3] = 0;
  r = ioctl(fd, 0xc020ed00, map);
  put("mapped: map_buffer -> ");
  putdec(r);
  put(" dev ");
  puthex(map[2]);
  put("\n");
  if (r || !map[2])
    return;
  /* the setup payload: one global scratch { addr, size } */
  *(unsigned long *)(page + 0) = map[2];
  *(unsigned long *)(page + 8) = 0x1000;
  csr = mmap(0, 0x1000, 3, 1, fd, 0x1800000);
  cq = mmap(0, 24 * 1024, 3, 1, fd, 0x1900000);
  rq = mmap(0, 12 * 1024, 3, 1, fd, 0x1a00000);
  if ((long)csr < 0 || (long)cq < 0 || (long)rq < 0)
    return;
  e = cq;
  for (i = 0; i < 48; i++)
    e[i] = 0;
  *(unsigned long *)(e + 0) = 1;
  *(unsigned short *)(e + 8) = (unsigned short)code;
  e[10] = 0x0b;
  *(unsigned long *)(e + 16) = map[2];
  *(unsigned long *)(e + 24) = 16;
  *(unsigned long *)(e + 28) = flags;
  put("mapped: element");
  for (i = 0; i < 48; i += 4) {
    put(" ");
    puthex(*(unsigned *)(e + i));
  }
  put("\n");
  *(volatile unsigned *)(csr + 12) = 1;
  *(volatile unsigned *)(csr + 0) = 1;
  for (i = 0; i < 400000; i++)
    __asm__ __volatile__("");
  put("mapped: rsp");
  for (i = 0; i < 24; i += 4) {
    put(" ");
    puthex(*(unsigned *)(rq + i));
  }
  put("\n");
}

// "fbsweep FILE": locate the Command flatbuffer's type field and the setup
// type value in one group. The captured runtime payload (FILE, the sync
// command the firmware rejects with "Setup is not done yet ... type 0") is
// pinned with EDGETPU_MAP_BUFFER and submitted element by element: first
// unmutated (the baseline response), then with one byte at a time replaced by
// the marker 0x5a, then with candidate type values 1..64 at every position
// whose marker changed the response's error word. The firmware's own log
// ("... received a command of type N") in dmesg names the type field once the
// run is over; the response words here name it during the run. Sequential
// submit/drain: poll the cmd-queue head CSR (csr+8) and read the response at
// rq + (k % 512) * 24.
static unsigned char *g_csr, *g_cq, *g_rq;
static unsigned char *g_log;
static unsigned g_idx;
static int g_kmsg = -1;

static int haslen(const char *s, int n, const char *kw) {
  int i, k;

  for (i = 0; i < n; i++) {
    for (k = 0; kw[k] && i + k < n && s[i + k] == kw[k]; k++)
      ;
    if (!kw[k])
      return 1;
  }
  return 0;
}

// Scan the firmware log ring for readable messages. The driver's own printer
// is ratelimited, but the ring keeps the entries.
static void fwlog_scan_g(unsigned char *g_log) {
  int i, start, n;
  static const char *kw[] = {"command of type", "Setup", "scratch", "parse",
                             "vii_", "Unknown", "tracker", 0};

  if (!g_log)
    return;
  {
    unsigned t = *(unsigned *)(g_log + 0x40);
    unsigned lim;

    put("fwlog head ");
    puthex(*(unsigned *)(g_log + 0));
    put(" tail ");
    puthex(t);
    put(" dropped ");
    putdec(*(unsigned *)(g_log + 0x44));
    put("\n");
    /* only the region the firmware wrote this boot (single lap) */
    lim = (t & 0xffff);
    if (t & 0x10000)
      lim = 0x10000;
    if (lim < 128) {
      put("fwlog: ring empty this boot\n");
      return;
    }
    if (lim > 0x10000)
      lim = 0x10000;
    for (i = 128; i < (int)lim - 8; i++) {
      if (g_log[i] < 0x20 || g_log[i] >= 0x7f)
        continue;
      start = i;
      while (i < (int)lim && g_log[i] >= 0x20 && g_log[i] < 0x7f)
        i++;
      n = i - start;
      if (n >= 12) {
        int k, hit = 0;
        for (k = 0; kw[k] && !hit; k++)
          hit = haslen((const char *)(g_log + start), n, kw[k]);
        if (hit) {
          put("log@");
          puthex(start);
          put(": ");
          for (k = 0; k < n; k++)
            putc(g_log[start + k]);
          put("\n");
        }
      }
      i--;
    }
  }
}

static int haskw(const char *s) {
  static const char *kw[] = {"command of type", "Setup", "scratch", "parse",
                             "vii_", "tracker", "lockup", 0};
  int i;

  for (i = 0; kw[i]; i++) {
    const char *a = s, *b = kw[i];
    while (*a && *b && *a == *b) {
      a++;
      b++;
    }
    if (!*b)
      return 1;
  }
  return 0;
}

// Consume /dev/kmsg and print only firmware-relevant records, so the ring
// buffer does not overflow mid-run and the per-command log stays in order.
static void kmsg_drain(void) {
  static char buf[8192];
  long n;
  char *p, *nl;

  if (g_kmsg < 0)
    return;
  for (;;) {
    n = syscall(63, g_kmsg, buf, sizeof(buf) - 1);
    if (n <= 0)
      break;
    buf[n] = 0;
    p = buf;
    while (p && *p) {
      nl = p;
      while (*nl && *nl != '\n')
        nl++;
      if (*nl)
        *nl = 0;
      if (haskw(p)) {
        put("fw: ");
        put(p);
        put("\n");
      }
      p = *nl ? nl + 1 : 0;
    }
  }
}

static void submit_elem(const unsigned char *elem) {
  unsigned char *e = g_cq + (g_idx % 512) * 48;
  struct { long s, ns; } ts = {0, 1000000}; /* 1 ms */
  int k, w;

  for (k = 0; k < 48; k++)
    e[k] = elem[k];
  *(volatile unsigned *)(g_csr + 12) = g_idx + 1; /* tail */
  *(volatile unsigned *)(g_csr + 0) = 1;           /* doorbell */
  /* wait for this element's response: the firmware echoes the seq in
     response word 0 at slot (seq-1) % 512 */
  for (w = 0; w < 400; w++) {
    if (*(volatile unsigned *)(g_rq + (g_idx % 512) * 24) == g_idx + 1)
      break;
    syscall(101, &ts, 0); /* nanosleep */
  }
  put("k=");
  putdec(g_idx);
  if (w == 400)
    put(" TIMEOUT");
  put(" rsp");
  for (k = 0; k < 24; k += 4) {
    put(" ");
    puthex(*(unsigned *)(g_rq + (g_idx % 512) * 24 + k));
  }
  put("\n");
  kmsg_drain();
  g_idx++;
}

static void make_elem(unsigned char *e, unsigned code, unsigned prio,
                      unsigned long dma, unsigned long size) {
  int k;

  for (k = 0; k < 48; k++)
    e[k] = 0;
  *(unsigned long *)(e + 0) = g_idx + 1;
  *(unsigned short *)(e + 8) = (unsigned short)code;
  e[10] = (unsigned char)prio;
  *(unsigned long *)(e + 16) = dma;
  *(unsigned *)(e + 24) = (unsigned)size;
  *(unsigned *)(e + 28) = 0;
}

static void fbsweep_mode(const char *file) {
  unsigned attr[5] = {24, 12, 48, 24, 0x58};
  int ev[2] = {0, -1};
  static unsigned char base[0x1000];
  unsigned char elem[48];
  unsigned char *page;
  unsigned long map[4];
  unsigned plen = 0;
  unsigned base_err;
  int changed[64];
  int nchanged = 0;
  int fd, efd, i, v;
  long r;

  fd = open("/dev/edgetpu", 2);
  put("fbsweep: fd ");
  putdec(fd);
  put("\n");
  if (fd < 0)
    return;
  r = syscall(29, fd, 0xed1a, 0);
  put("fbsweep: wakelock -> ");
  putdec(r);
  put("\n");
  efd = (int)syscall(19, 0, 0);
  ev[1] = efd;
  ioctl(fd, 0x4008ed05, ev);
  r = ioctl(fd, 0x4014ed06, attr);
  put("fbsweep: create_group -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  r = ioctl(fd, 0xed08, 0);
  put("fbsweep: finalize -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  page = mmap(0, 0x1000, 3, 0x22, -1, 0);
  if ((long)page < 0) {
    put("fbsweep: page mmap failed\n");
    return;
  }
  for (i = 0; i < 0x1000; i++)
    page[i] = 0;
  if (file) {
    long fsz;
    int ffd = (int)syscall(56, -100, file, 0, 0);

    if (ffd >= 0) {
      fsz = syscall(62, ffd, 0, 2);
      syscall(62, ffd, 0, 0);
      if (fsz > 0 && fsz <= 0x1000 && syscall(63, ffd, page, fsz) == fsz) {
        plen = (unsigned)fsz;
        for (i = 0; i < (int)plen; i++)
          base[i] = page[i];
        put("fbsweep: payload ");
        putdec(plen);
        put(" bytes:");
        for (i = 0; i < (int)plen; i += 4) {
          put(" ");
          puthex(*(unsigned *)(base + i));
        }
        put("\n");
      }
      syscall(57, ffd);
    }
  }
  if (!plen)
    plen = 0x80;
  map[0] = (unsigned long)page;
  map[1] = 0x1000;
  map[2] = 0;
  map[3] = 0;
  r = ioctl(fd, 0xc020ed00, map);
  put("fbsweep: map_buffer -> ");
  putdec(r);
  put(" dev ");
  puthex(map[2]);
  put("\n");
  if (r || !map[2])
    return;
  g_csr = mmap(0, 0x1000, 3, 1, fd, 0x1800000);
  g_cq = mmap(0, 24 * 1024, 3, 1, fd, 0x1900000);
  g_rq = mmap(0, 12 * 1024, 3, 1, fd, 0x1a00000);
  if ((long)g_csr < 0 || (long)g_cq < 0 || (long)g_rq < 0)
    return;
  g_kmsg = (int)syscall(56, -100, "/dev/kmsg", 0x800, 0);
  g_log = mmap(0, 0x10000, 3, 1, fd, 0x1B00000);

  /* baseline: the payload exactly as the runtime sent it */
  for (i = 0; i < (int)plen; i++)
    page[i] = base[i];
  make_elem(elem, 0, 11, map[2], plen);
  submit_elem(elem);
  base_err = *(unsigned *)(g_rq + 8);

  /* phase 1: one marker byte at a time */
  for (i = 0; i < (int)plen && i < 64; i++) {
    for (v = 0; v < (int)plen; v++)
      page[v] = base[v];
    page[i] = 0x5a;
    make_elem(elem, 0, 11, map[2], plen);
    submit_elem(elem);
    if (*(unsigned *)(g_rq + ((g_idx - 1) % 512) * 24 + 8) != base_err &&
        nchanged < 64) {
      changed[nchanged++] = i;
      put("fbsweep: byte ");
      putdec(i);
      put(" changes the response\n");
    }
  }

  /* phase 2: candidate type values at every marker-sensitive position */
  for (i = 0; i < nchanged && g_idx < 200; i++) {
    for (v = 1; v <= 64 && g_idx < 200; v++) {
      int p = changed[i];

      for (r = 0; r < (int)plen; r++)
        page[r] = base[r];
      page[p] = (unsigned char)v;
      make_elem(elem, 0, 11, map[2], plen);
      submit_elem(elem);
    }
  }
  put("fbsweep: done, submissions ");
  putdec(g_idx);
  put("\n");
  fwlog_scan_g(g_log);
}

// "elsweep": submit the captured payload with the element command code at +8
// swept 0..79 (the firmware's "command of type %d" is this field), one at a
// time, serialized. The setup type is in there; its response error word should
// differ from 0xf000009.
static void elsweep_mode(const char *file) {
  unsigned attr[5] = {24, 12, 48, 24, 0x58};
  int ev[2] = {0, -1};
  static unsigned char base[0x1000];
  unsigned char elem[48];
  unsigned char *page;
  unsigned long map[4];
  unsigned plen = 0;
  int fd, efd, i, code;
  long r;

  fd = open("/dev/edgetpu", 2);
  if (fd < 0)
    return;
  syscall(29, fd, 0xed1a, 0);
  efd = (int)syscall(19, 0, 0);
  ev[1] = efd;
  ioctl(fd, 0x4008ed05, ev);
  r = ioctl(fd, 0x4014ed06, attr);
  put("elsweep: create_group -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  r = ioctl(fd, 0xed08, 0);
  if (r)
    return;
  page = mmap(0, 0x1000, 3, 0x22, -1, 0);
  if ((long)page < 0)
    return;
  for (i = 0; i < 0x1000; i++)
    page[i] = 0;
  if (file) {
    long fsz;
    int ffd = (int)syscall(56, -100, file, 0, 0);

    if (ffd >= 0) {
      fsz = syscall(62, ffd, 0, 2);
      syscall(62, ffd, 0, 0);
      if (fsz > 0 && fsz <= 0x1000 && syscall(63, ffd, page, fsz) == fsz) {
        plen = (unsigned)fsz;
        for (i = 0; i < (int)plen; i++)
          base[i] = page[i];
      }
      syscall(57, ffd);
    }
  }
  if (!plen)
    plen = 0x80;
  map[0] = (unsigned long)page;
  map[1] = 0x1000;
  map[2] = 0;
  map[3] = 0;
  r = ioctl(fd, 0xc020ed00, map);
  put("elsweep: map_buffer -> ");
  putdec(r);
  put(" dev ");
  puthex(map[2]);
  put("\n");
  if (r || !map[2])
    return;
  g_csr = mmap(0, 0x1000, 3, 1, fd, 0x1800000);
  g_cq = mmap(0, 24 * 1024, 3, 1, fd, 0x1900000);
  g_rq = mmap(0, 12 * 1024, 3, 1, fd, 0x1a00000);
  if ((long)g_csr < 0 || (long)g_cq < 0 || (long)g_rq < 0)
    return;
  g_kmsg = (int)syscall(56, -100, "/dev/kmsg", 0x800, 0);
  g_log = mmap(0, 0x10000, 3, 1, fd, 0x1B00000);
  for (i = 0; i < (int)plen; i++)
    page[i] = base[i];
  for (code = 0; code <= 199 && g_idx < 240; code++) {
    make_elem(elem, (unsigned)code, 11, map[2], plen);
    submit_elem(elem);
  }
  put("elsweep: done, submissions ");
  putdec(g_idx);
  put("\n");
  fwlog_scan_g(g_log);
}

// "typesweep": craft a Command flatbuffer whose scalar fields f1..f8 (u8) all
// carry a candidate type value v, f0 (u64) a marker, and sweep v = 1..200.
// payload.bin's table only has 3 fields, so its type field is absent (=0);
// this adds the fields. Any v that is the setup type should change the
// response away from 0xf000009 and the ring log line.
static void typesweep_mode(void) {
  unsigned attr[5] = {24, 12, 48, 24, 0x58};
  int ev[2] = {0, -1};
  unsigned char elem[48];
  unsigned char *page;
  unsigned long map[4];
  int fd, efd, v, k;
  long r;

  fd = open("/dev/edgetpu", 2);
  if (fd < 0)
    return;
  syscall(29, fd, 0xed1a, 0);
  efd = (int)syscall(19, 0, 0);
  ev[1] = efd;
  ioctl(fd, 0x4008ed05, ev);
  r = ioctl(fd, 0x4014ed06, attr);
  put("typesweep: create_group -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  r = ioctl(fd, 0xed08, 0);
  put("typesweep: finalize -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  page = mmap(0, 0x1000, 3, 0x22, -1, 0);
  if ((long)page < 0)
    return;
  map[0] = (unsigned long)page;
  map[1] = 0x1000;
  map[2] = 0;
  map[3] = 0;
  r = ioctl(fd, 0xc020ed00, map);
  put("typesweep: map_buffer -> ");
  putdec(r);
  put(" dev ");
  puthex(map[2]);
  put("\n");
  if (r || !map[2])
    return;
  g_csr = mmap(0, 0x1000, 3, 1, fd, 0x1800000);
  g_cq = mmap(0, 24 * 1024, 3, 1, fd, 0x1900000);
  g_rq = mmap(0, 12 * 1024, 3, 1, fd, 0x1a00000);
  g_log = mmap(0, 0x10000, 3, 1, fd, 0x1B00000);
  if ((long)g_csr < 0 || (long)g_cq < 0 || (long)g_rq < 0)
    return;
  for (v = 1; v <= 200 && g_idx < 240; v++) {
    for (k = 0; k < 64; k++)
      page[k] = 0;
    *(unsigned *)(page + 0) = 0x20;            /* root uoffset -> table @0x20 */
    *(unsigned short *)(page + 4) = 22;        /* vtable size */
    *(unsigned short *)(page + 6) = 24;        /* table size */
    *(unsigned short *)(page + 8) = 8;         /* f0 offset (u64) */
    for (k = 1; k <= 8; k++)
      *(unsigned short *)(page + 8 + 2 * k) = 15 + k; /* f1..f8 u8 @+16..+23 */
    *(unsigned *)(page + 0x20) = 0x20 - 0x04;  /* soffset to vtable @0x04 */
    *(unsigned long *)(page + 0x28) = 0x1000 + v; /* f0 */
    for (k = 0; k < 8; k++)
      page[0x30 + k] = (unsigned char)v;      /* f1..f8 */
    make_elem(elem, 0, 11, map[2], 64);
    submit_elem(elem);
    if (*(unsigned *)(g_rq + ((g_idx - 1) % 512) * 24 + 8) != 0xf000009) {
      put("typesweep: v=");
      putdec(v);
      put(" response changed!\n");
    }
  }
  put("typesweep: done, submissions ");
  putdec(g_idx);
  put("\n");
  fwlog_scan_g(g_log);
}

// "e12sweep": submit the captured payload as DMA but sweep the element's u32
// at +12 (never swept before; the HAL's one captured command had +12 =
// 0x35614856). Also submits one element whose DMA iova is unmapped to see
// whether the firmware logs a reachability/parse error instead of the gate.
static void e12sweep_mode(const char *file) {
  unsigned attr[5] = {24, 12, 48, 24, 0x58};
  int ev[2] = {0, -1};
  static unsigned char base[0x1000];
  unsigned char elem[48];
  unsigned char *page;
  unsigned long map[4];
  unsigned plen = 0;
  int fd, efd, i, v;
  long r;

  fd = open("/dev/edgetpu", 2);
  if (fd < 0)
    return;
  syscall(29, fd, 0xed1a, 0);
  efd = (int)syscall(19, 0, 0);
  ev[1] = efd;
  ioctl(fd, 0x4008ed05, ev);
  r = ioctl(fd, 0x4014ed06, attr);
  put("e12sweep: create_group -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  r = ioctl(fd, 0xed08, 0);
  put("e12sweep: finalize -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  page = mmap(0, 0x1000, 3, 0x22, -1, 0);
  if ((long)page < 0)
    return;
  for (i = 0; i < 0x1000; i++)
    page[i] = 0;
  if (file) {
    long fsz;
    int ffd = (int)syscall(56, -100, file, 0, 0);

    if (ffd >= 0) {
      fsz = syscall(62, ffd, 0, 2);
      syscall(62, ffd, 0, 0);
      if (fsz > 0 && fsz <= 0x1000 && syscall(63, ffd, page, fsz) == fsz) {
        plen = (unsigned)fsz;
        for (i = 0; i < (int)plen; i++)
          base[i] = page[i];
      }
      syscall(57, ffd);
    }
  }
  if (!plen)
    plen = 0x80;
  map[0] = (unsigned long)page;
  map[1] = 0x1000;
  map[2] = 0;
  map[3] = 0;
  r = ioctl(fd, 0xc020ed00, map);
  put("e12sweep: map_buffer -> ");
  putdec(r);
  put(" dev ");
  puthex(map[2]);
  put("\n");
  if (r || !map[2])
    return;
  g_csr = mmap(0, 0x1000, 3, 1, fd, 0x1800000);
  g_cq = mmap(0, 24 * 1024, 3, 1, fd, 0x1900000);
  g_rq = mmap(0, 12 * 1024, 3, 1, fd, 0x1a00000);
  g_kmsg = (int)syscall(56, -100, "/dev/kmsg", 0x800, 0);
  g_log = mmap(0, 0x10000, 3, 1, fd, 0x1B00000);
  if ((long)g_csr < 0 || (long)g_cq < 0 || (long)g_rq < 0)
    return;
  for (i = 0; i < (int)plen; i++)
    page[i] = base[i];
  make_elem(elem, 0, 11, map[2], plen);
  submit_elem(elem);
  for (v = 1; v <= 200 && g_idx < 240; v++) {
    make_elem(elem, 0, 11, map[2], plen);
    *(unsigned *)(elem + 12) = (unsigned)v;
    submit_elem(elem);
    if (*(unsigned *)(g_rq + ((g_idx - 1) % 512) * 24 + 8) != 0xf000009) {
      put("e12sweep: v=");
      putdec(v);
      put(" response changed!\n");
    }
  }
  /* unmapped iova: does the firmware log a reachability/parse error? */
  make_elem(elem, 0, 11, 0xdeadbee000UL, 64);
  submit_elem(elem);
  put("e12sweep: unmapped-iova response word2 ");
  puthex(*(unsigned *)(g_rq + ((g_idx - 1) % 512) * 24 + 8));
  put("\n");
  put("e12sweep: done, submissions ");
  putdec(g_idx);
  put("\n");
  fwlog_scan_g(g_log);
}

// "gate2 [payload]": one boot, one device create, four phases against the
// VII setup gate:
//  A baseline: captured payload on a host MAP_BUFFER page, code 0 prio 11
//  B element +12 swept as u32 v=1..200 with the same payload as DMA
//  C one element with an unmapped iova (0xdeadbee000) to provoke a
//    reachability/parse log line
//  D the captured payload inside a dma-buf (dma_heap/system) mapped with
//    EDGETPU_MAP_DMABUF (the runtime's 0xffeff000 address class)
//  E a crafted Command flatbuffer (f0 u64 marker, f1..f15 u8 = v) inside the
//    same dma-buf, swept v=1..200
// Any response word2 != 0xf000009 or a changed ring line is reported.
static void gate2_mode(const char *file) {
  unsigned attr[5] = {24, 12, 48, 24, 0x58};
  int ev[2] = {0, -1};
  static unsigned char base[0x1000];
  unsigned char elem[48];
  unsigned char *page, *dbuf;
  unsigned long map[4];
  unsigned long dmap[5];
  unsigned plen = 0;
  int fd, efd, i, v, k, dfd = -1;
  long r;

  fd = open("/dev/edgetpu", 2);
  if (fd < 0)
    return;
  syscall(29, fd, 0xed1a, 0);
  efd = (int)syscall(19, 0, 0);
  ev[1] = efd;
  ioctl(fd, 0x4008ed05, ev);
  r = ioctl(fd, 0x4014ed06, attr);
  put("gate2: create_group -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  r = ioctl(fd, 0xed08, 0);
  put("gate2: finalize -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  page = mmap(0, 0x1000, 3, 0x22, -1, 0);
  if ((long)page < 0)
    return;
  for (i = 0; i < 0x1000; i++)
    page[i] = 0;
  if (file) {
    long fsz;
    int ffd = (int)syscall(56, -100, file, 0, 0);

    if (ffd >= 0) {
      fsz = syscall(62, ffd, 0, 2);
      syscall(62, ffd, 0, 0);
      if (fsz > 0 && fsz <= 0x1000 && syscall(63, ffd, page, fsz) == fsz) {
        plen = (unsigned)fsz;
        for (i = 0; i < (int)plen; i++)
          base[i] = page[i];
      }
      syscall(57, ffd);
    }
  }
  if (!plen)
    plen = 0x80;
  map[0] = (unsigned long)page;
  map[1] = 0x1000;
  map[2] = 0;
  map[3] = 0;
  r = ioctl(fd, 0xc020ed00, map);
  put("gate2: map_buffer -> ");
  putdec(r);
  put(" dev ");
  puthex(map[2]);
  put("\n");
  if (r || !map[2])
    return;
  g_csr = mmap(0, 0x1000, 3, 1, fd, 0x1800000);
  g_cq = mmap(0, 24 * 1024, 3, 1, fd, 0x1900000);
  g_rq = mmap(0, 12 * 1024, 3, 1, fd, 0x1a00000);
  g_kmsg = (int)syscall(56, -100, "/dev/kmsg", 0x800, 0);
  g_log = mmap(0, 0x10000, 3, 1, fd, 0x1B00000);
  if ((long)g_csr < 0 || (long)g_cq < 0 || (long)g_rq < 0)
    return;

  /* phase A: baseline */
  for (i = 0; i < (int)plen; i++)
    page[i] = base[i];
  make_elem(elem, 0, 11, map[2], plen);
  submit_elem(elem);
  put("gate2: A baseline rsp word2 ");
  puthex(*(unsigned *)(g_rq + ((g_idx - 1) % 512) * 24 + 8));
  put("\n");

  /* phase B: element +12 swept as u32 */
  for (v = 1; v <= 200 && g_idx < 260; v++) {
    make_elem(elem, 0, 11, map[2], plen);
    *(unsigned *)(elem + 12) = (unsigned)v;
    submit_elem(elem);
    if (*(unsigned *)(g_rq + ((g_idx - 1) % 512) * 24 + 8) != 0xf000009) {
      put("gate2: B v=");
      putdec(v);
      put(" response changed!\n");
    }
  }
  put("gate2: B done, submissions ");
  putdec(g_idx);
  put("\n");
  fwlog_scan_g(g_log);

  /* phase C: unmapped iova */
  make_elem(elem, 0, 11, 0xdeadbee000UL, 64);
  submit_elem(elem);
  put("gate2: C unmapped rsp word2 ");
  puthex(*(unsigned *)(g_rq + ((g_idx - 1) % 512) * 24 + 8));
  put("\n");
  fwlog_scan_g(g_log);

  /* phase D: dma-buf mapped payload (runtime's address class) */
  {
    unsigned long alloc[3];
    int hfd = (int)syscall(56, -100, "/dev/dma_heap/system", 2, 0);

    if (hfd >= 0) {
      alloc[0] = 0x1000;   /* len */
      alloc[1] = ((unsigned long)0x80002 << 32); /* fd out (low), fd_flags O_RDWR|O_CLOEXEC (high) */
      alloc[2] = 0;        /* heap_flags */
      r = ioctl(hfd, 0xc0184200UL, alloc);
      put("gate2: dma_heap alloc -> ");
      putdec(r);
      put(" fd ");
      putdec((int)(alloc[1] & 0xffffffff));
      put("\n");
      if (r == 0) {
        dfd = (int)(alloc[1] & 0xffffffff);
        dbuf = mmap(0, 0x1000, 3, 1, dfd, 0);
        put("gate2: dbuf mmap ");
        puthex((unsigned long)dbuf);
        put("\n");
        if ((long)dbuf > 0) {
          for (i = 0; i < 0x1000; i++)
            dbuf[i] = 0;
          for (i = 0; i < (int)plen; i++)
            dbuf[i] = base[i];
          dmap[0] = 0;        /* offset (ignored) */
          dmap[1] = 0x1000;   /* size (ignored) */
          dmap[2] = 0;        /* device_address out */
          dmap[3] = (unsigned long)(unsigned)dfd; /* dmabuf_fd + flags(0) */
          dmap[4] = 0;        /* die_index */
          r = ioctl(fd, 0xc028ed11UL, dmap);
          put("gate2: map_dmabuf -> ");
          putdec(r);
          put(" dev ");
          puthex(dmap[2]);
          put("\n");
          if (r == 0 && dmap[2]) {
            make_elem(elem, 0, 11, dmap[2], plen);
            submit_elem(elem);
            put("gate2: D dmabuf-payload rsp word2 ");
            puthex(*(unsigned *)(g_rq + ((g_idx - 1) % 512) * 24 + 8));
            put("\n");
            fwlog_scan_g(g_log);
            /* phase E: crafted Command in the dma-buf, f1..f15 = v */
            for (v = 1; v <= 200 && g_idx < 500; v++) {
              for (k = 0; k < 0x80; k++)
                dbuf[k] = 0;
              *(unsigned *)(dbuf + 0) = 0x40;         /* root -> table @0x40 */
              *(unsigned short *)(dbuf + 4) = 36;     /* vtable size */
              *(unsigned short *)(dbuf + 6) = 32;     /* table size */
              *(unsigned short *)(dbuf + 8) = 8;      /* f0 u64 @ table+8 */
              for (k = 1; k <= 15; k++)
                *(unsigned short *)(dbuf + 8 + 2 * k) = 15 + k; /* f1..f15 */
              *(unsigned *)(dbuf + 0x40) = 0x40 - 0x04; /* soffset to vtable */
              *(unsigned long *)(dbuf + 0x48) = 0x1000 + v; /* f0 marker */
              for (k = 0; k < 15; k++)
                dbuf[0x50 + k] = (unsigned char)v;   /* f1..f15 */
              make_elem(elem, 0, 11, dmap[2], 0x60);
              submit_elem(elem);
              if (*(unsigned *)(g_rq + ((g_idx - 1) % 512) * 24 + 8) != 0xf000009) {
                put("gate2: E v=");
                putdec(v);
                put(" response changed!\n");
              }
            }
            put("gate2: E done, submissions ");
            putdec(g_idx);
            put("\n");
            fwlog_scan_g(g_log);
          }
        }
      }
      syscall(57, hfd);
    } else {
      put("gate2: no /dev/dma_heap/system\n");
    }
  }
  put("gate2: done, submissions ");
  putdec(g_idx);
  put("\n");
  fwlog_scan_g(g_log);
}

// The firmware's log is the only oracle for the payload schema: it parses the
// 48-byte element's payload as a Command flatbuffer and logs the *parsed* type
// ("Setup is not done yet received a command of type %d."), or "Could not
// parse Command flatbuffer." when the payload does not verify. Identical lines
// are deduplicated, so a changed type or a parse failure always shows up as a
// new tail entry.
static int hasat(const unsigned char *s, int n, const char *kw) {
  int k;

  for (k = 0; kw[k] && k < n; k++)
    if (s[k] != (unsigned char)kw[k])
      return 0;
  return !kw[k];
}

// Scan the firmware ring for the newest "command of type N" and for the parse
// error. Returns the last type printed this boot, or -1 when there is none.
static int ring_type(int *parse_err) {
  unsigned t;
  int i, lim, last = -1;

  if (parse_err)
    *parse_err = 0;
  if (!g_log)
    return -1;
  t = *(unsigned *)(g_log + 0x40);
  lim = (int)(t & 0xffff);
  if (lim < 128)
    return -1;
  if (lim > 0x10000)
    lim = 0x10000;
  for (i = 128; i < lim - 4; i++) {
    if (hasat(g_log + i, lim - i, "command of type ")) {
      int v = 0, k = i + 16;

      while (k < lim && g_log[k] >= '0' && g_log[k] <= '9') {
        v = v * 10 + (g_log[k] - '0');
        k++;
      }
      last = v;
      i = k;
    } else if (parse_err && hasat(g_log + i, lim - i, "Could not parse")) {
      *parse_err = 1;
    }
  }
  return last;
}

// Build a Command flatbuffer with NFIELDS scalar fields, so the firmware's
// "type %d" names whichever vtable slot its schema reads as the command type:
// with every field set to i+1, the printed type is (field index + 1). The
// fields are u16 (an 8-bit enum still reads its low byte). Layout: root uoffset
// at 0, vtable at 4, table at 0x48, field i at table+4+4*i.
#define CMD_NFIELDS 32
#define CMD_TABLE 0x48
#define CMD_VT 0x04
#define CMD_LEN (CMD_TABLE + 4 + 4 * CMD_NFIELDS)
static void cmd_build(unsigned char *b, int field, unsigned value) {
  int i;

  for (i = 0; i < CMD_LEN; i++)
    b[i] = 0;
  *(unsigned *)(b + 0) = CMD_TABLE;
  *(unsigned short *)(b + CMD_VT + 0) = (unsigned short)(4 + 2 * CMD_NFIELDS);
  *(unsigned short *)(b + CMD_VT + 2) = (unsigned short)(4 + 4 * CMD_NFIELDS);
  for (i = 0; i < CMD_NFIELDS; i++)
    *(unsigned short *)(b + CMD_VT + 4 + 2 * i) = (unsigned short)(4 + 4 * i);
  *(unsigned *)(b + CMD_TABLE) = CMD_TABLE - CMD_VT;
  if (field >= 0 && field < CMD_NFIELDS)
    *(unsigned short *)(b + CMD_TABLE + 4 + 4 * field) = (unsigned short)value;
}

// "cmdsweep [payload]": locate the Command flatbuffer's type field and the
// setup type in one group, with the firmware's own log line as the read-back.
//   A  the captured runtime payload (baseline: expect "type 0")
//   B  every field i = (i % 24) + 1, then i = (i * 7 % 24) + 1; the two answers
//      name the type field by elimination
//   C  the found field swept 0..24 (the runtime's whole command table); a setup
//      type that clears the gate answers with a different error and the
//      firmware's own strings ("No global scratches were provided in setup
//      command.") instead of the gate line
//   D  if B reads 0 for both patterns, each field alone with 1
static void cmdsweep_mode(const char *file) {
  unsigned attr[5] = {24, 12, 48, 24, 0x58};
  int ev[2] = {0, -1};
  static unsigned char base[0x1000];
  unsigned char elem[48];
  unsigned char *page;
  unsigned long map[4];
  unsigned plen = 0;
  int t1, t2, pe, field = -1, fd, efd, i, v;
  long r;

  fd = open("/dev/edgetpu", 2);
  put("cmdsweep: fd ");
  putdec(fd);
  put("\n");
  if (fd < 0)
    return;
  syscall(29, fd, 0xed1a, 0);
  efd = (int)syscall(19, 0, 0);
  ev[1] = efd;
  ioctl(fd, 0x4008ed05, ev);
  r = ioctl(fd, 0x4014ed06, attr);
  put("cmdsweep: create_group -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  r = ioctl(fd, 0xed08, 0);
  put("cmdsweep: finalize -> ");
  putdec(r);
  put("\n");
  if (r)
    return;
  page = mmap(0, 0x1000, 3, 0x22, -1, 0);
  if ((long)page < 0)
    return;
  for (i = 0; i < 0x1000; i++)
    page[i] = 0;
  map[0] = (unsigned long)page;
  map[1] = 0x1000;
  map[2] = 0;
  map[3] = 0;
  r = ioctl(fd, 0xc020ed00, map);
  put("cmdsweep: map_buffer -> ");
  putdec(r);
  put(" dev ");
  puthex(map[2]);
  put("\n");
  if (r || !map[2])
    return;
  g_csr = mmap(0, 0x1000, 3, 1, fd, 0x1800000);
  g_cq = mmap(0, 24 * 1024, 3, 1, fd, 0x1900000);
  g_rq = mmap(0, 12 * 1024, 3, 1, fd, 0x1a00000);
  g_kmsg = (int)syscall(56, -100, "/dev/kmsg", 0x800, 0);
  g_log = mmap(0, 0x10000, 3, 1, fd, 0x1B00000);
  if ((long)g_csr < 0 || (long)g_cq < 0 || (long)g_rq < 0)
    return;

  /* A: the runtime's own sync payload, the baseline the firmware logs as 0 */
  if (file) {
    long fsz;
    int ffd = (int)syscall(56, -100, file, 0, 0);

    if (ffd >= 0) {
      fsz = syscall(62, ffd, 0, 2);
      syscall(62, ffd, 0, 0);
      if (fsz > 0 && fsz <= 0x1000 && syscall(63, ffd, page, fsz) == fsz)
        plen = (unsigned)fsz;
      syscall(57, ffd);
    }
    if (plen) {
      make_elem(elem, 0, 11, map[2], plen);
      submit_elem(elem);
      put("cmdsweep: A baseline ring type ");
      putdec(ring_type(&pe));
      put(pe ? " (parse error seen)\n" : "\n");
    }
  }

  /* B: two patterns over 32 fields, all set at once */
  cmd_build(page, -1, 0);
  for (i = 0; i < CMD_NFIELDS; i++)
    *(unsigned short *)(page + CMD_TABLE + 4 + 4 * i) =
        (unsigned short)((i % 24) + 1);
  make_elem(elem, 0, 11, map[2], CMD_LEN);
  submit_elem(elem);
  t1 = ring_type(&pe);
  put("cmdsweep: B1 ring type ");
  putdec(t1);
  put(pe ? " (parse error seen)\n" : "\n");

  cmd_build(page, -1, 0);
  for (i = 0; i < CMD_NFIELDS; i++)
    *(unsigned short *)(page + CMD_TABLE + 4 + 4 * i) =
        (unsigned short)(((i * 7) % 24) + 1);
  make_elem(elem, 0, 11, map[2], CMD_LEN);
  submit_elem(elem);
  t2 = ring_type(&pe);
  put("cmdsweep: B2 ring type ");
  putdec(t2);
  put(pe ? " (parse error seen)\n" : "\n");

  if (t1 > 0 && t1 <= CMD_NFIELDS && t2 > 0 && t2 <= 24) {
    for (i = 0; i < CMD_NFIELDS; i++) {
      if ((i % 24) + 1 == t1 && ((i * 7) % 24) + 1 == t2) {
        field = i;
        break;
      }
    }
  }
  put("cmdsweep: type field ");
  putdec(field);
  put("\n");

  /* C: sweep the found field through the runtime's command table */
  if (field >= 0) {
    for (v = 0; v <= 24 && g_idx < 60; v++) {
      cmd_build(page, field, (unsigned)v);
      make_elem(elem, 0, 11, map[2], CMD_LEN);
      submit_elem(elem);
      put("cmdsweep: C v=");
      putdec(v);
      put(" ring ");
      putdec(ring_type(&pe));
      put("\n");
      if (*(unsigned *)(g_rq + ((g_idx - 1) % 512) * 24 + 8) != 0xf000009)
        put("cmdsweep: C response changed!\n");
    }
  } else {
    /* D: no single-field answer; try each field alone with 1 */
    for (i = 0; i < CMD_NFIELDS; i++) {
      cmd_build(page, i, 1);
      make_elem(elem, 0, 11, map[2], CMD_LEN);
      submit_elem(elem);
      put("cmdsweep: D field ");
      putdec(i);
      put(" ring ");
      putdec(ring_type(&pe));
      put("\n");
    }
  }
  put("cmdsweep: done, submissions ");
  putdec(g_idx);
  put("\n");
  fwlog_scan_g(g_log);
}

// Dumps the VII queues of the group the HAL created, from inside the same
// process: the queues are per-fd, so only a thread that shares the HAL's fd can
// see what it wrote before it blocked.
extern int pthread_create(unsigned long *, const void *, void *(*)(void *),
                            void *);

static void *queue_watch(void *arg) {
  struct {
    long sec;
    long nsec;
  } ts = {10, 0};
  unsigned *csr, *cq, *rq;
  int fd, i;

  (void)arg;
  syscall(101, &ts, 0); /* nanosleep */
  fd = tpu_fd;
  if (fd < 0) {
    put("watch: no /dev/edgetpu fd\n");
    return 0;
  }
  csr = mmap(0, 0x1000, 3, 1, fd, 0x1800000);
  cq = mmap(0, 24 * 1024, 3, 1, fd, 0x1900000);
  rq = mmap(0, 12 * 1024, 3, 1, fd, 0x1a00000);
  (void)csr;
  put("watch: cq ");
  puthex((unsigned long)cq);
  put(" rq ");
  puthex((unsigned long)rq);
  for (i = 0; i < 12; i++) {
    put(" ");
    puthex(cq[i]);
  }
  put("\nwatch: rq");
  for (i = 0; i < 8; i++) {
    put(" ");
    puthex(rq[i]);
  }
  put("\n");
  return 0;
}

// Call into the stock HAL's function table (U7, U11). The AIDL service's main
// calls entry[1] to create the LibDarwinnHal object and entry[3] with it, so
// that pair is the HAL's own initialisation path; if any HAL call opens
// /dev/edgetpu and sends the firmware setup the app runtime never sends, it is
// in this path. "call N A0 A1 A2" reaches any other entry by index.
static void halcall_mode(int argc, char **argv) {
  void **t = GetDarwinnHalFunctions();
  unsigned long h = 0, s = 0;
  long r;

  put("hal table ");
  puthex((unsigned long)t);
  put(" version ");
  putdec((long)(unsigned)((unsigned *)t)[0]);
  put("\n");
  if (argc < 3) {
    put("usage: halcall init | halcall call N [A0 A1 A2]\n");
    return;
  }
  if (streq(argv[2], "init")) {
    r = ((long (*)(unsigned long *))t[1])(&h);
    status("entry[1]", r);
    put("entry[1] out ");
    puthex(h);
    put("\n");
    if (!h) return;
    r = ((long (*)(unsigned long, unsigned long *))t[3])(h, &s);
    status("entry[3]", r);
    put("entry[3] out ");
    puthex(s);
    put("\n");
    return;
  }
  // The AIDL service's main builds this config on the stack and passes it to
  // entry[3]: two ones, the device path, the spawner (zero here) and an fd of
  // -1. Calling entry[3] this way reaches the device creation the service does,
  // without entry[1]'s compiler-spawner setup.
  if (streq(argv[2], "device")) {
    struct {
      unsigned version, flags;
      const char *path;
      unsigned long spawner;
      long fd;
    } cfg = {1, 1, "/dev/edgetpu", 0, -1};

    unsigned long th;

    pthread_create(&th, 0, queue_watch, 0);
    r = ((long (*)(void *, unsigned long *))t[3])(&cfg, &s);
    status("entry[3]", r);
    put("entry[3] out ");
    puthex(s);
    put("\n");
    // Keep the device (and with it the group and the firmware) alive while the
    // log is read: the HAL sends its setup during the device's lifetime.
    if (!r && s) {
      struct {
        long sec;
        long nsec;
      } ts = {argc > 3 ? (long)argdec(argv[3]) : 20, 0};

      put("holding the device open\n");
      syscall(101, &ts, 0); /* nanosleep */
    }
    return;
  }
  if (streq(argv[2], "call") && argc > 3) {
    unsigned idx = (unsigned)argdec(argv[3]);
    unsigned long a0 = argc > 4 ? argdec(argv[4]) : 0;
    unsigned long a1 = argc > 5 ? argdec(argv[5]) : 0;
    unsigned long a2 = argc > 6 ? argdec(argv[6]) : 0;
    long (*fn)(unsigned long, unsigned long, unsigned long) =
        (long (*)(unsigned long, unsigned long, unsigned long))t[idx];

    put("call [");
    putdec(idx);
    put("] ");
    puthex((unsigned long)fn);
    put("(");
    puthex(a0);
    put(" ");
    puthex(a1);
    put(" ");
    puthex(a2);
    put(")\n");
    r = fn(a0, a1, a2);
    status("returns", r);
    put("x0 ");
    puthex((unsigned long)r);
    put("\n");
    return;
  }
  put("halcall: unknown request\n");
}

int main(int argc, char **argv) {
  if (argc > 1 && streq(argv[1], "raw")) {
    raw_mode();
    return 0;
  }
  if (argc > 1 && streq(argv[1], "hold")) {
    hold_mode();
    return 0;
  }
  if (argc > 1 && streq(argv[1], "probe")) {
    probe_mode();
    return 0;
  }
  if (argc > 1 && streq(argv[1], "mapped")) {
    mapped_mode(argc > 2 ? (unsigned)argdec(argv[2]) : 11,
                argc > 3 ? (unsigned)argdec(argv[3]) : 0,
                argc > 4 ? argv[4] : 0);
    return 0;
  }
  if (argc > 1 && streq(argv[1], "payload")) {
    payload_mode(argc > 2 ? (unsigned)argdec(argv[2]) : 11,
                 argc > 3 ? (unsigned)argdec(argv[3]) : 0);
    return 0;
  }
  if (argc > 4 && streq(argv[1], "setup")) {
    setup_mode(argv[2], argv[3], argv[4]);
    return 0;
  }
  if (argc > 1 && streq(argv[1], "fwlog")) {
    int fd = open("/dev/edgetpu", 2);
    unsigned char *lg;
    int i;

    if (fd < 0)
      return 0;
    lg = mmap(0, 0x10000, 3, 1, fd, 0x1B00000);
    put("fwlog mmap ");
    puthex((unsigned long)lg);
    put(" head ");
    puthex(*(unsigned *)(lg + 0));
    put(" tail ");
    puthex(*(unsigned *)(lg + 0x40));
    put(" dropped ");
    putdec(*(unsigned *)(lg + 0x44));
    put("\nhex 0x80..0x200:\n");
    for (i = 0x80; i < 0x200; i += 16) {
      int k;
      puthex(i);
      put(": ");
      for (k = 0; k < 16; k++) {
        char b[3];
        b[0] = "0123456789abcdef"[(lg[i + k] >> 4) & 0xf];
        b[1] = "0123456789abcdef"[lg[i + k] & 0xf];
        b[2] = 0;
        put(b);
        put(" ");
      }
      put("\n");
    }
    fwlog_scan_g(lg);
    return 0;
  }
  if (argc > 2 && streq(argv[1], "fbsweep")) {
    fbsweep_mode(argv[2]);
    return 0;
  }
  if (argc > 2 && streq(argv[1], "elsweep")) {
    elsweep_mode(argv[2]);
    return 0;
  }
  if (argc > 1 && streq(argv[1], "typesweep")) {
    typesweep_mode();
    return 0;
  }
  if (argc > 2 && streq(argv[1], "e12sweep")) {
    e12sweep_mode(argv[2]);
    return 0;
  }
  if (argc > 2 && streq(argv[1], "gate2")) {
    gate2_mode(argv[2]);
    return 0;
  }
  if (argc > 1 && streq(argv[1], "cmdsweep")) {
    cmdsweep_mode(argc > 2 ? argv[2] : 0);
    return 0;
  }
  // "hal": dump the stock HAL function table and exit. Touches no device, so
  // it is safe to run without a fresh boot.
  if (argc > 3 && streq(argv[1], "scratch")) {
    scratch_mode((unsigned)argdec(argv[2]), (unsigned)argdec(argv[3]));
    return 0;
  }
  if (argc > 2 && streq(argv[1], "halcall")) {
    halcall_mode(argc, argv);
    return 0;
  }
  if (argc > 1 && streq(argv[1], "hal")) {
    void **t = GetDarwinnHalFunctions();
    unsigned long base = (unsigned long)GetDarwinnHalFunctions - 0x16946ecUL;
    int i;

    put("hal table ");
    puthex((unsigned long)t);
    put(" base ");
    puthex(base);
    put(" version ");
    putdec((long)(unsigned)((unsigned *)t)[0]);
    put("\n");
    for (i = 0; i < 24; i++) {
      unsigned long v = (unsigned long)t[i];

      put("  [");
      putdec(i);
      put("] ");
      puthex(v);
      if (v > base) {
        put("  off ");
        puthex(v - base);
      }
      put("\n");
    }
    return 0;
  }
  static const char *const paths[] = {"/dev/edgetpu"};
  void *dev = 0, *vd, *factory, *graph = 0;
  SharedPtr buffer = {0, 0};
  long st, size;

  if (argc < 2) {
    put("usage: edgetpu-run MODEL\n");
    return 2;
  }

  int fd = open(argv[1], 0);
  if (fd < 0) {
    put("cannot open ");
    put(argv[1]);
    put("\n");
    return 2;
  }
  size = lseek(fd, 0, 2);
  lseek(fd, 0, 0);
  char *model = malloc((size_t)size);
  if (!model || read(fd, model, (size_t)size) != size) {
    put("cannot read the model\n");
    return 2;
  }
  close(fd);
  put("model bytes: ");
  putdec(size);
  put("\n");

  // The load base of the runtime for a debugger: the library's symbol address
  // minus its file offset (0xf07a0) is where the ELF was mapped.
  put("runtime create fn: ");
  puthex((unsigned long)&DarwinnDelegate_CreateVirtualDevice);
  put("\n");

  // With a second argument "waitdbg" the client stops itself here so gdb can
  // attach and set breakpoints in the runtime before it creates the device.
  if (argc > 2 && argv[2][0] == 'w') {
    put("debug stop\n");
    syscall(129, syscall(172), 19);
  }

  // The runtime builds the virtual device from a device spec: platform, flags,
  // die index, priority, device paths and how many. Ask the runtime for its own
  // default spec instead of hardcoding one; the paths it hands back are what it
  // parses to decide how many chips the device has.
  int sa0 = 0, sa2 = 0, sa3 = 0, sa5 = 0;
  char sa1 = 0;
  const char **dpaths = 0;

  put("call get default device spec\n");
  st = DarwinnDelegate_GetDefaultDeviceSpec(&sa0, &sa1, &sa2, &sa3, &dpaths,
                                            &sa5);
  status("default device spec status", st);
  put("spec: ");
  putdec(sa0);
  put(" ");
  putdec(sa1);
  put(" ");
  putdec(sa2);
  put(" ");
  putdec(sa3);
  put(" paths ");
  putdec(sa5);
  put("\n");
  for (int i = 0; i < sa5 && i < 8 && dpaths; i++) {
    put("  path: ");
    put(dpaths[i]);
    put("\n");
  }

  // The runtime clears firmware_setup_done_ when it releases its firmware
  // wakelock, and only sends the firmware "setup" command when that flag is
  // clear. A failed create still releases the wakelock, so retry: a later
  // attempt can send the setup command the first one skipped.
  for (int attempt = 1; attempt <= 3 && !dev; attempt++) {
    put("call create device, attempt ");
    putdec(attempt);
    put("\n");
    st = DarwinnDelegate_CreateVirtualDevice(sa0, sa1, sa2, sa3, dpaths, sa5,
                                             &dev);
    status("create device status", st);
    dump_maps();
    put("device: ");
    puthex((unsigned long)dev);
    put("\n");
  }
  if (!dev) return 1;

  put("call get virtual device\n");
  vd = DarwinnDelegate_EdgeTpuDevice_GetVirtualDevice(dev);
  put("virtual device: ");
  puthex((unsigned long)vd);
  put("\n");
  if (!vd) return 1;

  put("call get buffer factory\n");
  factory = DarwinnApi2_VirtualDevice_GetBufferFactory(vd);
  put("buffer factory: ");
  puthex((unsigned long)factory);
  put("\n");
  if (!factory) return 1;

  put("call allocate buffer\n");
  st = DarwinnApi2_BufferFactory_AllocateBuffer(factory, (size_t)size, 0, 0,
                                               &buffer);
  status("allocate status", st);
  put("buffer: ");
  puthex((unsigned long)buffer.object);
  put("\n");
  if (!buffer.object) return 1;

  put("call copy\n");
  st = DarwinnApi2_Buffer_CopyFrom(&buffer, model);
  status("copy status", st);

  put("call register graph\n");
  st = DarwinnApi2_VirtualDevice_RegisterGraphByBuffer(vd, &buffer, 0, 0, 0,
                                                       &graph);
  status("register graph status", st);
  put("graph: ");
  puthex((unsigned long)graph);
  put("\n");
  if (!graph) return 1;

  put("inputs: ");
  putdec(DarwinnApi2_Graph_NumInputTensors(graph));
  put("\noutputs: ");
  putdec(DarwinnApi2_Graph_NumOutputTensors(graph));
  put("\n");

  return 0;
}
