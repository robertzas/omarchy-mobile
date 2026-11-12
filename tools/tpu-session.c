/* SPDX-License-Identifier: MIT */
/*
 * tpu-session: create a tachyon compute service and a session over binder,
 * the step stock's edgetpu_app_service takes before it opens a TPU session.
 *
 * Signatures (from the disassembly of libedgetpu_tachyon.google.so):
 *   TachyonComputeService_create(x0, x1)         - x1 captured, name/options
 *   TachyonComputeService_createSession(x0, x1, x2)
 *                                                - service, config, ret; all
 *                                                  three null-checked
 * The C API reports success as a null TachyonStatus.
 *
 * Runs inside the vendor chroot (tools/tpu-exec.py) with the chain up.
 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct TachyonComputeService TCS;
typedef struct TachyonStatus TStatus;

static void *h;

static void *sym(const char *n)
{
	void *p = dlsym(h, n);

	if (!p)
		fprintf(stderr, "missing symbol %s\n", n);
	return p;
}

static int st(const char *what, TStatus *s)
{
	if (!s) {
		printf("%s: ok\n", what);
		return 0;
	}
	printf("%s: status %d\n", what, *((int32_t *)s));
	return -1;
}

int main(void)
{
	TStatus *(*create)(TCS **, const char *);
	TStatus *(*create_session)(TCS *, const void *, void *);
	void *(*cfg_create)(void);
	TStatus *(*cfg_privileged)(void *, int);
	unsigned char ret[0x100];
	uint64_t *q = (uint64_t *)ret;
	TCS *svc = NULL;
	void *cfg;
	TStatus *s;

	h = dlopen("libedgetpu_tachyon.google.so", RTLD_NOW | RTLD_GLOBAL);
	if (!h) {
		fprintf(stderr, "dlopen: %s\n", dlerror());
		return 1;
	}

	create = (void *)sym("TachyonComputeService_create");
	create_session = (void *)sym("TachyonComputeService_createSession");
	cfg_create = (void *)sym("TachyonComputeSessionConfig_create");
	cfg_privileged = (void *)sym("TachyonComputeSessionConfig_setPrivileged");
	if (!create || !create_session || !cfg_create)
		return 1;

	s = create(&svc, "default");
	st("create(service)", s);
	printf("  service=%p\n", (void *)svc);
	if (!svc)
		return 1;

	cfg = cfg_create();
	printf("  config=%p\n", cfg);
	if (cfg && cfg_privileged)
		st("  setPrivileged(1)", cfg_privileged(cfg, 1));

	memset(ret, 0, sizeof(ret));
	s = create_session(svc, cfg, ret);
	st("createSession", s);
	printf("  ret=%016lx %016lx %016lx %016lx\n",
	       (unsigned long)q[0], (unsigned long)q[1],
	       (unsigned long)q[2], (unsigned long)q[3]);
	fflush(stdout);
	return 0;
}
