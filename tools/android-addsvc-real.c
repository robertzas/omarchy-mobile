// SPDX-License-Identifier: MIT
// android-addsvc-real: report (and forward) the Power HAL's real registration.
//
// The Power HAL imports the plain AServiceManager_addService@LIBBINDER_NDK, so
// neither the lazy shim nor the flag-taking shim ever saw it, and nothing said
// whether servicemanager accepts a uid-1000 caller. Forward the call to the
// real implementation and log its AStatus, so "Unable to connect to Power HAL"
// can be traced to a refused registration or to the lookup side.
#include <stdint.h>

typedef struct AIBinder AIBinder;
typedef struct AStatus AStatus;

extern void *dlsym(void *handle, const char *symbol);
extern int AStatus_isOk(const AStatus *status);
extern long write(int fd, const void *buf, unsigned long count);

#define RTLD_NEXT ((void *)-1l)

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

static void mark(const char *what, const AStatus *status, int ok)
{
	write(2, "ADDSVC-REAL ", 12);
	while (*what)
		write(2, what++, 1);
	write(2, ok ? " ok ex=" : " REFUSED ex=", ok ? 8 : 13);
	/* AStatus starts with its exception code (0 == OK). */
	puthex(status ? (unsigned long)*(const int *)status : 0xdeadUL);
}

AStatus *AServiceManager_addService(AIBinder *binder, const char *instance)
{
	static AStatus *(*real)(AIBinder *, const char *);
	AStatus *status;
	int ok;

	if (!real)
		real = (AStatus *(*)(AIBinder *, const char *))
			dlsym(RTLD_NEXT, "AServiceManager_addService");
	status = real ? real(binder, instance) : (AStatus *)0;
	ok = status && AStatus_isOk(status);
	mark(instance ? instance : "(null)", status, ok);
	return status;
}
