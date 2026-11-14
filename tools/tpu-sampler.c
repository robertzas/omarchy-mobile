// SPDX-License-Identifier: MIT
//
// tpu-sampler: read a blocked thread's registers and user stack from outside
// the process, and resolve every stack word that points into an executable
// mapping as module+offset.
//
// Why standalone: TPU-PLAN 1.6 records that ptrace from inside a preloaded .so
// is not trustworthy on this device (PTRACE_ATTACH and GETREGSET report
// success while sp reads 0x3d3d3d3d3d3d3d3d and process_vm_readv returns -1,
// U302). A separate process attaching from outside has none of that ambiguity:
// the kernel stops the target thread, gives it a clean register set and lets a
// different process read its stack.
//
// Use:
//   gcc -O2 -static -o tpu-sampler tools/tpu-sampler.c
//   tpu-sampler PID [--stack BYTES] [--wait SECONDS] [--all]
//
// Default: only threads blocked in futex (aarch64 syscall 98) are sampled,
// because the HAL's create waits there. --all samples every thread.
//
// Output, per sampled thread:
//   tid N syscall 98 futex uaddr 0x...
//   pc 0x... module+0x...   lr ...   sp ...
//   stack word <addr> -> <module>+<off>
//
// The offset is the *file* offset (mapping offset + delta), so the same number
// can be looked up with objdump --start-address on the library from the host.

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

#define NT_PRSTATUS 1
#ifndef PTRACE_GETREGSET
#define PTRACE_GETREGSET 0x4204
#endif
#define SYS_FUTEX 98
#define MAX_MAPS 400
#define MAX_THREADS 256

struct regs {
	uint64_t x[31];
	uint64_t sp;
	uint64_t pc;
	uint64_t pstate;
};

struct map {
	uint64_t start, end, off;
	int exec;
	char path[256];
};

static struct map maps[MAX_MAPS];
static int nmaps;

static int read_file(const char *path, char *buf, size_t len)
{
	int fd = open(path, O_RDONLY);
	ssize_t n;

	if (fd < 0)
		return -1;
	n = read(fd, buf, len - 1);
	close(fd);
	if (n < 0)
		return -1;
	buf[n] = 0;
	return (int)n;
}

static const char *base(const char *p)
{
	const char *s = strrchr(p, '/');

	return s ? s + 1 : p;
}

static int load_maps(pid_t pid)
{
	char path[64], buf[524288];
	char *line, *save;
	int n;

	snprintf(path, sizeof(path), "/proc/%d/maps", (int)pid);
	n = read_file(path, buf, sizeof(buf));
	if (n < 0)
		return -1;
	nmaps = 0;
	for (line = strtok_r(buf, "\n", &save); line && nmaps < MAX_MAPS;
	     line = strtok_r(NULL, "\n", &save)) {
		unsigned long long s, e, o;
		char perms[8], dev[16], p[256] = "";
		int inode;

		if (sscanf(line, "%llx-%llx %7s %llx %15s %d %255s", &s, &e,
			   perms, &o, dev, &inode, p) < 6)
			continue;
		maps[nmaps].start = s;
		maps[nmaps].end = e;
		maps[nmaps].off = o;
		maps[nmaps].exec = perms[2] == 'x';
		snprintf(maps[nmaps].path, sizeof(maps[nmaps].path), "%s",
			 base(p));
		nmaps++;
	}
	return 0;
}

static struct map *find_map(uint64_t addr)
{
	int i;

	for (i = 0; i < nmaps; i++)
		if (addr >= maps[i].start && addr < maps[i].end)
			return &maps[i];
	return NULL;
}

/* File offset for an address, i.e. the value objdump wants. */
static uint64_t file_off(uint64_t addr)
{
	struct map *m = find_map(addr);

	if (!m)
		return addr;
	return m->off + (addr - m->start);
}

static void show_addr(const char *tag, uint64_t addr)
{
	struct map *m = find_map(addr);

	if (m && m->path[0])
		printf("%s 0x%llx %s+0x%llx", tag, (unsigned long long)addr,
		       m->path, (unsigned long long)file_off(addr));
	else if (m)
		printf("%s 0x%llx [anon+0x%llx]", tag, (unsigned long long)addr,
		       (unsigned long long)file_off(addr));
	else
		printf("%s 0x%llx [?]", tag, (unsigned long long)addr);
}

static int read_comm(pid_t tid, char *out, size_t len)
{
	char path[96];
	int fd;
	ssize_t n;

	snprintf(path, sizeof(path), "/proc/%d/comm", (int)tid);
	fd = open(path, O_RDONLY);
	if (fd < 0)
		return -1;
	n = read(fd, out, len - 1);
	close(fd);
	if (n <= 0)
		return -1;
	if (out[n - 1] == '\n')
		n--;
	out[n] = 0;
	return 0;
}

static int read_syscall(pid_t pid, long *nr, unsigned long *a0)
{
	char path[96], buf[512];
	int n;

	snprintf(path, sizeof(path), "/proc/%d/syscall", (int)pid);
	n = read_file(path, buf, sizeof(buf));
	if (n <= 0)
		return -1;
	*nr = strtol(buf, NULL, 10);
	*a0 = 0;
	{
		char *p = strchr(buf, ' ');

		if (p)
			*a0 = strtoul(p + 1, NULL, 16);
	}
	return 0;
}

static int sample(pid_t tid, pid_t pid, int stack_bytes, int all)
{
	long nr = -1;
	unsigned long a0 = 0;
	struct regs r;
	struct iovec iov;
	char path[96];
	int st, i, printed = 0;
	uint64_t sp, start;
	unsigned char stack[16384];
	struct iovec local, remote;
	ssize_t got;

	if (read_syscall(tid, &nr, &a0) < 0) {
		fprintf(stderr, "tpu-sampler: tid %d: no syscall file\n", (int)tid);
		return -1;
	}
	if (!all && nr != SYS_FUTEX)
		return 0;

	printf("tid %d", (int)tid);
	{
		char comm[64] = "?";

		if (read_comm(tid, comm, sizeof(comm)) == 0)
			printf(" (%s)", comm);
	}
	printf(" syscall %ld%s", nr, nr == SYS_FUTEX ? " (futex)" : "");
	if (nr == SYS_FUTEX) {
		uint32_t fw = 0;
		struct iovec fl, fr;

		printf(" uaddr 0x%lx", a0);
		fl.iov_base = &fw;
		fl.iov_len = sizeof(fw);
		fr.iov_base = (void *)a0;
		fr.iov_len = sizeof(fw);
		if (process_vm_readv(pid, &fl, 1, &fr, 1, 0) == (ssize_t)sizeof(fw))
			printf(" word %u (0x%08x)", fw, fw);
		else
			printf(" word unreadable: %s", strerror(errno));
	}
	printf("\n");

	/* SIGSTOP wakes an interruptible futex wait, so ATTACH stops it. */
	if (ptrace(PTRACE_ATTACH, tid, NULL, NULL) < 0) {
		printf("  attach failed: %s\n", strerror(errno));
		return -1;
	}
	if (waitpid(tid, &st, __WALL) < 0 || !WIFSTOPPED(st)) {
		printf("  wait failed: %s (status 0x%x)\n", strerror(errno), st);
		ptrace(PTRACE_DETACH, tid, NULL, NULL);
		return -1;
	}

	memset(&r, 0, sizeof(r));
	iov.iov_base = &r;
	iov.iov_len = sizeof(r);
	if (ptrace(PTRACE_GETREGSET, tid, (void *)NT_PRSTATUS, &iov) < 0) {
		printf("  getregset failed: %s\n", strerror(errno));
		ptrace(PTRACE_DETACH, tid, NULL, NULL);
		return -1;
	}

	show_addr("  pc", r.pc);
	printf("\n");
	show_addr("  lr", r.x[30]);
	printf("\n");
	show_addr("  sp", r.sp);
	printf("\n");
	printf("  pstate 0x%llx x29 0x%llx\n",
	       (unsigned long long)r.pstate, (unsigned long long)r.x[29]);

	if (load_maps(pid) < 0) {
		printf("  maps unreadable\n");
		ptrace(PTRACE_DETACH, tid, NULL, NULL);
		return -1;
	}

	sp = r.sp & ~7ULL;
	start = sp;
	if (stack_bytes > (int)sizeof(stack))
		stack_bytes = sizeof(stack);
	local.iov_base = stack;
	local.iov_len = stack_bytes;
	remote.iov_base = (void *)start;
	remote.iov_len = stack_bytes;
	got = process_vm_readv(pid, &local, 1, &remote, 1, 0);
	if (got <= 0) {
		printf("  process_vm_readv failed: %s\n", strerror(errno));
		ptrace(PTRACE_DETACH, tid, NULL, NULL);
		return -1;
	}

	for (i = 0; i + 8 <= got; i += 8) {
		uint64_t w;

		memcpy(&w, stack + i, 8);
		if (!w)
			continue;
		{
			struct map *m = find_map(w);

			if (!m || !m->exec)
				continue;
		}
		if (printed++ >= 48) {
			printf("  ... more frames suppressed\n");
			break;
		}
		printf("  stack[0x%04llx] ",
		       (unsigned long long)((uint64_t)i));
		show_addr("", w);
		printf("\n");
	}
	if (!printed)
		printf("  no stack word points into an executable mapping\n");

	snprintf(path, sizeof(path), "/proc/%d/task", (int)pid);
	(void)path;
	ptrace(PTRACE_DETACH, tid, NULL, NULL);
	return 1;
}

static int numeric(const char *s)
{
	if (!*s)
		return 0;
	while (*s)
		if (*s < '0' || *s > '9')
			return 0;
		else
			s++;
	return 1;
}

int main(int argc, char **argv)
{
	pid_t pid, tids[MAX_THREADS];
	int n = 0, i, stack_bytes = 8192, all = 0, waitsec = 0, sampled = 0;
	char dir[64];
	struct dirent *de;
	DIR *d;

	if (argc < 2) {
		fprintf(stderr,
			"usage: tpu-sampler PID [--stack BYTES] [--wait SEC] [--all]\n");
		return 2;
	}
	pid = atoi(argv[1]);
	for (i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "--stack") && i + 1 < argc)
			stack_bytes = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--wait") && i + 1 < argc)
			waitsec = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--all"))
			all = 1;
		else {
			fprintf(stderr, "tpu-sampler: unknown argument %s\n", argv[i]);
			return 2;
		}
	}

	for (;;) {
		n = 0;
		snprintf(dir, sizeof(dir), "/proc/%d/task", (int)pid);
		d = opendir(dir);
		if (!d) {
			fprintf(stderr, "tpu-sampler: %s: %s\n", dir, strerror(errno));
			return 1;
		}
		while ((de = readdir(d)) && n < MAX_THREADS)
			if (numeric(de->d_name))
				tids[n++] = atoi(de->d_name);
		closedir(d);
		sampled = 0;
		for (i = 0; i < n; i++) {
			int rc = sample(tids[i], pid, stack_bytes, all);

			if (rc > 0)
				sampled++;
		}
		if (sampled || waitsec-- <= 0)
			break;
		usleep(200000);
	}
	if (!sampled)
		fprintf(stderr, "tpu-sampler: no sampled thread in %d\n", (int)pid);
	return sampled ? 0 : 1;
}
