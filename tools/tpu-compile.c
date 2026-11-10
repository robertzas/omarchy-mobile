// SPDX-License-Identifier: MIT
// tpu-compile: compile a TFLite model with the stock Edge TPU compiler, on the
// phone, for the Tachyon ring path (TPU-PLAN U167). The stock vendor service
// is the producer of the DGC0 graph container the core's RegisterGraph
// verifier wants; it calls libedgetpu_tflite_compiler.so's C API, and so can
// this client.
//
// Run inside the vendor chroot as root:
//   chroot ROOT /vendor/bin/tpu-compile MODEL OUT [OPTIONS]
//
// The API (signature from the vendor service's call site at 0x4870 and the
// compiler's own mmap at 0x9c5d74):
//   int CompileTfliteFlatbuffer2(int model_fd, size_t model_size,
//                                const char *options, uint32_t options_size,
//                                uint32_t uid, uint32_t *out_size,
//                                void **out_data, char **out_error);
// The model is passed as an open file descriptor: the compiler mmaps it
// (PROT_READ, MAP_SHARED). The compiler frees the output with
// LibEdgetpuTfliteCompilerFree.
typedef unsigned long size_t;
typedef long ssize_t;

extern void __libc_init(void *, void *, int (*)(int, char **, char **), void *);
extern long write(int, const void *, size_t);
extern void *dlopen(const char *, int);
extern void *dlsym(void *, const char *);
extern char *dlerror(void);
extern void _exit(int) __attribute__((noreturn));
extern int open(const char *, int, ...);
extern int close(int);
extern long read(int, void *, size_t);
extern long write(int, const void *, size_t);
extern long lseek(int, long, int);
extern void *malloc(size_t);
extern void free(void *);
extern char *getenv(const char *);
extern void *memset(void *, int, size_t);
extern int mprotect(void *, size_t, int);
extern long syscall(long, ...);

#define RTLD_NOW 2
#define RTLD_LOCAL 0

// bionic's crt is not in the vendor chroot; __libc_init does its job.
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
  write(2, s, n);
}

static void clear_cache(void *start, void *end) {
  unsigned long ctr, dline, iline, p;
  __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
  dline = 4UL << ((ctr >> 16) & 0xf);
  iline = 4UL << (ctr & 0xf);
  for (p = (unsigned long)start & ~(dline - 1); p < (unsigned long)end; p += dline)
    __asm__ volatile("dc cvau, %0" ::"r"(p) : "memory");
  __asm__ volatile("dsb ish" ::: "memory");
  for (p = (unsigned long)start & ~(iline - 1); p < (unsigned long)end; p += iline)
    __asm__ volatile("ic ivau, %0" ::"r"(p) : "memory");
  __asm__ volatile("dsb ish" ::: "memory");
  __asm__ volatile("isb" ::: "memory");
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

static unsigned long filesize(const char *path) {
  int fd = open(path, 0);
  long n;

  if (fd < 0) return 0;
  n = lseek(fd, 0, 2);
  close(fd);
  return n > 0 ? (unsigned long)n : 0;
}

static int slurp(const char *path, char *buf, unsigned long size) {
  int fd = open(path, 0);
  unsigned long done = 0;

  if (fd < 0) return -1;
  while (done < size) {
    long n = read(fd, buf + done, size - done);

    if (n <= 0) break;
    done += n;
  }
  close(fd);
  return done == size ? 0 : -1;
}

static int spill(const char *path, const char *buf, unsigned long size) {
  int fd = open(path, 0x241 /* O_WRONLY|O_CREAT|O_TRUNC */, 0644);
  unsigned long done = 0;

  if (fd < 0) return -1;
  while (done < size) {
    long n = write(fd, buf + done, size - done);

    if (n <= 0) break;
    done += n;
  }
  close(fd);
  return done == size ? 0 : -1;
}

// The compiler asks the property service which SoC it runs on; a chroot has
// none. The vendor runtime expects the Pixel 7 generation's ID.
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

typedef struct {
  const char *dli_fname;
  void *dli_fbase;
  const char *dli_sname;
  void *dli_saddr;
} Dl_info;
extern int dladdr(const void *, Dl_info *);

// Diagnostic: the compiler sometimes ends the process itself (exit 1) before
// returning, and its message goes to a log this chroot has no daemon for. A
// frame-pointer walk shows which library call did it.
static void backtrace_here(void) {
  unsigned long *fp = (unsigned long *)__builtin_frame_address(0);
  int i;

  for (i = 0; i < 16 && fp; i++) {
    unsigned long lr = fp[1];
    Dl_info di;

    put("  lr ");
    puthex(lr);
    if (lr && dladdr((void *)lr, &di)) {
      put(" base ");
      puthex((unsigned long)di.dli_fbase);
      put(" off ");
      puthex(lr - (unsigned long)di.dli_fbase);
      if (di.dli_sname) {
        put(" ");
        put(di.dli_sname);
      }
    }
    put("\n");
    fp = (unsigned long *)fp[0];
  }
}

static void die_now(int status) __attribute__((noreturn));
static void die_now(int status) {
  register long x0 __asm__("x0") = status;

  __asm__ volatile("mov x8, #94\n svc #0" : : "r"(x0) : "x8");
  for (;;) {
  }
}

void exit(int status) {
  put("process exit ");
  putdec(status);
  put("\n");
  backtrace_here();
  die_now(status);
}

unsigned long g_exit_lr __attribute__((used));
unsigned long g_exit_sp __attribute__((used));
unsigned long g_exit_caller __attribute__((used));
void exit_report(int status) __attribute__((noreturn));

// Naked: the interrupt handler in the compiler calls _exit through a 16-byte
// thunk that saved its own return address at [sp]. Reading it here names the
// exact call site that gave up, which a frame-pointer walk cannot (the site is
// in a leaf with no frame).
__attribute__((naked)) void _exit(int status) {
  __asm__ volatile(
      "adrp x9, g_exit_lr\n"
      "add x9, x9, :lo12:g_exit_lr\n"
      "str x30, [x9]\n"
      "adrp x9, g_exit_sp\n"
      "add x9, x9, :lo12:g_exit_sp\n"
      "mov x10, sp\n"
      "str x10, [x9]\n"
      "ldr x10, [sp]\n"
      "adrp x9, g_exit_caller\n"
      "add x9, x9, :lo12:g_exit_caller\n"
      "str x10, [x9]\n"
      "b exit_report\n");
}

void exit_report(int status) {
  Dl_info di;

  put("process _exit ");
  putdec(status);
  put("\n  lr ");
  puthex(g_exit_lr);
  put(" sp ");
  puthex(g_exit_sp);
  put("\n  caller ");
  puthex(g_exit_caller);
  if (g_exit_caller && dladdr((void *)g_exit_caller, &di)) {
    put(" base ");
    puthex((unsigned long)di.dli_fbase);
    put(" off ");
    puthex(g_exit_caller - (unsigned long)di.dli_fbase);
  }
  put("\n");
  backtrace_here();
  die_now(status);
}

void abort(void) {
  put("process abort\n");
  backtrace_here();
  die_now(134);
}

static void patch_insn(unsigned char *base, unsigned long off, unsigned int want,
                       unsigned int neu, const char *what) {
  unsigned int *slot = (unsigned int *)(base + off);
  unsigned int old = *slot;
  unsigned long page = (unsigned long)slot & ~4095UL;

  put(what);
  put(" ");
  puthex((unsigned long)slot);
  put(" old ");
  puthex(old);
  put("\n");
  if (old != want) {
    put("  unexpected instruction, skipped\n");
    return;
  }
  if (mprotect((void *)page, 4096, 7) != 0) {
    put("  mprotect failed\n");
    return;
  }
  *slot = neu;
  clear_cache((char *)slot, (char *)slot + 4);
  mprotect((void *)page, 4096, 5);
  put("  patched -> ");
  puthex(neu);
  put("\n");
}

// The compiler's tracing/ASHMEM helper prefers libcutils' legacy
// ashmem_create_region, which opens /dev/ashmem: mainline has no such device.
// Export memfd-backed versions so its dlsym(RTLD_DEFAULT) search finds these
// instead (build with -Wl,--export-dynamic).
static int memfd_region(const char *name, size_t size) {
  long fd = syscall(279, name, 1 /* MFD_CLOEXEC */);

  if (fd < 0) return -1;
  if (size && syscall(46 /* ftruncate */, (int)fd, (long)size) != 0) {
    close((int)fd);
    return -1;
  }
  return (int)fd;
}

__attribute__((visibility("default"), used))
int ashmem_create_region(const char *name, size_t size) {
  return memfd_region(name, size);
}

__attribute__((visibility("default"), used))
int ASharedMemory_create(const char *name, size_t size) {
  return memfd_region(name, size);
}

__attribute__((visibility("default"), used))
int ashmem_get_size_region(int fd) {
  return (int)lseek(fd, 0, 2);
}

__attribute__((visibility("default"), used))
int ashmem_pin_region(int fd, size_t offset, size_t len) {
  (void)fd;
  (void)offset;
  (void)len;
  return 0;
}

__attribute__((visibility("default"), used))
int ashmem_unpin_region(int fd, size_t offset, size_t len) {
  (void)fd;
  (void)offset;
  (void)len;
  return 0;
}

typedef int (*compile_fn)(int, unsigned long, const char *, unsigned,
                          unsigned, unsigned *, void **, char **);
typedef void (*free_fn)(void *);

int main(int argc, char **argv) {
  const char *model_path;
  const char *out_path;
  const char *opt_path;
  unsigned long model_size, opt_size = 0;
  int model_fd;
  char *opts = 0;
  unsigned out_size = 0;
  void *out = 0;
  char *err = 0;
  char *msg = 0;
  void *h;
  compile_fn compile;
  free_fn release;
  int rc;

  put("tpu-compile\n");
  if (argc < 3) {
    put("usage: tpu-compile MODEL OUT [OPTIONS]\n");
    return 2;
  }
  model_path = argv[1];
  out_path = argv[2];
  opt_path = argc > 3 ? argv[3] : 0;

  model_size = filesize(model_path);
  put("model ");
  put(model_path);
  put(" ");
  putdec((long)model_size);
  put(" bytes\n");
  if (!model_size) return 1;
  model_fd = open(model_path, 0);
  if (model_fd < 0) {
    put("model open failed\n");
    return 1;
  }
  if (opt_path) {
    opt_size = filesize(opt_path);
    if (opt_size) {
      opts = (char *)malloc(opt_size);
      if (!opts || slurp(opt_path, opts, opt_size)) {
        put("options read failed\n");
        return 1;
      }
    }
  }
  if (!opts) {
    opts = (char *)malloc(1);
    opt_size = 0;
  }

  h = dlopen("/vendor/lib64/libedgetpu_tflite_compiler.so", RTLD_NOW);
  if (!h) {
    put("dlopen: ");
    put(dlerror() ? dlerror() : "?");
    put("\n");
    return 1;
  }
  compile = (compile_fn)dlsym(h, "CompileTfliteFlatbuffer2");
  release = (free_fn)dlsym(h, "LibEdgetpuTfliteCompilerFree");
  put("compile=");
  puthex((unsigned long)compile);
  put(" free=");
  puthex((unsigned long)release);
  put("\n");
  if (!compile) return 1;

  // The compiler asks its static DirectoryRegistry for a config by the
  // runtime version, in two places: the cache key (ldr w20, [x0, #0x50] at
  // 0xc08f98) and the config itself (ldr w0, [x21, #0x8] at 0xc14cc0). A
  // plain TFLite model carries no version, so both ask for v1 and miss; this
  // build ships only v5 (the janeiro config at 0x3f41050, selected by version
  // 14). Force both loads to 14 for this run.
  {
    unsigned char *base = (unsigned char *)compile - 0xc0871c;
    patch_insn(base, 0xc08f98, 0xb9405014, 0x528001d4, "cache version");
    patch_insn(base, 0xc14cc0, 0xb9400aa0, 0x528001c0, "config version");
  }

  put("compiling (uid 1000, ");
  putdec((long)opt_size);
  put(" option bytes)...\n");
  rc = compile(model_fd, model_size, opts, (unsigned)opt_size, 1000,
               &out_size, &out, &err);
  put("rc ");
  putdec(rc);
  put(" out_size ");
  putdec((long)out_size);
  put(" out ");
  puthex((unsigned long)out);
  put(" err ");
  puthex((unsigned long)err);
  put("\n");
  if (err) {
    put("error: ");
    put(err);
    put("\n");
  }
  if (rc == 0 && out && out_size) {
    if (out_size >= 8) {
      unsigned char *p = (unsigned char *)out;
      int i;

      put("head:");
      for (i = 0; i < 16; i++) {
        put(" ");
        puthex(p[i]);
      }
      put("\n");
    }
    if (spill(out_path, (const char *)out, out_size) == 0) {
      put("wrote ");
      put(out_path);
      put("\n");
    } else {
      put("write failed\n");
    }
    if (release) release(out);
  }
  free(err);
  close(model_fd);
  free(opts);
  (void)msg;
  return rc;
}
