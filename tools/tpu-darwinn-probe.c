// SPDX-License-Identifier: MIT
// tpu-darwinn-probe: ask the stock Darwinn API v2 for a virtual device over
// /dev/edgetpu, so stock's own code builds the commands (TPU-PLAN U171).
//
// The hand-built flatbuffers in tools/tpu-tachyon-client.c stop at RegisterGraph
// because the GraphDescriptor's field layout is not documented. The vendor
// runtime library carries the same client stack the stock HAL uses
// (platforms::darwinn::tachyon::client::TachyonHalWrapper) behind the public C
// API DarwinnApi2_*, so a VirtualDevice from it serializes every command the way
// the core expects. DarwinnDelegate_CreateVirtualDevice takes the device paths,
// which is the direct driver route: no binder service, no session config.
//
// The variants' argument counts, from the disassembly:
//   DarwinnDelegate_GetDefaultDeviceSpec(type*, flag*, a*, b*, path**, c*)
//   DarwinnDelegate_CreateVirtualDevice(type, flag, a, b, paths, n, out**)
//   DarwinnDelegate_CreateVirtualDevice3(...)       adds two stack arguments
//                                                  before the out pointer
//
// Run inside the vendor chroot:
//   /vendor/bin/tpu-darwinn-probe           (DEV=/dev/edgetpu)
#include <stddef.h>

typedef unsigned long size_t;

extern void __libc_init(void *, void *, int (*)(int, char **, char **), void *);
extern long write(int, const void *, size_t);
extern void *dlopen(const char *, int);
extern void *dlsym(void *, const char *);
extern char *dlerror(void);
extern char *getenv(const char *);

#define RTLD_NOW 2
#define RTLD_GLOBAL 0x100

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

/* A Darwinn status comes back as two registers: a code and a message string.
   Zero in the code is success everywhere in this API. */
typedef struct {
  long code;
  long msg;
} tpu_status;

/* The status' second register is only known to be a message pointer when the
   code is nonzero, and a wrong prototype makes it garbage, so print it as an
   address and never dereference it. */
static void show(const char *what, tpu_status st) {
  put(what);
  put(": code=");
  putdec(st.code);
  put(" arg2=");
  puthex((unsigned long)st.msg);
  put("\n");
}

static int g_type = 5, g_a = 0, g_b = 1, g_c = 1;
static unsigned char g_flag = 1;
static const char *g_path;

int main(int argc, char **argv) {
  void *h;
  int rc = 0;

  (void)argc;
  (void)argv;
  h = dlopen("/vendor/lib64/libedgetpu_util.so", RTLD_NOW | RTLD_GLOBAL);
  if (!h) {
    put("dlopen: ");
    put(dlerror());
    put("\n");
    return 1;
  }
  put("libedgetpu_util loaded\n");

  {
    typedef int (*ver_fn)(int *);
    ver_fn ver = (ver_fn)dlsym(h, "DarwinnApi2_GetVersionInfo");
    int v = -1;

    if (!ver) {
      put("no DarwinnApi2_GetVersionInfo\n");
    } else {
      int r = ver(&v);

      put("GetVersionInfo rc=");
      putdec(r);
      put(" version=");
      putdec(v);
      put("\n");
    }
  }
  {
    /* Six outputs: the disassembly stores to x0..x5 (type 5, flag 1, 0, 1,
       the device path and one more int). Passing five made the library write
       through a garbage sixth pointer. */
    typedef tpu_status (*spec_fn)(int *, unsigned char *, int *, int *,
                                  const char **, int *);
    spec_fn spec =
        (spec_fn)dlsym(h, "DarwinnDelegate_GetDefaultDeviceSpec");

    if (!spec) {
      put("no DarwinnDelegate_GetDefaultDeviceSpec\n");
    } else {
      tpu_status st;

      put("calling GetDefaultDeviceSpec\n");
      st = spec(&g_type, &g_flag, &g_a, &g_b, &g_path, &g_c);
      show("spec", st);
      put("  type=");
      putdec(g_type);
      put(" flag=");
      putdec(g_flag);
      put(" a=");
      putdec(g_a);
      put(" b=");
      putdec(g_b);
      put(" c=");
      putdec(g_c);
      put(" path=");
      puthex((unsigned long)g_path);
      put("\n");
    }
  }
  {
    const char *paths[1];
    void *dev = 0;
    typedef tpu_status (*create_fn)(int, int, int, int, const char **, int,
                                    void **);
    create_fn cr = (create_fn)dlsym(h, "DarwinnDelegate_CreateVirtualDevice");
    const char *env = getenv("DEV");
    tpu_status st;

    /* The spec's path is a std::string object, not a C string (reading it as
       one gave a garbage name and an INTERNAL error from file.cc), so use the
       node the kernel driver exports. */
    paths[0] = env && env[0] ? env : "/dev/edgetpu";
    if (!cr) {
      put("no DarwinnDelegate_CreateVirtualDevice\n");
      return 1;
    }
    put("creating a device on ");
    put(paths[0]);
    put("\n");
    st = cr(g_type, g_flag, g_a, g_b, paths, 1, &dev);
    show("create", st);
    put("  device=");
    puthex((unsigned long)dev);
    put("\n");
    if (!dev) {
      rc = 1;
    } else {
      typedef tpu_status (*vii_fn)(void *, int *);
      vii_fn vii = (vii_fn)dlsym(h, "DarwinnApi2_VirtualDevice_GetViiVersion");

      if (vii) {
        int ver = -1;
        tpu_status s2 = vii(dev, &ver);

        show("GetViiVersion", s2);
        put("  vii=");
        putdec(ver);
        put("\n");
      }
    }
  }
  return rc;
}
