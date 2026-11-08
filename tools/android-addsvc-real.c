// SPDX-License-Identifier: MIT
// Forward AServiceManager_addService to the real libbinder_ndk and print what
// servicemanager answers. The Power HAL ignores the status, so a refused
// registration looks the same as a successful one from outside; this shim is
// the only way to read the code.
//
// dlsym(RTLD_NEXT) finds nothing here (the preload is the first object and the
// chroot's linker config is missing), so open the library by name instead.
//
// Build: clang --target=aarch64-linux-android30 -shared -fPIC -nostdlib \
//          -fno-stack-protector -o libaddsvcreal.so android-addsvc-real.c

typedef struct AIBinder AIBinder;
typedef struct AStatus AStatus;

extern void *dlopen(const char *name, int flags);
extern void *dlsym(void *handle, const char *symbol);
extern long write(int fd, const void *buf, unsigned long count);

#define RTLD_NOW 2

static void *libbinder(void)
{
	static void *h;

	if (!h)
		h = dlopen("libbinder_ndk.so", RTLD_NOW);
	return h;
}

static void put(const char *s)
{
	unsigned long n = 0;

	while (s[n])
		n++;
	write(2, s, n);
}

static void puthex(unsigned long v)
{
	char b[19];
	int i;

	b[0] = '0';
	b[1] = 'x';
	for (i = 0; i < 16; i++)
		b[2 + i] = "0123456789abcdef"[(v >> (60 - 4 * i)) & 0xf];
	b[18] = '\n';
	write(2, b, 19);
}

static void mark(const char *what, const AStatus *status, int code)
{
	put("ADDSVC-REAL ");
	put(what);
	put(" ex=");
	puthex((unsigned long)code);
}

AStatus *AServiceManager_addService(AIBinder *binder, const char *instance)
{
	typedef AStatus *(*add_fn)(AIBinder *, const char *);
	typedef int (*code_fn)(const AStatus *);
	add_fn real = (add_fn)dlsym(libbinder(), "AServiceManager_addService");
	code_fn code = (code_fn)dlsym(libbinder(), "AStatus_getExceptionCode");
	AStatus *status;
	int exc;

	if (!real) {
		put("ADDSVC-REAL no symbol\n");
		return 0;
	}
	status = real(binder, instance);
	exc = status && code ? code(status) : -999;
	mark(instance ? instance : "(null)", status, exc);
	return status;
}
