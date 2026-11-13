// SPDX-License-Identifier: MIT
// Answer Android system-property calls without init's property service.
//
// With servicemanager and the Tachyon service running, the delegate still
// spins in CreateVirtualDevice because libbinder waits on system properties
// that only Android's init serves. This shim gives every lookup a fixed value
// and makes waits return immediately, so the service lookup can finish.
// Freestanding: no libc.
typedef unsigned int uint32_t;

static unsigned long str_len(const char *s)
{
	unsigned long n = 0;

	while (s[n])
		n++;
	return n;
}

static void copy(char *dst, const char *src, unsigned long max)
{
	unsigned long i = 0;

	while (src[i] && i + 1 < max) {
		dst[i] = src[i];
		i++;
	}
	dst[i] = 0;
}

static const char sdk_value[] = "34";
/* The vendor Edge TPU runtime reads ro.board.platform. The delegate needs
 * "mmio": PlatformTypeFromString accepts mmio/reference/simulator/
 * remote_simulator, and any other value makes it reject the device with
 * "Incorrect driver provider is used for the current device" before it opens
 * /dev/edgetpu. The Tachyon service's core hashes the same property into its
 * Darwinn platform type (GetPlatformId); "gs201" is the Pixel 7 generation's
 * ID (CityHash64 low 7 bits 0x77 -> platform 1), and gs201 is the TPU we
 * drive. Give the Tachyon service gs201 and every other process mmio. Build
 * with -DPLATFORM_VALUE or -DTACHYON_PLATFORM_VALUE to override. */
#ifndef PLATFORM_VALUE
#define PLATFORM_VALUE "mmio"
#endif
#ifndef TACHYON_PLATFORM_VALUE
#define TACHYON_PLATFORM_VALUE "gs201"
#endif
static const char platform_value[] = PLATFORM_VALUE;

/* Freestanding syscalls: a preloaded shim cannot rely on libc here. */
static long syscall4(long n, long a, long b, long c, long d)
{
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;

	__asm__ volatile("svc #0" : "+r"(x0)
			 : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}

static int contains(const char *hay, const char *needle)
{
	unsigned long i = 0;

	while (hay[i]) {
		unsigned long j = 0;

		while (needle[j] && hay[i + j] == needle[j])
			j++;
		if (!needle[j])
			return 1;
		i++;
	}
	return 0;
}

/* Two processes map ro.board.platform themselves: the Tachyon service's core
 * hashes it into a Darwinn platform type, and the NNAPI DBA service reads it
 * as its chip version ("Unknown chip_version found from device" otherwise,
 * TPU-STATUS U279). Both need gs201; the delegate keeps mmio. Read the
 * process's own cmdline, never argv. */
static int is_tachyon_service(void)
{
	static int cached = -1;
	char buf[256];
	long fd, n;

	if (cached >= 0)
		return cached;
	cached = 0;
	fd = syscall4(56 /* openat */, -100 /* AT_FDCWD */,
		      (long)"/proc/self/cmdline", 0, 0);
	if (fd < 0)
		return 0;
	n = syscall4(63 /* read */, fd, (long)buf, sizeof(buf) - 1, 0);
	syscall4(57 /* close */, fd, 0, 0, 0);
	if (n <= 0)
		return 0;
	buf[n] = 0;
	cached = contains(buf, "com.google.edgetpu.tachyon-service") ||
		 contains(buf, "com.google.edgetpu.dba-service");
	return cached;
}

static const char *get_platform_value(void)
{
	return is_tachyon_service() ? TACHYON_PLATFORM_VALUE : platform_value;
}
static const char empty_value[] = "";
/* The tachyon service sets its core VLOG level from this property. Level 2
 * logs the core's command dispatch and firmware-setup path; level 3 adds the
 * per-mailbox detail (TPU-PLAN U59/U64). */
static const char tachyon_log_value[] = "3";
/* The DBA service asks for this one (the Tachyon service asks for the
 * property above). Level 3 makes the DBA HAL log its session and setup path,
 * which is what tells a blocked createSession from a refused one (U284). */
static const char darwinn_log_value[] = "3";

static struct {
	char name[32];
	char value[92];
} fake_prop = {"ro.build.version.sdk", "34"};

// The caller that finds a property then reads it back must see the same name;
// libbinder copies and compares the name and a mismatch smashes its stack.
static char last_name[64] = "ro.build.version.sdk";

static int is_name(const char *name, const char *want)
{
	unsigned long i = 0;

	while (name[i] && want[i] && name[i] == want[i])
		i++;
	return name[i] == want[i];
}

int __system_property_get(const char *name, char *value)
{
	const char *v = "1";

	if (name && is_name(name, "servicemanager.ready"))
		v = "true";
	else if (name && is_name(name, "ro.build.version.sdk"))
		v = sdk_value;
	else if (name && is_name(name, "ro.board.platform"))
		v = get_platform_value();
	else if (name && is_name(name, "vendor.tachyon.log_level"))
		v = tachyon_log_value;
	else if (name && is_name(name, "vendor.darwinn.log_level"))
		v = darwinn_log_value;
	copy(value, v, 92);
	return (int)str_len(v);
}

const void *__system_property_find(const char *name)
{
	copy(last_name, name ? name : "", sizeof(last_name));
	return &fake_prop;
}

int __system_property_read_callback(const void *pi, void (*cb)(void *, const char *, const char *, uint32_t), void *cookie)
{
	const char *value = "1";

	(void)pi;
	if (is_name(last_name, "servicemanager.ready"))
		value = "true";
	else if (is_name(last_name, "ro.build.version.sdk"))
		value = sdk_value;
	else if (is_name(last_name, "ro.board.platform"))
		value = get_platform_value();
	else if (is_name(last_name, "vendor.tachyon.log_level"))
		value = tachyon_log_value;
	else if (is_name(last_name, "vendor.darwinn.log_level"))
		value = darwinn_log_value;
	if (cb)
		cb(cookie, last_name, value, 0);
	return 0;
}

int __system_property_wait(const void *pi, uint32_t old_serial, uint32_t *new_serial, const void *timeout)
{
	(void)pi;
	(void)timeout;
	if (new_serial)
		*new_serial = old_serial;
	return 0;
}

uint32_t __system_property_serial(const void *pi)
{
	(void)pi;
	return 0;
}

uint32_t __system_property_area_serial(void)
{
	return 0;
}

int __system_property_set(const char *name, const char *value)
{
	(void)name;
	(void)value;
	return 0;
}
