// SPDX-License-Identifier: MIT
// tpu-tachyon-client: create a session on the stock Tachyon compute service.
//
// The A17 Edge TPU runtime has two compute paths. libedgetpu_util's direct
// VII path opens /dev/edgetpu itself and never sends the firmware's one-time
// setup command. The Tachyon path goes through
// com.google.edgetpu.tachyon.IComputeService/default, whose
// TachyonCore_CreateClientSession builds the session over a device fd from the
// EdgeTpu app service. The service binary carries the setup and its queue
// setup; this client is the missing caller.
//
// It is a development probe, not a runtime: create a session, set up the two
// FMQ queues, print their fds and sizes, then stay alive long enough for the
// service's asynchronous setup to run.
//
// Build (laptop, Android clang and the extracted vendor chroot):
//   CL=~/.cache/omamobile/toolchain/clang-r596125/bin/clang
//   C=out/vendor-chroot-edgetpu/root
//   $CL --target=aarch64-linux-android30 -x c++ -std=c++17 -O2 -fPIE -pie \
//       -nostdlib -fuse-ld=lld -Wl,-e,_start \
//       -Wl,--dynamic-linker,/system/bin/linker64 \
//       -o out/tpu-client/tpu-tachyon-client tools/tpu-tachyon-client.cc \
//       -L$C/apex/com.android.runtime/lib64/bionic -L$C/system/lib64 \
//       -L$C/vendor/lib64 -Wl,--no-as-needed -lbinder -lbinder_ndk -llog \
//       -lc -lm -ldl -lc++ $C/vendor/lib64/libedgetpu_tachyon.google.so
//
// Run inside the chroot after tools/tpu-tachyon-run has started the services:
//   LD_LIBRARY_PATH=/system_ext/lib64:/vendor/lib64:/system/lib64:/apex/com.android.runtime/lib64/bionic \
//   LD_PRELOAD="/system/lib64/libnosid.so /system/lib64/liblogstderr.so" \
//   chroot $R /system_ext/bin/tpu-tachyon-client
typedef unsigned long size_t;
typedef long ssize_t;

// ProcessState::initWithDriver returns android::sp<ProcessState>, a C++ class
// with a non-trivial return convention (the result goes through x8). The empty
// destructor keeps that convention; the object is deliberately not released
// because the process is short-lived.
struct SharedPtr {
  void *object;
  void *control;
  ~SharedPtr() {}
};

struct TachyonCallbacks {
  void *cookie;
  void *on_death;
  void *on_unlinked;
};

extern "C" {
long write(int, const void *, size_t);
char *getenv(const char *);
void _exit(int);
long syscall(long, ...);

SharedPtr process_state_init_with_driver(const char *)
    __asm__("_ZN7android12ProcessState14initWithDriverEPKc");

// The C API in libedgetpu_tachyon.google.so. create() takes a callback table
// (all-zero disables the death recipient); createSession() takes the service,
// a SessionConfig and an out pointer for the session. Both return an AStatus
// (NULL is also a failure), which the NDK helpers below decode.
void *TachyonComputeService_create(const TachyonCallbacks *, void **);
void *TachyonComputeService_createSession(void *, const void *, void **);
void *TachyonComputeSessionConfig_create(void);
void TachyonComputeSessionConfig_setPrivileged(void *, int);
void *TachyonComputeSession_setupCommandQueue(void *, int *, int *);
void *TachyonComputeSession_setupResponseQueue(void *, int *, int *);

int AStatus_isOk(const void *);
int AStatus_getExceptionCode(const void *);
int AStatus_getServiceSpecificError(const void *);
const char *AStatus_getMessage(const void *);

// bionic starts a dynamic executable through __libc_init. This client has no
// static constructors, so an all-zero .init_array is exact.
extern void (*const tpu_client_init_array[4])(void);
void __libc_init(const void *, void (*)(void), void (*)(void), void (*)(void));
}

void (*const tpu_client_init_array[4])(void) = {0, 0, 0, 0};

static void put(const char *s) {
  size_t n = 0;

  while (s[n])
    n++;
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

static void putdec(long v) {
  char b[24];
  int i = 23, neg = v < 0;
  unsigned long u = neg ? (unsigned long)-v : (unsigned long)v;

  b[i--] = 0;
  do {
    b[i--] = '0' + u % 10;
    u /= 10;
  } while (u);
  if (neg)
    b[i--] = '-';
  put(&b[i + 1]);
}

static int status(const char *what, void *st) {
  int ok = st && AStatus_isOk(st);

  put(what);
  put(": ");
  if (!st) {
    put("null\n");
    return 0;
  }
  put(ok ? "ok" : "FAILED");
  put(" exception ");
  putdec(AStatus_getExceptionCode(st));
  put(" service ");
  putdec(AStatus_getServiceSpecificError(st));
  {
    const char *msg = AStatus_getMessage(st);

    if (msg && msg[0]) {
      put(" \"");
      put(msg);
      put("\"");
    }
  }
  put("\n");
  return ok;
}

extern "C" __attribute__((used)) int client_main(void) {
  TachyonCallbacks cb = {0, 0, 0};
  SharedPtr state;
  void *service = 0;
  void *config;
  void *session = 0;
  void *st;
  int cfd = -1, csize = 0, rfd = -1, rsize = 0;
  int privileged = getenv("PRIV") != 0;
  int i;

  put("tpu-tachyon-client\n");
  state = process_state_init_with_driver("/dev/vndbinder");
  put("vndbinder: ");
  puthex((unsigned long)state.object);
  put("\n");
  if (!state.object) {
    put("vndbinder init failed\n");
    return 1;
  }

  st = TachyonComputeService_create(&cb, &service);
  if (!status("create", st) || !service)
    return 1;
  put("service: ");
  puthex((unsigned long)service);
  put("\n");

  config = TachyonComputeSessionConfig_create();
  put("config: ");
  puthex((unsigned long)config);
  put(" privileged ");
  putdec(privileged);
  put("\n");
  if (!config)
    return 1;
  TachyonComputeSessionConfig_setPrivileged(config, privileged);

  st = TachyonComputeService_createSession(service, config, &session);
  if (!status("createSession", st) || !session)
    return 1;
  put("session: ");
  puthex((unsigned long)session);
  put("\n");

  st = TachyonComputeSession_setupCommandQueue(session, &cfd, &csize);
  status("cmdq", st);
  put("cmdq: fd ");
  putdec(cfd);
  put(" size ");
  putdec(csize);
  put("\n");

  st = TachyonComputeSession_setupResponseQueue(session, &rfd, &rsize);
  status("rspq", st);
  put("rspq: fd ");
  putdec(rfd);
  put(" size ");
  putdec(rsize);
  put("\n");

  // The service's setup path runs asynchronously; give it time and keep the
  // session (and so its device context) alive.
  for (i = 0; i < 15; i++) {
    struct {
      long sec;
      long nsec;
    } ts = {1, 0};

    syscall(101, &ts, 0);
  }
  put("done\n");
  return 0;
}

extern "C" __attribute__((naked)) void _start(void) {
  __asm__ volatile(
      "mov x0, sp\n"
      "mov x1, #0\n"
      "adr x2, client_main\n"
      "adrp x3, tpu_client_init_array\n"
      "add x3, x3, :lo12:tpu_client_init_array\n"
      "bl __libc_init\n"
      "mov x8, #94\n"
      "mov x0, #1\n"
      "svc #0\n");
}
