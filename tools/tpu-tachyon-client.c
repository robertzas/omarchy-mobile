// SPDX-License-Identifier: MIT
// tpu-tachyon-client: start a session on the stock Tachyon compute service,
// the process that sends the firmware's one-time setup command. The vendor
// runtime's util library skips that setup on this device, so every VII command
// the delegate sends is refused with "Setup is not done yet"; this client
// drives the same AIDL the app service uses (TPU-PLAN U51).
//
// Run inside the vendor chroot as the system uid:
//   chroot --userspec=1000:1000 ROOT /vendor/bin/tpu-tachyon-client
//
// The lib's TachyonComputeService_create checks AServiceManager_isDeclared()
// first; there is no VINTF manifest in the chroot, so it would fail without
// even looking the service up. This client overrides that one symbol (the real
// AServiceManager_waitForService stays) and leaves the rest of the AIDL path to
// libbinder_ndk. It deliberately does not stub the other AServiceManager_*
// calls as tools/tpu-a14-hal.c does: those stubs are for the HAL, not this.

typedef unsigned long size_t;
typedef long ssize_t;

extern void __libc_init(void *, void *, int (*)(int, char **, char **), void *);
extern long write(int, const void *, size_t);
extern void *dlopen(const char *, int);
extern void *dlsym(void *, const char *);
extern char *dlerror(void);
extern void _exit(int) __attribute__((noreturn));
extern unsigned int sleep(unsigned int);
extern int usleep(unsigned int);
extern long readlink(const char *, char *, size_t);
extern int *__errno(void);
extern char *getenv(const char *);
extern void *memcpy(void *, const void *, size_t);
extern void *memset(void *, int, size_t);
extern long syscall(long, ...);
extern int open(const char *, int);
extern int ioctl(int, unsigned long, ...);
extern void *mmap(void *, size_t, int, int, int, long);
extern long lseek(int, long, int);
extern long read(int, void *, size_t);
extern int close(int);

/* No string.h here: the client is built -nostdlib against bionic's exports. */
static int same_str(const char *a, const char *b) {
  while (*a && *a == *b) {
    a++;
    b++;
  }
  return *a == *b;
}

static unsigned env_num(const char *name, unsigned def) {
  const char *s = getenv(name);
  unsigned v = 0;

  if (!s || !*s) return def;
  while (*s >= '0' && *s <= '9') v = v * 10 + (unsigned)(*s++ - '0');
  return v;
}

static int has_char(const char *s, char c) {
  while (*s) {
    if (*s == c) return 1;
    s++;
  }
  return 0;
}

#define RTLD_NOW 2
#define RTLD_GLOBAL 0x100
#define RTLD_DEFAULT ((void *)0)

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

static long parse_dec(const char *s) {
  long v = 0;

  if (!s) return 0;
  while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
  return v;
}

// A chroot has no Android property service; the lib asks for the chip family.
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

// The VINTF manifest is missing in the chroot, but the service is registered
// on the vendor binder. Without this the lib returns "not declared" before it
// ever calls AServiceManager_waitForService.
int AServiceManager_isDeclared(const char *instance) {
  (void)instance;
  return 1;
}

// The lib dereferences all three: cookie at 0, onDied at 8 (passed to
// AIBinder_DeathRecipient_new), onUnavailable at 0x10.
static int g_cookie;
static void on_died(void *cookie) { (void)cookie; }
static void on_unavailable(void *cookie) { (void)cookie; }
static void *g_callbacks[3] = { &g_cookie, (void *)on_died,
                                (void *)on_unavailable };

typedef void *(*create_fn)(void *, void **);
typedef void *(*config_create_fn)(void);
typedef void (*config_set_fn)(void *, int);
typedef void *(*session_fn)(void *, void *, void **);
typedef void *(*queue_fn)(void *, int *, int *);
typedef void *(*status_fn)(void *);
typedef int (*status_ok_fn)(void *);
typedef int (*status_code_fn)(void *);
typedef const char *(*status_msg_fn)(void *);

static void show_status(status_fn get, status_ok_fn ok, const char *what,
                        void *st) {
  put(what);
  put(": ");
  if (!st) {
    put("null\n");
    return;
  }
  if (!ok) {
    put("status=");
    puthex((unsigned long)st);
    put(" (no AStatus_isOk)\n");
    return;
  }
  int r = ok(st);
  (void)get;
  put(r == 1 ? "OK" : "NOT-OK");
  put(" status=");
  puthex((unsigned long)st);
  if (r != 1) {
    status_code_fn exc =
        (status_code_fn)dlsym(RTLD_DEFAULT, "AStatus_getExceptionCode");
    status_code_fn svc =
        (status_code_fn)dlsym(RTLD_DEFAULT, "AStatus_getServiceSpecificError");
    status_msg_fn msg =
        (status_msg_fn)dlsym(RTLD_DEFAULT, "AStatus_getMessage");
    (void)get;
    if (exc) {
      put(" exception ");
      putdec(exc(st));
    }
    if (svc) {
      put(" service ");
      putdec(svc(st));
    }
    if (msg) {
      const char *m = msg(st);
      if (m && m[0]) {
        put(" \"");
        put(m);
        put("\"");
      }
    }
  }
  put("\n");
}

extern unsigned int getuid(void);

// The core verifies the first command as a flatbuffer CommandMessage before it
// dispatches anything (tpu_actor_engine.cc:785). Its schema, recovered from the
// core's verifier, is: uint64 command_id, bool privileged-ish flag, the union
// type byte, then the union table. A zero-filled buffer has root offset 0 and
// fails verification, so the core never reaches its own firmware-setup path.
// This builds a minimal message: type 1 (a known union member) with an empty
// table, which the verifier accepts (TPU-PLAN U59/U60).
static void put16(unsigned char *p, unsigned v) {
  p[0] = v & 0xff;
  p[1] = (v >> 8) & 0xff;
}

static void put32(unsigned char *p, unsigned long v) {
  p[0] = v & 0xff;
  p[1] = (v >> 8) & 0xff;
  p[2] = (v >> 16) & 0xff;
  p[3] = (v >> 24) & 0xff;
}

static void put64(unsigned char *p, unsigned long v) {
  int i;

  for (i = 0; i < 8; i++) p[i] = (v >> (8 * i)) & 0xff;
}

// HANDLE is the command's memory handle; FDH is the client-assigned fd handle
// that sendFileDescriptors assigns. ImportMemoryFromFd validates the second:
// with only HANDLE set it names Handle 1 but still reports fd handle 0.
static unsigned long g_handle;
static unsigned long g_fd_handle;
static unsigned long g_dma_size = 4096;
static unsigned long g_scratch;       /* firmware scratch memory handle */
static unsigned long g_scratch_size;  /* its size in bytes */
static unsigned long g_graph_size;    /* the graph dma-buf's size */
static unsigned long base_handle;     /* HANDLE: the graph's memory handle */
static unsigned long base_fd;         /* FDH: the graph's fd handle */

/* RegisterGraph with an arbitrary GraphDescriptor layout. ORDER2 is a list of
   field selectors, one per descriptor field (up to six):
     C graph container table   S firmware scratch table
     X extra buffer table      I intermediate-buffer vector (one element)
     L location, inline struct (offset, size)
     T location, two-field table
   Every table sits at a fixed offset, so a sweep permutes only the descriptor's
   field slots. TPU-PLAN U123: the core dereferences a null field at +0x38, and
   the failing field's slot is what this finds. */
/* SAME=1 points the firmware scratch and the intermediate buffer at the
   graph's own memory, to tell a failed handle lookup from a bad descriptor.
   RH=1 sends the graph's memory handle as the register command's handle
   instead of handle+1. */
static unsigned long reg_scratch_handle(void) {
  return getenv("SAME") ? g_handle : g_scratch;
}

static unsigned long reg_scratch_size(void) {
  return getenv("SAME") ? g_dma_size : g_scratch_size;
}

static unsigned build_reg2(unsigned char *b, const char *order, long seq) {
  unsigned nf = 0;
  unsigned k;

  while (order[nf] && nf < 6) nf++;
  put32(b + 0, 36);
  put16(b + 24, 0x0c);
  put16(b + 26, 0x18);
  put16(b + 28, 4);
  put16(b + 30, 12);
  put16(b + 32, 13);
  put16(b + 34, 16);
  put32(b + 36, 12);
  put64(b + 40, (unsigned long)seq);
  b[48] = 1;
  b[49] = (unsigned char)env_num("TAG", 7);
  put32(b + 52, 20);              /* union table at 72 */
  put16(b + 60, 10);              /* union vtable: 3 fields */
  put16(b + 62, 32);
  put16(b + 64, 8);
  put16(b + 66, 16);
  put16(b + 68, 24);
  put32(b + 72, 12);              /* soffset back to 60 */
  put64(b + 80, getenv("RH") ? g_handle : g_handle + 1); /* command handle */
  put64(b + 88, 1);               /* device id */
  put32(b + 96, 24);              /* descriptor table at 120 */
  put16(b + 104, (unsigned)(2 + 2 * nf)); /* vtable: one entry per field */
  put16(b + 106, (unsigned)(8 * nf + 16)); /* table size, room for a struct */
  for (k = 0; k < nf; k++) put16(b + 108 + 2 * k, (unsigned)(8 + 8 * k));
  put32(b + 120, 16);             /* soffset back to 104 */
  for (k = 0; k < nf; k++) {
    unsigned long fld = 128 + 8 * k;
    char f = order[k];

    if (f == 'C') put32(b + fld, (unsigned)(204 - fld));
    else if (f == 'S') put32(b + fld, (unsigned)(252 - fld));
    else if (f == 'X') put32(b + fld, (unsigned)(300 - fld));
    else if (f == 'I') put32(b + fld, (unsigned)(336 - fld));
    else if (f == 'T') put32(b + fld, (unsigned)(408 - fld));
    else if (f == 'L') {
      put64(b + fld, 0);
      put64(b + fld + 8, g_dma_size);
    }
  }
  /* C: graph container table at 204 */
  put16(b + 192, 10);
  put16(b + 194, 32);
  put16(b + 196, 8);
  put16(b + 198, 16);
  put16(b + 200, 24);
  put32(b + 204, 12);
  put64(b + 212, g_handle);
  put64(b + 220, 0);
  put64(b + 228, g_dma_size);
  /* S: firmware scratch table at 252 */
  put16(b + 240, 10);
  put16(b + 242, 32);
  put16(b + 244, 8);
  put16(b + 246, 16);
  put16(b + 248, 24);
  put32(b + 252, 12);
  put64(b + 260, reg_scratch_handle());
  put64(b + 268, 0);
  put64(b + 276, reg_scratch_size());
  /* X: a second full-size buffer table at 300 */
  put16(b + 288, 10);
  put16(b + 290, 32);
  put16(b + 292, 8);
  put16(b + 294, 16);
  put16(b + 296, 24);
  put32(b + 300, 12);
  put64(b + 308, g_handle);
  put64(b + 316, 0);
  put64(b + 324, g_dma_size);
  /* I: the one-element intermediate vector at 336 */
  put32(b + 336, 1);
  put32(b + 340, 16);
  put16(b + 344, 10);
  put16(b + 346, 32);
  put16(b + 348, 8);
  put16(b + 350, 16);
  put16(b + 352, 24);
  put32(b + 356, 12);
  put64(b + 364, reg_scratch_handle());
  put64(b + 372, 0);
  put64(b + 380, reg_scratch_size());
  /* T: the location as a two-field table at 408 */
  put16(b + 396, 10);
  put16(b + 398, 24);
  put16(b + 400, 8);
  put16(b + 402, 16);
  put32(b + 408, 12);
  put64(b + 416, 0);
  put64(b + 424, g_dma_size);
  return 512;
}

/* RegisterGraph with fields on the command itself as well as in the graph
   descriptor. ORDER2 selects the GraphDescriptor fields and UORDER the
   command's own fields, one letter each:
     H command handle (u64)    D device id (u64)    G the descriptor table
     C graph container table   S firmware scratch table
     X extra buffer table      I intermediate-buffer vector (one element)
     L location, inline struct (offset, size)
     T location, two-field table
   TPU-PLAN U123: the core reads a null buffer at command+0x38 whatever the
   descriptor holds, so the missing field is likely on the command: stock's
   RegisterGraphByBufferWithExternalParameter passes a parameter buffer
   beside the graph. */
static unsigned build_reg3(unsigned char *b, const char *order, long seq,
                           const char *uo) {
  unsigned nf = 0, nu = 0, k, cur = 8;
  unsigned offs[8];

  while (order[nf] && nf < 8) nf++;
  while (uo[nu] && nu < 5) nu++;
  for (k = 0; k < nf; k++) {
    offs[k] = cur;
    cur += (order[k] == 'c' || order[k] == 's' || order[k] == 'i' ||
            order[k] == 'A' || order[k] == 'B') ? 24 : 8;
  }
  put32(b + 0, 36);
  put16(b + 24, 0x0c);
  put16(b + 26, 0x18);
  put16(b + 28, 4);
  put16(b + 30, 12);
  put16(b + 32, 13);
  put16(b + 34, 16);
  put32(b + 36, 12);
  put64(b + 40, (unsigned long)seq);
  b[48] = 1;
  b[49] = (unsigned char)env_num("TAG", 7);
  {
    /* A five-field vtable is 14 bytes and would overlap a table at 72;
       move the table past it. The header size is 4 + 2*nu, not 2 + 2*nu. */
    unsigned ub = nu >= 5 ? 80 : 72;

    put32(b + 52, (unsigned)(ub - 52));
    put16(b + 60, (unsigned)(4 + 2 * nu));
    put16(b + 62, (unsigned)(8 * nu + 8));
    for (k = 0; k < nu; k++) put16(b + 64 + 2 * k, (unsigned)(8 + 8 * k));
    put32(b + ub, (unsigned)(ub - 60));
  }
  for (k = 0; k < nu; k++) {
    unsigned long fld = (nu >= 5 ? 80 : 72) + 8 + 8 * k;
    char f = uo[k];

    if (f == 'H') put64(b + fld, getenv("RH") ? g_handle : g_handle + 1);
    else if (f == 'D') put64(b + fld, 1);
    else if (f == 'G') put32(b + fld, (unsigned)(144 - fld));
    else if (f == 'X') put32(b + fld, (unsigned)(348 - fld));
    else if (f == 'V' || f == 'W') put32(b + fld, (unsigned)(440 - fld));
    else if (f == 'M') put64(b + fld, g_handle);
    else if (f == 'K') put64(b + fld, g_handle + 1);
    else if (f == 'S') {
      put32(b + fld, env_num("BTYPE", 0));
      put32(b + fld + 4, env_num("BIDX", 0));
      put64(b + fld + 8, 0);
      put64(b + fld + 16, env_num("BSIZE", (unsigned)g_dma_size));
    }
  }
  /* GraphDescriptor table at 144; c/s/i are inline BufferLocations */
  put16(b + 128, (unsigned)(2 + 2 * nf));
  put16(b + 130, (unsigned)(cur + 16));
  for (k = 0; k < nf; k++) put16(b + 132 + 2 * k, (unsigned)offs[k]);
  put32(b + 144, 16);
  for (k = 0; k < nf; k++) {
    unsigned long fld = 144 + offs[k];
    char f = order[k];

    if (f == 'C') put32(b + fld, (unsigned)(252 - fld));
    else if (f == 'S') put32(b + fld, (unsigned)(300 - fld));
    else if (f == 'X') put32(b + fld, (unsigned)(348 - fld));
    else if (f == 'I' || f == 'E') put32(b + fld, (unsigned)(384 - fld));
    else if (f == 'J') put32(b + fld, (unsigned)(388 - fld));
    else if (f == 'T') put32(b + fld, (unsigned)(476 - fld));
    else if (f == 'L') {
      put64(b + fld, 0);
      put64(b + fld + 8, g_dma_size);
    } else if (f == 'c') {
      put32(b + fld, 0);
      put32(b + fld + 4, 0);
      put64(b + fld + 8, 0);
      put64(b + fld + 16, g_dma_size);
    } else if (f == 's') {
      put32(b + fld, 1);
      put32(b + fld + 4, 1);
      put64(b + fld + 8, 0);
      put64(b + fld + 16, reg_scratch_size());
    } else if (f == 'i') {
      put32(b + fld, 1);
      put32(b + fld + 4, 2);
      put64(b + fld + 8, 0);
      put64(b + fld + 16, reg_scratch_size());
    } else if (f == 'A') {
      /* U137: an inline BufferLocation as the core's struct, not a table:
         one u64 handle first (the table encoding put a buffer position
         there, which is where the core's "handle 252" came from). */
      put64(b + fld, g_handle);
      put64(b + fld + 8, 0);
      put64(b + fld + 16, g_dma_size);
    } else if (f == 'B') {
      put64(b + fld, reg_scratch_handle());
      put64(b + fld + 8, 0);
      put64(b + fld + 16, reg_scratch_size());
    }
  }
  /* C: graph container table at 252 */
  put16(b + 240, 10);
  put16(b + 242, 32);
  put16(b + 244, 8);
  put16(b + 246, 16);
  put16(b + 248, 24);
  put32(b + 252, 12);
  /* CH/SH/IH force an impossible memory handle into one buffer table. An
     unknown handle is a clean error, so it says whether the core read that
     table at all: the named error means it did, the VII-builder crash means
     it did not. */
  put64(b + 260, env_num("CH", (unsigned)g_handle));
  put64(b + 268, 0);
  put64(b + 276, g_dma_size);
  /* S: firmware scratch table at 300 */
  put16(b + 288, 10);
  put16(b + 290, 32);
  put16(b + 292, 8);
  put16(b + 294, 16);
  put16(b + 296, 24);
  put32(b + 300, 12);
  put64(b + 308, env_num("SH", (unsigned)reg_scratch_handle()));
  put64(b + 316, 0);
  put64(b + 324, reg_scratch_size());
  /* X: a second buffer table at 348 */
  put16(b + 336, 10);
  put16(b + 338, 32);
  put16(b + 340, 8);
  put16(b + 342, 16);
  put16(b + 344, 24);
  put32(b + 348, 12);
  put64(b + 356, g_handle);
  put64(b + 364, 0);
  put64(b + 372, g_dma_size);
  /* I: the one-element intermediate vector at 384, table at 404 */
  put32(b + 384, 1);
  put32(b + 388, 16);
  put16(b + 392, 10);
  put16(b + 394, 32);
  put16(b + 396, 8);
  put16(b + 398, 16);
  put16(b + 400, 24);
  put32(b + 404, 12);
  put64(b + 412, env_num("IH", (unsigned)reg_scratch_handle()));
  put64(b + 420, 0);
  put64(b + 428, reg_scratch_size());
  /* J: the same one-element vector, but its element is the 24-byte
     BufferDescriptor inline at 392 (a vector of structs), not a uoffset to a
     table. Written after the I block so it wins when both could apply. */
  /* E: an empty vector at 384 (length 0). A valid vector of any element
     type, to tell "the field is a vector" from "the element encoding is
     wrong": if the parse advances past it, the next field parses. */
  if (has_char(order, 'E'))
    put32(b + 384, 0);
  if (has_char(order, 'J')) {
    put32(b + 388, 1);            /* length at 388: data at 392 is 8-aligned */
    put64(b + 392, env_num("IH", (unsigned)reg_scratch_handle()));
    put64(b + 400, 0);
    put64(b + 408, reg_scratch_size());
  }
  /* V/W: the memory handles a location index names, at 440 */
  put32(b + 440, 2);
  put64(b + 444, uo && has_char(uo, 'W') ? g_handle + 1 : g_handle);
  put64(b + 452, uo && has_char(uo, 'W') ? reg_scratch_handle() + 1
                                        : reg_scratch_handle());
  /* T: the location as a two-field table at 476 */
  put16(b + 464, 10);
  put16(b + 466, 24);
  put16(b + 468, 8);
  put16(b + 470, 16);
  put32(b + 476, 12);
  put64(b + 484, 0);
  put64(b + 492, g_dma_size);
  return 512;
}

static unsigned build_cmd(unsigned char *b, int type, long seq) {
  /* root table at 36, its vtable at 24; union vtable at 56, union table at 60 */
  int i;

  for (i = 0; i < 512; i++) b[i] = 0;
  if ((type == 7 || type == 8) && g_handle) {
    /* REG2/ORDER2: the flexible descriptor builder, for the field sweep. */
    {
      const char *o2 = getenv("ORDER2");
      const char *u2 = getenv("UORDER");

      if (u2 && u2[0])
        return build_reg3(b, o2 && o2[0] ? o2 : "CSI", seq, u2);
      if (o2 && o2[0]) return build_reg2(b, o2, seq);
    }
    /* RegisterGraph is {command handle, device id, GraphDescriptor}. The
       descriptor has four fields: three BufferDescriptor tables (the graph
       container, the firmware scratch, the intermediate buffers, which must
       be non-empty) and the graph location (offset, size) inside the
       container. Nothing public names their order, so ORDER permutes the
       three tables and LOC=struct|table|none picks the fourth field: a
       16-byte inline struct (the default), a two-field table, or no field at
       all. */
    const char *order = getenv("ORDER");
    const char *loc = getenv("LOC");
    int nf = 3;
    int k;

    if (!order || !order[0]) order = "CSI";
    if (!loc) loc = "struct";
    if (!same_str(loc, "none")) nf = 4;
    put32(b + 0, 36);
    put16(b + 24, 0x0c);
    put16(b + 26, 0x18);
    put16(b + 28, 4);
    put16(b + 30, 12);
    put16(b + 32, 13);
    put16(b + 34, 16);
    put32(b + 36, 12);
    put64(b + 40, (unsigned long)seq);
    b[48] = 1;
    b[49] = (unsigned char)type;
    put32(b + 52, 20);              /* union table at 72 */
    put16(b + 60, 10);              /* union vtable: 3 fields */
    put16(b + 62, 32);
    put16(b + 64, 8);
    put16(b + 66, 16);
    put16(b + 68, 24);
    put32(b + 72, 12);              /* soffset back to 60 */
    put64(b + 80, getenv("RH") ? g_handle : g_handle + 1); /* command handle */
    put64(b + 88, 1);               /* device id */
    put32(b + 96, 20);              /* descriptor table at 116 */
    put16(b + 104, (unsigned)(2 + 2 * nf)); /* vtable: one entry per field */
    put16(b + 106, (unsigned)(nf == 4 ? 48 : 32)); /* table size */
    for (k = 0; k < nf; k++) put16(b + 108 + 2 * k, (unsigned)(8 + 8 * k));
    put32(b + 116, 12);             /* soffset back to 104 */
    /* The three tables are at 176 (C), 220 (S) and 252 (I); each slot holds a
       uoffset forward from the slot itself. The location is an inline 16-byte
       struct in slot 3, or a two-field table at 320 (LOC=table). */
    for (k = 0; k < 3 && k < nf; k++) {
      char f = order[k] ? order[k] : "CSI"[k];
      unsigned long tgt = f == 'C' ? 176 : f == 'I' ? 252 : 220;

      put32(b + 124 + 8 * k, (unsigned)(tgt - 124 - 8 * k));
    }
    if (same_str(loc, "table")) {
      put16(b + 308, 10);           /* location vtable: 2 fields */
      put16(b + 310, 24);
      put16(b + 312, 8);
      put16(b + 314, 16);
      put32(b + 320, 12);           /* soffset back to 308 */
      put64(b + 328, 0);            /* location: offset */
      put64(b + 336, g_dma_size);   /* location: size */
      put32(b + 148, (unsigned)(320 - 148));
    } else if (same_str(loc, "struct")) {
      put64(b + 148, 0);            /* graph location: offset */
      put64(b + 156, g_dma_size);   /* graph location: size */
    } else if (same_str(loc, "buf")) {
      /* The fourth field as a BufferDescriptor table (memory handle, offset,
         size): the external parameter buffer some register calls take. */
      put16(b + 304, 10);
      put16(b + 306, 32);
      put16(b + 308, 8);
      put16(b + 310, 16);
      put16(b + 312, 24);
      put32(b + 320, 16);           /* soffset back to 304 */
      put64(b + 328, g_handle);     /* memory handle */
      put64(b + 336, 0);            /* offset */
      put64(b + 344, g_dma_size);   /* size */
      put32(b + 148, (unsigned)(320 - 148));
    }
    put16(b + 164, 10);             /* graph container vtable */
    put16(b + 166, 32);
    put16(b + 168, 8);
    put16(b + 170, 16);
    put16(b + 172, 24);
    put32(b + 176, 12);             /* soffset back to 164 */
    put64(b + 184, g_handle);       /* graph memory handle */
    put64(b + 192, 0);              /* graph offset in that memory */
    put64(b + 200, g_dma_size);     /* graph length */
    put16(b + 208, 10);             /* scratch vtable */
    put16(b + 210, 32);
    put16(b + 212, 8);
    put16(b + 214, 16);
    put16(b + 216, 24);
    put32(b + 220, 12);             /* soffset back to 208 */
    put64(b + 228, reg_scratch_handle());   /* firmware scratch handle */
    put64(b + 236, 0);                      /* scratch offset */
    put64(b + 244, reg_scratch_size());     /* scratch length */
    put32(b + 252, 1);              /* one intermediate buffer */
    put32(b + 256, 16);             /* its table at 272 */
    put16(b + 260, 10);
    put16(b + 262, 32);
    put16(b + 264, 8);
    put16(b + 266, 16);
    put16(b + 268, 24);
    put32(b + 272, 12);             /* soffset back to 260 */
    put64(b + 280, reg_scratch_handle());   /* memory handle */
    put64(b + 288, 0);
    put64(b + 296, reg_scratch_size());     /* size */
    return 352;
  }
  if ((g_handle || g_fd_handle) && (type == 5 || type == 6 || type == 7)) {
    /* The tegu core's actor engine validates a separate client-assigned fd
       handle. Its schema is {handle, device_id, fd_handle, offset, size}:
       field 0 is the command handle (the core logs "Handle 1"), field 1 the
       device id, field 2 the fd handle, field 3 the offset and field 4 the
       size. Union vtable at 64 (14 bytes), union table at 80; fields at 88,
       96, 104, 112 and 120. The core read 4096 as the offset when it was in
       field 3, so the offset comes before the size. */
    put32(b + 0, 36);
    put16(b + 24, 0x0c);
    put16(b + 26, 0x18);
    put16(b + 28, 4);
    put16(b + 30, 12);
    put16(b + 32, 13);
    put16(b + 34, 16);
    put32(b + 36, 12);
    put64(b + 40, (unsigned long)seq);
    b[48] = 1;  /* privileged, matching the session config */
    b[49] = (unsigned char)type;
    put32(b + 52, 28);  /* union table at 80 */
    put16(b + 64, 14);  /* vtable size: 7 u16 entries */
    put16(b + 66, 48);  /* table size */
    put16(b + 68, 8);   /* field 0 at table+8 */
    put16(b + 70, 16);  /* field 1 at table+16 */
    put16(b + 72, 24);  /* field 2 at table+24 */
    put16(b + 74, 32);  /* field 3 at table+32 */
    put16(b + 76, 40);  /* field 4 at table+40 */
    put32(b + 80, 16);  /* soffset back to the vtable at 64 */
    put64(b + 88, g_handle ? g_handle : 1);
    put64(b + 96, 1);   /* device id, the virtual device from AllocateTpu */
    put64(b + 104, g_fd_handle);
    put64(b + 112, 0);  /* offset into the dma-buf */
    put64(b + 120, g_dma_size);  /* bytes to map */
    return 128;
  }
  put32(b + 0, 36);
  put16(b + 24, 0x0c);
  put16(b + 26, 0x18);
  put16(b + 28, 4);
  put16(b + 30, 12);
  put16(b + 32, 13);
  put16(b + 34, 16);
  put32(b + 36, 12);
  put64(b + 40, (unsigned long)seq);
  b[48] = 1;  /* privileged, matching the session config */
  b[49] = (unsigned char)type;  /* union type from the core's name table (U96) */
  put32(b + 52, 8);
  put16(b + 56, 4);
  put16(b + 58, 4);
  put32(b + 60, 4);
  return 64;
}

// The tegu core refuses a SessionConfig without a get_fds callback. It is
// called only for handles the client assigned to the core; this client
// assigns none, so the stub logs any request and refuses it (fd -1), which is
// enough to pass the config check (TPU-PLAN U58).
typedef void (*get_fds_cb_fn)(void *, int *, long *, int, long);

static void get_fds_cb(void *cookie, int *fds, long *handles, int count,
                       long session_id) {
  int i;

  (void)cookie;
  put("get_fds: count=");
  putdec(count);
  put(" session=");
  putdec(session_id);
  put("\n");
  for (i = 0; i < count; i++) {
    put("  handle=");
    puthex((unsigned long)handles[i]);
    put("\n");
    fds[i] = -1;
  }
}


static int g_fd[4];
static int g_is_ev[4];

static int str_has(const char *h, const char *n) {
  int i, j;

  for (i = 0; h[i]; i++) {
    for (j = 0; n[j] && h[i + j] == n[j]; j++) {}
    if (!n[j]) return 1;
  }
  return 0;
}

// The queue setup hands back four raw fds. Whether one is the eventfd the
// actor's epoll waits on decides who must ring it (U94).
static void show_fd(int slot, int fd) {
  char path[32], buf[96], d[12], t[12];
  const char *pre = "/proc/self/fd/";
  int i = 0, j = 0, k, n, v;

  g_fd[slot] = fd;
  g_is_ev[slot] = 0;
  while (pre[i]) { path[i] = pre[i]; i++; }
  if (fd == 0) {
    d[j++] = '0';
  } else {
    v = fd;
    k = 0;
    while (v) { t[k++] = (char)('0' + v % 10); v /= 10; }
    while (k) d[j++] = t[--k];
  }
  for (k = 0; k < j; k++) path[i++] = d[k];
  path[i] = 0;
  n = (int)readlink(path, buf, sizeof(buf) - 1);
  put("fd ");
  putdec(fd);
  put(" -> ");
  if (n < 0) {
    put("? errno ");
    putdec(*__errno());
  } else {
    buf[n] = 0;
    put(buf);
    g_is_ev[slot] = str_has(buf, "eventfd");
  }
  put("\n");
}

int main(int argc, char **argv) {
  /* argv[1] "0" asks for an unprivileged session; default is privileged
   * (the config the app service uses). */
  int privileged = 1;
  int ntypes = 0;
  static int types[8];
  long rounds_env = 0;
  int cmd_type = (int)parse_dec(getenv("TYPE"));

  g_handle = (unsigned long)parse_dec(getenv("HANDLE"));
  g_fd_handle = (unsigned long)parse_dec(getenv("FDH"));
  base_handle = g_handle;
  base_fd = g_fd_handle;
  if (cmd_type <= 0 || cmd_type > 24) cmd_type = 1;

  // TYPES=2,7 sends a different union member in each round, each with its
  // own sequence number; one session can allocate a device and then use it.
  {
    const char *tl = getenv("TYPES");

    ntypes = 0;
    if (tl) {
      while (*tl && ntypes < 8) {
        int v = 0;

        while (*tl >= '0' && *tl <= '9') v = v * 10 + (*tl++ - '0');
        if (v > 0 && v <= 24) types[ntypes++] = v;
        if (*tl == ',') tl++;
        else break;
      }
    }
  }
  if (argc > 1 && argv[1] && argv[1][0] == '0') privileged = 0;
  void *h = dlopen("/vendor/lib64/libedgetpu_tachyon.google.so",
                   RTLD_NOW | RTLD_GLOBAL);
  if (!h) {
    put("dlopen: ");
    put(dlerror() ? dlerror() : "?");
    put("\n");
    return 1;
  }

  // The lib logged "The user of this library did not start a threadpool": the
  // core calls back into the client (get_fds) over binder, and without a
  // threadpool that call cannot be delivered. Stock's HAL starts one.
  {
    typedef void (*start_pool_fn)(void);
    start_pool_fn start_pool =
        (start_pool_fn)dlsym(h, "ABinderProcess_startThreadPool");

    if (!start_pool)
      start_pool = (start_pool_fn)dlsym(RTLD_DEFAULT,
                                        "ABinderProcess_startThreadPool");
    if (start_pool) {
      start_pool();
      put("threadpool started\n");
    } else {
      put("threadpool symbol missing\n");
    }
  }

  create_fn service_create =
      (create_fn)dlsym(h, "TachyonComputeService_create");
  config_create_fn config_create =
      (config_create_fn)dlsym(h, "TachyonComputeSessionConfig_create");
  config_set_fn config_set =
      (config_set_fn)dlsym(h, "TachyonComputeSessionConfig_setPrivileged");
  session_fn create_session =
      (session_fn)dlsym(h, "TachyonComputeService_createSession");
  queue_fn setup_cmd =
      (queue_fn)dlsym(h, "TachyonComputeSession_setupCommandQueue");
  queue_fn setup_rsp =
      (queue_fn)dlsym(h, "TachyonComputeSession_setupResponseQueue");
  status_fn status_get = (status_fn)dlsym(h, "TachyonStatus_getAStatus");
  status_ok_fn status_ok = (status_ok_fn)dlsym(RTLD_DEFAULT, "AStatus_isOk");
  typedef void (*set_fds_cb_fn)(void *, get_fds_cb_fn, void *);
  set_fds_cb_fn config_set_fds_cb =
      (set_fds_cb_fn)dlsym(h, "TachyonComputeSessionConfig_setGetFdsResponseCallback");

  if (!service_create || !config_create || !config_set || !create_session) {
    put("dlsym: missing core symbol\n");
    return 1;
  }
  put("symbols: status_get=");
  puthex((unsigned long)status_get);
  put(" status_ok=");
  puthex((unsigned long)status_ok);
  put("\n");

  void *service = 0;
  void *  st = service_create(g_callbacks, &service);
  show_status(0, status_ok, "create", st);
  put("service=");
  puthex((unsigned long)service);
  put("\n");
  if (!service) return 1;

  void *config = config_create();
  if (!config) {
    put("config_create null\n");
    return 1;
  }
  config_set(config, privileged);
  // The AIDL SessionConfig carries a session type (offset 4) and the client's
  // version (offsets 8 and 0xc); CreateComputeSession passes exactly the two
  // version ints to ComputeSession::Create. Both default to 0, which the core
  // may treat as unknown and refuse to start. Stock sets them (TPU-PLAN U65).
  {
    typedef void (*set_type_fn)(void *, int);
    typedef void (*set_ver_fn)(void *, unsigned, unsigned);
    set_type_fn set_type = (set_type_fn)dlsym(
        h, "TachyonComputeSessionConfig_setSessionType");
    set_ver_fn set_ver = (set_ver_fn)dlsym(
        h, "TachyonComputeSessionConfig_setClientVersion");
    long type = parse_dec(getenv("STYPE"));
    long major = parse_dec(getenv("CVER_MAJOR"));
    long minor = parse_dec(getenv("CVER_MINOR"));

    if (set_type) {
      set_type(config, (int)type);
      put("session type=");
      putdec(type);
      put("\n");
    }
    if (set_ver) {
      set_ver(config, (unsigned)major, (unsigned)minor);
      put("client version=");
      putdec(major);
      put(".");
      putdec(minor);
      put("\n");
    }
  }
  if (config_set_fds_cb) {
    config_set_fds_cb(config, get_fds_cb, 0);
    put("get_fds_callback set\n");
  } else {
    put("get_fds_callback setter missing\n");
  }
  put("uid=");
  putdec((long)getuid());
  put(" privileged=");
  putdec(privileged);
  put("\n");
  put("config=");
  puthex((unsigned long)config);
  put("\n");

  void *session = 0;
  st = create_session(service, config, &session);
  show_status(0, status_ok, "createSession", st);
  put("session=");
  puthex((unsigned long)session);
  put("\n");
  if (!session) return 1;

  int fd0 = -1, fd1 = -1, fd2 = -1, fd3 = -1;
  if (setup_cmd) {
    void *r = setup_cmd(session, &fd0, &fd1);
    put("setupCommandQueue: r=");
    puthex((unsigned long)r);
    put(" fds=");
    putdec(fd0);
    put(",");
    putdec(fd1);
    put("\n");
    show_status(0, status_ok, "setupCommandQueue", r);
  }
  if (setup_rsp) {
    void *r = setup_rsp(session, &fd2, &fd3);
    put("setupResponseQueue: r=");
    puthex((unsigned long)r);
    put(" fds=");
    putdec(fd2);
    put(",");
    putdec(fd3);
    put("\n");
    show_status(0, status_ok, "setupResponseQueue", r);
  }
  show_fd(0, fd0);
  show_fd(1, fd1);
  show_fd(2, fd2);
  show_fd(3, fd3);
  // Assign a memfd to a client handle before the command that imports it. The
  // core's get_fds callback is for handles it needs back; the fd itself goes
  // out through this call (the lib's SendFileDescriptors).
  if (g_fd_handle) {
    typedef void *(*sendfds_fn)(void *, const int *, const long *, long);
    sendfds_fn sendfds =
        (sendfds_fn)dlsym(h, "TachyonComputeSession_sendFileDescriptors");

    if (sendfds) {
      const char *gf = getenv("GFILE");
      unsigned long size = g_dma_size;
      int graph_fd = -1;

      if (gf) {
        graph_fd = open(gf, 0);
        if (graph_fd < 0) {
          put("graph open failed: ");
          put(gf);
          put("\n");
        } else {
          long end = lseek(graph_fd, 0, 2);

          if (end > 0) size = (unsigned long)end;
          lseek(graph_fd, 0, 0);
        }
      }
      /* The import maps a dma-buf, not a memfd: a memfd gave "Could not map
         dma-buf 20 ... errno=Invalid argument". The system heap is the
         Android dma-buf allocator, and the TPU driver can map it. */
      {
        int heap = open("/dev/dma_heap/system", 2);

        if (heap < 0) {
          put("no /dev/dma_heap/system, errno ");
          putdec(*__errno());
          put("\n");
        } else {
          /* The kernel's ABI puts the output fd first: {len, fd, fd_flags,
             heap_flags}. The older {len, fd_flags, heap_flags, fd} order made
             the kernel read fd_flags as a nonzero fd and return EINVAL. */
          struct {
            unsigned long len;
            unsigned int fd;
            unsigned int fd_flags;
            unsigned long heap_flags;
          } a;

          memset(&a, 0, sizeof a);
          a.len = size;
          a.fd_flags = 0x80002;  /* O_RDWR | O_CLOEXEC */
          if (ioctl(heap, 0xc0184800UL, &a) != 0 || a.fd == 0) {
            put("dma_heap alloc failed, errno ");
            putdec(*__errno());
            put("\n");
          } else {
            void *p = mmap(0, size, 3, 1, (int)a.fd, 0);

            if (p == (void *)-1) {
              put("dma-buf mmap failed, errno ");
              putdec(*__errno());
              put("\n");
            } else {
              if (graph_fd >= 0) {
                long done = 0;

                while (done < (long)size) {
                  long n = read(graph_fd, (char *)p + done, size - done);

                  if (n <= 0) break;
                  done += n;
                }
                put("graph bytes ");
                putdec(done);
                put("\n");
                close(graph_fd);
              } else {
                memset(p, 0, size);
              }
              /* The system heap is CPU-cached; sync the writes before the
                 TPU maps it (DMA_BUF_IOCTL_SYNC, START|WRITE then END|WRITE). */
              {
                struct {
                  unsigned long flags;
                } sy;

                sy.flags = 2;  /* DMA_BUF_SYNC_START | WRITE */
                ioctl((int)a.fd, 0x40086200UL, &sy);
                sy.flags = 6;  /* DMA_BUF_SYNC_END | WRITE */
                ioctl((int)a.fd, 0x40086200UL, &sy);
              }
              g_dma_size = size;
              {
                int ifd = (int)a.fd;
                long h = (long)g_fd_handle;
                void *r = sendfds(session, &ifd, &h, 1);

                show_status(0, status_ok, "sendFileDescriptors", r);
              }
              g_graph_size = g_dma_size;
              /* RegisterGraph's GraphDescriptor field 0 is the firmware
                 scratch memory: its length must be at least the graph's
                 GetFwScratchBufferSize(). Allocate and send a second
                 system-heap dma-buf under the next client handle. */
              {
                const char *sf = getenv("SFILE");
                unsigned long ssize = (unsigned long)parse_dec(getenv("SSIZE"));
                int heap2 = open("/dev/dma_heap/system", 2);

                if (ssize == 0) ssize = 1 << 20;
                if (heap2 < 0) {
                  put("scratch: no dma_heap, errno ");
                  putdec(*__errno());
                  put("\n");
                } else {
                  struct {
                    unsigned long len;
                    unsigned int fd;
                    unsigned int fd_flags;
                    unsigned long heap_flags;
                  } a2;
                  int sifd = -1;

                  memset(&a2, 0, sizeof a2);
                  a2.len = ssize;
                  a2.fd_flags = 0x80002;
                  if (ioctl(heap2, 0xc0184800UL, &a2) != 0 || a2.fd == 0) {
                    put("scratch: alloc failed, errno ");
                    putdec(*__errno());
                    put("\n");
                  } else {
                    void *p2 = mmap(0, ssize, 3, 1, (int)a2.fd, 0);

                    if (p2 == (void *)-1) {
                      put("scratch: mmap failed, errno ");
                      putdec(*__errno());
                      put("\n");
                    } else {
                      int f2 = sf ? open(sf, 0) : -1;

                      if (f2 >= 0) {
                        long done = 0;

                        while (done < (long)ssize) {
                          long n = read(f2, (char *)p2 + done, ssize - done);

                          if (n <= 0) break;
                          done += n;
                        }
                        close(f2);
                      } else {
                        memset(p2, 0, ssize);
                      }
                      {
                        struct {
                          unsigned long flags;
                        } sy2;

                        sy2.flags = 2;
                        ioctl((int)a2.fd, 0x40086200UL, &sy2);
                        sy2.flags = 6;
                        ioctl((int)a2.fd, 0x40086200UL, &sy2);
                      }
                      sifd = (int)a2.fd;
                      g_scratch_size = ssize;
                      {
                        long h2 = (long)g_fd_handle + 1;
                        void *r = sendfds(session, &sifd, &h2, 1);

                        show_status(0, status_ok,
                                    "sendFileDescriptors scratch", r);
                      }
                    }
                  }
                  close(heap2);
                }
              }
            }
          }
          close(heap);
        }
      }
    } else {
      put("sendFileDescriptors symbol missing\n");
    }
  }
  // The core sends the firmware's setup message lazily, before the first
  // command it copies into the command FMQ. Send one zero-filled message so
  // that setup runs before the delegate's own VII sync (TPU-PLAN U58).
  // TachyonMessage is { uint64_t size; void *data; } passed in x1/x2; the
  // wrapper's third argument is not a size (TPU-PLAN U59).
  typedef void *(*send_fn)(void *, unsigned long, void *);
  send_fn send_cmd =
      (send_fn)dlsym(h, "TachyonComputeSession_sendCommand");
  struct tmsg {
    unsigned long size;
    void *data;
  };
  typedef void *(*recv_fn)(void *, struct tmsg *);
  recv_fn recv_rsp =
      (recv_fn)dlsym(h, "TachyonComputeSession_receiveResponse");
  // The cheetah lib moves the queue fds out of the session in
  // setupCommandQueue and leaves the session's own copies at -1, so the
  // legacy sendCommand may write where the actor never looks (U93). The
  // explicit write path reserves a slot, fills it and commits it:
  //   begin(session, bytes, &buf1, &len1, &buf2, &len2).
  typedef void *(*begin_write_fn)(void *, unsigned long, void **,
                                  unsigned long *, void **, unsigned long *);
  typedef void *(*commit_fn)(void *);
  begin_write_fn begin_write = (begin_write_fn)dlsym(
      h, "TachyonComputeSession_beginCommandQueueWrite");
  commit_fn commit_write =
      (commit_fn)dlsym(h, "TachyonComputeSession_commitCommandQueueWrite");
  put("queue write path: " );
  put(begin_write && commit_write ? "present\n" : "missing\n");

  // The core moves a new session CREATED to STARTED to AUTHORIZED on its own
  // actor, and an event that arrives before STARTED is held and never
  // re-examined. The stock caller therefore does not send its first command
  // in the same breath as createSession. DELAY gives the actor that time;
  // ROUNDS sends the command again if the first one was dropped (U65).
  rounds_env = ntypes > 0 ? ntypes : 0;
  {
    long delay = parse_dec(getenv("DELAY"));
    long rounds = rounds_env ? rounds_env : parse_dec(getenv("ROUNDS"));

    if (delay > 0 && delay <= 60) {
      put("waiting ");
      putdec(delay);
      put("s before the first command\n");
      sleep((unsigned)delay);
    }
    if (ntypes > 0) rounds = ntypes;
    else if (rounds <= 0 || rounds > 8) rounds = 2;
    if (!send_cmd) {
      put("sendCommand symbol missing\n");
    } else if (!recv_rsp) {
      put("receiveResponse symbol missing\n");
    } else {
      static unsigned char msg[512];
      long round;

      for (round = 1; round <= rounds; round++) {
        int this_type = ntypes > 0 ? types[round - 1] : cmd_type;
        if (ntypes > 0) {
          /* TYPES=2,5,5,7: round 2 imports the graph under HANDLE/FDH,
             round 3 the scratch under the next pair, round 4 registers. */
          if (round == 2) {
            g_handle = base_handle;
            g_fd_handle = base_fd;
            g_dma_size = g_graph_size;
          } else if (round == 3) {
            g_handle = base_handle + 1;
            g_fd_handle = base_fd + 1;
            g_dma_size = g_scratch_size;
          } else if (round == 4) {
            g_handle = base_handle;
            g_scratch = base_handle + 1;
            g_dma_size = g_graph_size;
          }
        }
        unsigned n = build_cmd(msg, this_type, round);
        static unsigned char rbuf[256];
        struct tmsg rm;
        unsigned i, tries;
        void *rr = 0;
        void *r = send_cmd(session, n, msg);

        put("round ");
        putdec(round);
        put(" ");
        show_status(0, status_ok, "sendCommand", r);
        {
          unsigned long one = 1;
          int k;

          for (k = 0; k < 4; k++) {
            if (g_is_ev[k]) {
              long rc = write(g_fd[k], &one, 8);

              put("ring fd ");
              putdec(g_fd[k]);
              put(" rc ");
              putdec(rc);
              if (rc < 0) {
                put(" errno ");
                putdec(*__errno());
              }
              put("\n");
            }
          }
        }
        if (getenv("QW") && round == 1 && begin_write && commit_write) {
          void *b1 = 0, *b2 = 0;
          unsigned long l1 = 0, l2 = 0;
          void *w = begin_write(session, 128, &b1, &l1, &b2, &l2);

          show_status(0, status_ok, "beginCommandQueueWrite", w);
          put("queue buffers: ");
          puthex((unsigned long)b1);
          put(" len ");
          putdec((long)l1);
          put(" / ");
          puthex((unsigned long)b2);
          put(" len ");
          putdec((long)l2);
          put("\n");
          /* begin returns 0 on success here, not an AStatus (U94): the
             buffers and lengths are the only result, so commit whenever a
             slot was reserved. */
          if (b1 && l1) {
            unsigned char q[128];
            unsigned qn = build_cmd(q, this_type, round);

            if (b1 && l1 >= qn) {
              memcpy(b1, q, qn);
            } else if (b1 && l1 && b2 && l2 >= qn - l1) {
              memcpy(b1, q, l1);
              memcpy(b2, q + l1, qn - l1);
            }
            {
              void *c = commit_write(session);

              show_status(0, status_ok, "commitCommandQueueWrite", c);
            }
          }
        }
        // Service-specific error 8 means "the response FMQ holds fewer than
        // 128 bytes": no answer yet, not a failure (the lib's
        // ReceiveResponseMessage builds exactly that status). Poll instead of
        // reading once, so a lazily produced answer is not missed.
        /* RegisterGraph and Invoke take longer than a Ping: poll 30 s. */
        for (tries = 0; tries < env_num("POLL", 300); tries++) {
          rm.size = sizeof rbuf;
          rm.data = rbuf;
          rr = recv_rsp(session, &rm);
          if (rr && status_ok && status_ok(rr) == 1)
            break;
          usleep(100000);
        }
        show_status(0, status_ok, "receiveResponse", rr);
        put("polled ");
        putdec((long)tries);
        put(" x 100ms\n");
        put("response size=");
        putdec((long)rm.size);
        put(" data=");
        for (i = 0; i < rm.size && i < 160; i++) {
          puthex(rbuf[i]);
          put(" ");
        }
        put("\n");
        put("ascii: ");
        for (i = 0; i < rm.size && i < 160; i++) {
          char ch[2];
          unsigned char b = rbuf[i];

          ch[0] = (b >= 32 && b < 127) ? (char)b : '.';
          ch[1] = 0;
          put(ch);
        }
        put("\n");
        if (rr && status_ok && status_ok(rr) == 1 && ntypes == 0) break;
        if (ntypes > 0 && round < rounds) sleep(1);
      }
    }
  }

  // Keep the session (and the core that owns it) alive while a delegate run
  // tests the firmware gate; the stock service dies on client disconnect.
  put("sleeping for the service's setup\n");
  sleep(120);
  put("done\n");
  return 0;
}
