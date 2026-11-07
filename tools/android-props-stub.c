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
static const char empty_value[] = "";

static struct {
	char name[32];
	char value[92];
} fake_prop = {"ro.build.version.sdk", "34"};

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

	if (name && is_name(name, "ro.build.version.sdk"))
		v = sdk_value;
	copy(value, v, 92);
	return (int)str_len(v);
}

const void *__system_property_find(const char *name)
{
	(void)name;
	return &fake_prop;
}

int __system_property_read_callback(const void *pi, void (*cb)(void *, const char *, const char *, uint32_t), void *cookie)
{
	(void)pi;
	if (cb)
		cb(cookie, "servicemanager.ready", "1", 0);
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
