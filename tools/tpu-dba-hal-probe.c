// SPDX-License-Identifier: MIT
// tpu-dba-hal-probe: call the DBA HAL's only export and print what it returns.
//
// libdarwinn_dba_hal_runtime.so exports exactly one symbol,
// GetDarwinnHalFunctions@@VER_1.0, so the surface that performs the firmware
// setup is a function table. Printing it (and the address-relative offset of
// each pointer) turns the HAL into something the disassembly can name, without
// binder and without a client protocol (TPU-PLAN D2b, U284).
//
// Run inside the vendor chroot:
//   LD_LIBRARY_PATH=/system/lib64:/vendor/lib64 chroot $R /vendor/bin/tpu-dba-hal-probe
#include <stddef.h>

typedef unsigned long size_t;

extern void __libc_init(void *, void *, int (*)(int, char **, char **), void *);
extern long write(int, const void *, size_t);
extern void *dlopen(const char *, int);
extern void *dlsym(void *, const char *);
extern char *dlerror(void);

#define RTLD_NOW 2
#define RTLD_GLOBAL 0x100

#ifndef PROBE_AS_SO
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
#endif

static void put(const char *s) {
  size_t n = 0;

  if (!s) s = "(null)";
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
    b[i--] = '0' + (char)(u % 10);
    u /= 10;
  } while (u);
  if (neg) b[i--] = '-';
  put(&b[i + 1]);
}

struct dl_info {
  const char *name;
  void *base;
  const char *sym;
  void *addr;
};

extern int dladdr(const void *, void *);

static int probe(int argc, char **argv) {
  const char *path = argc > 1 ? argv[1] : "/vendor/lib64/libdarwinn_dba_hal_runtime.so";
  void *h;
  void *(*get)(void);
  unsigned long *tbl;
  int i;

  h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
  if (!h) {
    put("dlopen: ");
    put(dlerror());
    put("\n");
    return 1;
  }
  put("loaded ");
  put(path);
  put("\n");
  get = (void *(*)(void))dlsym(h, "GetDarwinnHalFunctions");
  if (!get) {
    put("no GetDarwinnHalFunctions\n");
    return 1;
  }
  put("calling GetDarwinnHalFunctions\n");
  tbl = (unsigned long *)get();
  put("table = ");
  puthex((unsigned long)tbl);
  put("\n");
  if (!tbl) {
    put("null table\n");
    return 1;
  }
  /* Read only the words that can be function pointers; a wrong count is a
     read into the same mapping, not a call. */
  for (i = 0; i < 32; i++) {
    unsigned long v = tbl[i];
    struct dl_info in;

    put("  +");
    putdec(i * 8);
    put(" ");
    puthex(v);
    if (v > 0x1000) {
      in.name = 0;
      in.base = 0;
      in.sym = 0;
      in.addr = 0;
      if (dladdr((void *)v, &in) && in.base) {
        put(" base=");
        puthex((unsigned long)in.base);
        put(" off=");
        puthex(v - (unsigned long)in.base);
        if (in.sym) {
          put(" ");
          put(in.sym);
        }
      }
    }
    put("\n");
  }
  return 0;
}

int main(int argc, char **argv) { return probe(argc, argv); }

/* As a preloaded .so the probe has no crt to call main: run it when the object
   loads, in a process whose libc and libdl are already there. */
__attribute__((constructor)) static void start(void) { probe(0, 0); }
