// SPDX-License-Identifier: MIT
// tpu-app-service: host the stock Edge TPU app service.
//
// The vendor image does not ship a process that publishes
// com.google.edgetpu.IEdgeTpuAppService/default, but libedgetpu_client.google.so
// exports the stock implementation (EdgeTpuServiceAppConnector::Create and
// BnEdgeTpuAppService::createBinder). The TFLite delegate and the Darwinn HAL
// are clients of that service: they ask it for the device fd, and only then
// does the util library create the Tachyon session and send the firmware setup
// command. Without the service the HAL's first VII sync fails with
// "Setup is not done yet" and the delegate never gets a device.
//
// This hosts the connector as root (so GetEdgeTpuFd can open /dev/edgetpu and
// the vendor compiler service can be reached), registers it on the vendor
// binder domain, and stays alive:
//   LD_PRELOAD="/system/lib64/libnosid.so ..." chroot $R /vendor/bin/tpu-app-service
//
// It is a development stand-in only: on stock Android the NNAPI HAL hosts the
// same connector.
//
// Build: clang --target=aarch64-linux-android30 -fPIE -pie -nostdlib \
//          -Wl,-e,_start -Wl,--dynamic-linker,/apex/com.android.runtime/bin/linker64 \
//          -L$R/vendor/lib64 -L$R/system/lib64 \
//          -L$R/apex/com.android.runtime/lib64/bionic \
//          -ledgetpu_client.google -lbinder_ndk -lbase -lcutils -lutils \
//          -lc++ -lc -lm -ldl -o tpu-app-service tpu-app-service.cc
#include <stdint.h>

typedef struct AIBinder AIBinder;
typedef struct AStatus AStatus;
extern "C" AStatus *AServiceManager_addService(AIBinder *binder, const char *instance);

namespace ndk {
// The real type wraps a shared_ptr<AIBinder>, so its destructor is non-trivial
// and the function returns it through the indirect-result register. Keeping an
// empty destructor gives the same ABI; the binder is deliberately never
// released because the service lives for the life of the process.
struct SpAIBinder {
	void *binder;
	void *control;
	~SpAIBinder() {}
	AIBinder *get() const { return (AIBinder *)binder; }
};
} // namespace ndk

namespace {

struct SharedPtr {
	void *object;
	void *control;
	~SharedPtr() {}
};

long sys_write(int fd, const void *buf, unsigned long len)
{
	register long x0 __asm__("x0") = fd;
	register const void *x1 __asm__("x1") = buf;
	register unsigned long x2 __asm__("x2") = len;
	register long x8 __asm__("x8") = 64;

	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
	return x0;
}

void out(const char *s)
{
	unsigned long n = 0;

	while (s[n])
		n++;
	sys_write(2, s, n);
}

void sleep_seconds(long s)
{
	struct timespec {
		long tv_sec;
		long tv_nsec;
	} ts = { s, 0 };
	register long x0 __asm__("x0") = (long)&ts;
	register long x1 __asm__("x1") = 0;
	register long x8 __asm__("x8") = 101; /* nanosleep */
	long rc;

	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x8) : "memory");
	rc = x0;
	(void)rc;
}

} // namespace

// Defined in libedgetpu_client.google.so. Create() returns the connector as a
// libc++ shared_ptr: object in x0, control block in x1.
extern "C" SharedPtr tpu_app_connector_create()
	__asm__("_ZN7android7darwinn26EdgeTpuServiceAppConnector6CreateEv");
extern "C" ndk::SpAIBinder tpu_app_connector_create_binder(void *self)
	__asm__("_ZN4aidl3com6google7edgetpu19BnEdgeTpuAppService12createBinderEv");
// The vendor services and the servicemanager all live on /dev/vndbinder; the
// stock HAL calls this before it creates anything. Without it the connector's
// lookup of the vendor service goes to /dev/binder and gets null.
// Returns an android::sp<ProcessState>: a non-trivial 8-byte object, so it
// comes back through the indirect-result register. Declaring it as an int made
// the callee write the singleton through an uninitialized x8 (a fault at 0x40).
extern "C" SharedPtr process_state_init_with_driver(const char *driver)
	__asm__("_ZN7android12ProcessState14initWithDriverEPKc");

extern "C" char *getenv(const char *name);

extern "C" void app_main(void)
{
	SharedPtr connector;
	ndk::SpAIBinder binder;
	AStatus *status;

	if (getenv && getenv("TPU_PROBE")) {
		SharedPtr state, probe;

		out("probe: Create\n");
		state = process_state_init_with_driver("/dev/vndbinder");
		probe = tpu_app_connector_create();
		out(probe.object ? "probe: found\n" : "probe: not found\n");
		return;
	}

	out("tpu-app-service: Create\n");
	{
		SharedPtr state = process_state_init_with_driver("/dev/vndbinder");

		if (!state.object)
			out("tpu-app-service: vndbinder init failed\n");
		else
			out("tpu-app-service: vndbinder ok\n");
	}
	connector = tpu_app_connector_create();
	out("tpu-app-service: Create returned\n");
	if (!connector.object) {
		out("tpu-app-service: Create failed\n");
		return;
	}

	binder = tpu_app_connector_create_binder(connector.object);
	out("tpu-app-service: createBinder\n");
	if (!binder.get()) {
		out("tpu-app-service: createBinder failed\n");
		return;
	}

	status = AServiceManager_addService(
		binder.get(), "com.google.edgetpu.IEdgeTpuAppService/default");
	(void)status;
	out("tpu-app-service: addService\n");

	for (;;) {
		sleep_seconds(30);
		out("tpu-app-service: alive\n");
	}
}

// The bionic libc starts a dynamic executable through __libc_init: it sets up
// TLS, runs constructors (including the vendor libraries' static initializers)
// and then calls main.
// The fourth argument is not a single function: bionic's __libc_init treats it
// as the executable's .init_array (it reads entries at +0, +8 and +16 from it),
// so a null here faults. This executable has no static constructors, so an
// all-zero array is the exact equivalent of its empty .init_array.
extern "C" void (*const tpu_app_init_array[4])(void);
void (*const tpu_app_init_array[4])(void) = { 0, 0, 0, 0 };

extern "C" void __libc_init(const void *raw_args, void (*onexit)(void),
			    void (*main_fn)(void), void (*init)(void));

__asm__(
".global _start\n"
"_start:\n"
"  mov x0, sp\n"
"  mov x1, #0\n"
"  adr x2, app_main\n"
"  adrp x3, tpu_app_init_array\n"
"  add x3, x3, :lo12:tpu_app_init_array\n"
"  bl __libc_init\n"
"  mov x8, #94\n"
"  mov x0, #1\n"
"  svc #0\n");
