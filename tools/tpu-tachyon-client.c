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

static unsigned build_cmd(unsigned char *b) {
  /* root table at 36, its vtable at 24; union vtable at 56, union table at 60 */
  int i;

  for (i = 0; i < 128; i++) b[i] = 0;
  put32(b + 0, 36);
  put16(b + 24, 0x0c);
  put16(b + 26, 0x18);
  put16(b + 28, 4);
  put16(b + 30, 12);
  put16(b + 32, 13);
  put16(b + 34, 16);
  put32(b + 36, 12);
  put64(b + 40, 1);
  b[48] = 1;  /* privileged, matching the session config */
  b[49] = 1;  /* union type 1 (the core's first known command type) */
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

int main(int argc, char **argv) {
  /* argv[1] "0" asks for an unprivileged session; default is privileged
   * (the config the app service uses). */
  int privileged = 1;
  if (argc > 1 && argv[1] && argv[1][0] == '0') privileged = 0;
  void *h = dlopen("/vendor/lib64/libedgetpu_tachyon.google.so",
                   RTLD_NOW | RTLD_GLOBAL);
  if (!h) {
    put("dlopen: ");
    put(dlerror() ? dlerror() : "?");
    put("\n");
    return 1;
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
  // The core sends the firmware's setup message lazily, before the first
  // command it copies into the command FMQ. Send one zero-filled message so
  // that setup runs before the delegate's own VII sync (TPU-PLAN U58).
  // TachyonMessage is { uint64_t size; void *data; } passed in x1/x2; the
  // wrapper's third argument is not a size (TPU-PLAN U59).
  typedef void *(*send_fn)(void *, unsigned long, void *);
  send_fn send_cmd =
      (send_fn)dlsym(h, "TachyonComputeSession_sendCommand");
  if (send_cmd) {
    static unsigned char msg[128];
    unsigned n = build_cmd(msg);

    void *r = send_cmd(session, n, msg);
    show_status(0, status_ok, "sendCommand", r);
    /* The core answers on the response FMQ. Its answer says whether the
     * command reached the actor that sends the firmware setup. */
    struct tmsg {
      unsigned long size;
      void *data;
    };
    typedef void *(*recv_fn)(void *, struct tmsg *);
    recv_fn recv_rsp =
        (recv_fn)dlsym(h, "TachyonComputeSession_receiveResponse");
    if (recv_rsp) {
      static unsigned char rbuf[256];
      struct tmsg rm;
      unsigned i;

      rm.size = sizeof rbuf;
      rm.data = rbuf;
      void *rr = recv_rsp(session, &rm);
      show_status(0, status_ok, "receiveResponse", rr);
      put("response size=");
      putdec((long)rm.size);
      put(" data=");
      for (i = 0; i < rm.size && i < 64; i++) {
        puthex(rbuf[i]);
        put(" ");
      }
      put("\n");
    } else {
      put("receiveResponse symbol missing\n");
    }
  } else {
    put("sendCommand symbol missing\n");
  }

  // Keep the session (and the core that owns it) alive while a delegate run
  // tests the firmware gate; the stock service dies on client disconnect.
  put("sleeping for the service's setup\n");
  sleep(120);
  put("done\n");
  return 0;
}
