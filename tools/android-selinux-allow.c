// SPDX-License-Identifier: MIT
// Let Android system binaries run on a Linux userspace without SELinux.
//
// servicemanager checks `selinux_status_open(true) >= 0` and aborts when the
// kernel has no selinuxfs (CONFIG_SECURITY_SELINUX is not set here). This shim
// answers the libselinux calls it makes: status opens cleanly, every check is
// allowed, and a service context handle is returned. Freestanding so it loads
// into bionic without a libc match. Install it as libselinux.so in the chroot
// so the linker cannot prefer the real one.
static long sys_write(int fd, const void *buf, unsigned long len)
{
	register long x0 asm("x0") = fd;
	register const void *x1 asm("x1") = buf;
	register unsigned long x2 asm("x2") = len;
	register long x8 asm("x8") = 64; /* __NR_write */

	asm volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
	return x0;
}

__attribute__((constructor)) static void marker(void)
{
	static const char msg[] = "SELINUX-SHIM\n";

	sys_write(2, msg, sizeof(msg) - 1);
}

static char service_context[] = "u:object_r:system_service:s0";

int selinux_status_open(int fallback)
{
	(void)fallback;
	return 0;
}

void selinux_status_close(void)
{
}

int selinux_status_updated(void)
{
	return 0;
}

int selinux_status_getenforce(void)
{
	return 0;
}

int selinux_check_access(const char *scon, const char *tcon, const char *tclass,
			 const char *perm, void *auditdata)
{
	(void)scon;
	(void)tcon;
	(void)tclass;
	(void)perm;
	(void)auditdata;
	return 0;
}

void selinux_set_callback(int type, void *cb)
{
	(void)type;
	(void)cb;
}

void selinux_log_callback(int type, const char *fmt, ...)
{
	(void)type;
	(void)fmt;
}

int selinux_android_service_context_handle(void)
{
	return 1;
}

int selinux_android_setcon(const char *scon)
{
	(void)scon;
	return 0;
}

int is_selinux_enabled(void)
{
	return 0;
}

int selinux_getenforce(void)
{
	return 0;
}

int security_policyvers(void)
{
	return 30;
}

int security_getenforce(void)
{
	return 0;
}

int selinux_android_restorecon(const char *path, unsigned int flags)
{
	(void)path;
	(void)flags;
	return 0;
}

int getcon(char **con)
{
	if (con)
		*con = service_context;
	return 0;
}

void freecon(char *con)
{
	(void)con;
}

int getpidcon(int pid, char **con)
{
	(void)pid;
	if (con)
		*con = service_context;
	return 0;
}

void *selabel_open(int backend, const void *opts, unsigned nopts)
{
	(void)backend;
	(void)opts;
	(void)nopts;
	return (void *)1;
}

void selabel_close(void *handle)
{
	(void)handle;
}

int selabel_lookup(void *handle, char **con, const char *key, int type)
{
	(void)handle;
	(void)key;
	(void)type;
	if (con)
		*con = service_context;
	return 0;
}
