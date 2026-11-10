// SPDX-License-Identifier: MIT
// tpu-core-session: drive libtachyon_core.so's session exports directly.
//
// The delegate's Tachyon path fails in TachyonCore_CreateClientSession before
// the core's session constructor runs, so the firmware setup it would build is
// never sent (TPU-PLAN U117). This client takes the shortest route to that
// constructor: dlopen the core, set the NPU manager active, then create a
// session with a zeroed 0xb8-byte config and print both statuses. Run it in the
// vendor chroot with LD_LIBRARY_PATH and the liblog-to-stderr shim.
typedef unsigned long size_t;
extern void __libc_init(void *, void *, int (*)(int, char **, char **), void *);
extern long write(int, const void *, size_t);
extern void *dlsym(void *, const char *);
extern void *dlopen(const char *, int);
extern int usleep(unsigned int);

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
  put("0x");
  put(b + i + 1);
}

static void putdec(long v) {
  char b[24];
  int i = 23;
  unsigned long u = v < 0 ? (unsigned long)-v : (unsigned long)v;
  b[i--] = 0;
  do {
    b[i--] = '0' + (u % 10);
    u /= 10;
  } while (u);
  if (v < 0) b[i--] = '-';
  put(b + i + 1);
}

int main(int argc, char **argv) {
  void *h;
  long (*set_status)(int);
  long (*create)(void *, size_t, void **);
  unsigned char cfg[0xb8];
  void *sess = 0;
  size_t i;
  long rc;

  (void)argc;
  (void)argv;
  h = dlopen("/vendor/lib64/libtachyon_core.so", 2);
  put("dlopen "); puthex((unsigned long)h); put("\n");
  if (!h) return 1;
  set_status = (long (*)(int))dlsym(h, "TachyonCore_SetNpuManagerStatus");
  create = (long (*)(void *, size_t, void **))dlsym(
      h, "TachyonCore_CreateClientSession");
  put("set_status "); puthex((unsigned long)set_status); put("\n");
  put("create "); puthex((unsigned long)create); put("\n");
  if (set_status) {
    rc = set_status(1);
    put("set_status -> "); putdec(rc); put("\n");
  }
  for (i = 0; i < sizeof(cfg); i++) cfg[i] = 0;
  if (create) {
    rc = create(cfg, sizeof(cfg), &sess);
    put("create -> "); putdec(rc); put("\n");
    put("session "); puthex((unsigned long)sess); put("\n");
  }
  usleep(3000000);
  return 0;
}
