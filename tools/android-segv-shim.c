// SPDX-License-Identifier: MIT
// Name the faulting address and call chain when a vendor binary dies with a
// signal.
//
// The Tachyon core parses a RegisterGraph command, builds the VII command and
// then disappears with no log line at all (TPU-PLAN U122). bionic installs no
// crash handler, so a SIGSEGV prints nothing and the client only sees
// DEAD_OBJECT. This shim prints the signal, the faulting PC/LR/SP and a
// frame-pointer backtrace, with the module and offset of every address, so the
// crash maps onto the stripped .so on the laptop.
//
// Build (NDK, aarch64):
//   $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang \
//     --target=aarch64-linux-android30 -O2 -fPIC -shared \
//     -o out/tpu-client/libsegvshim.so tools/android-segv-shim.c
#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>

static void emit(const char *s)
{
	write(2, s, strlen(s));
}

static void emit_hex(unsigned long v)
{
	char b[19];
	int i = 18;

	b[18] = 0;
	if (!v) {
		emit("0");
		return;
	}
	while (v && i > 0) {
		unsigned d = v & 0xf;

		b[--i] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
		v >>= 4;
	}
	emit(b + i);
}

static void emit_addr(const char *tag, unsigned long v)
{
	Dl_info di;

	emit(tag);
	emit_hex(v);
	if (dladdr((void *)v, &di) && di.dli_fname) {
		const char *base = strrchr(di.dli_fname, '/');

		emit(" ");
		emit(base ? base + 1 : di.dli_fname);
		emit("+");
		emit_hex(v - (unsigned long)di.dli_fbase);
	}
	emit("\n");
}

/* A userspace address, so a dump of it cannot fault in the handler. */
static int user_ptr(unsigned long p)
{
	p &= 0x00ffffffffffffffUL;  /* MTE tags the top byte (TBI) */
	return p >= 0x1000 && p < 0x0001000000000000UL;
}

static void dump(const char *tag, unsigned long p, int n)
{
	int i;

	if (!user_ptr(p))
		return;
	emit(tag);
	emit_hex(p);
	emit(":");
	for (i = 0; i < n; i++) {
		emit(" ");
		emit_hex(((volatile unsigned long *)p)[i]);
	}
	emit("\n");
}

static void segv(int sig, siginfo_t *si, void *uc_)
{
	ucontext_t *uc = (ucontext_t *)uc_;
	unsigned long pc = 0, lr = 0, sp = 0, fp = 0;
	unsigned long *frame;
	int i;

#ifdef __aarch64__
	pc = (unsigned long)uc->uc_mcontext.pc;
	lr = (unsigned long)uc->uc_mcontext.regs[30];
	sp = (unsigned long)uc->uc_mcontext.sp;
	fp = (unsigned long)uc->uc_mcontext.regs[29];
#endif
	emit("SIG ");
	emit_hex((unsigned long)sig);
	emit(" addr ");
	emit_hex((unsigned long)(si ? si->si_addr : 0));
	emit("\n");
	emit_addr("pc ", pc);
	emit_addr("lr ", lr);
	emit("sp ");
	emit_hex(sp);
	emit(" fp ");
	emit_hex(fp);
	emit("\n");
#ifdef __aarch64__
	{
		unsigned long *r = (unsigned long *)uc->uc_mcontext.regs;
		unsigned long o = r[21] & 0x00ffffffffffffffUL;
		int k;

		emit("x19..x28:");
		for (k = 19; k <= 28; k++) {
			emit(" ");
			emit_hex(r[k]);
		}
		emit("\n");
		/* The command object the faulting frame walks: its fields name
		   which flatbuffer slot the core failed to fill (U123). */
		dump("obj", o, 24);
		dump("obj+0x10", user_ptr(o) ? *(unsigned long *)(o + 0x10) : 0, 6);
		dump("obj+0x20", user_ptr(o) ? *(unsigned long *)(o + 0x20) : 0, 6);
		dump("obj+0x38", user_ptr(o) && *(unsigned long *)(o + 0x38)
		     ? *(unsigned long *)(o + 0x38) : 0, 6);
	}
#endif
	/* The frame pointer chain: [fp] is the caller's fp, [fp+8] the return
	   address into the caller. Stop on a frame that does not grow. */
	frame = (unsigned long *)fp;
	for (i = 0; i < 32 && frame; i++) {
		unsigned long ret;
		unsigned long *next;

		if ((unsigned long)frame & 7)
			break;
		ret = frame[1];
		if (!ret)
			break;
		emit_addr("#", ret);
		next = (unsigned long *)frame[0];
		if (next <= frame)
			break;
		frame = next;
	}
	emit("segv-shim: exiting\n");
	_exit(128 + sig);
}

__attribute__((constructor)) static void install(void)
{
	static char stack[64 * 1024];
	stack_t ss;
	struct sigaction sa;
	/* No SIGABRT: libabortshim makes abort() return so libbase's CHECKs do
	   not kill a vendor service, and catching it here would undo that. */
	int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE };
	unsigned i;

	ss.ss_sp = stack;
	ss.ss_size = sizeof stack;
	ss.ss_flags = 0;
	sigaltstack(&ss, 0);
	memset(&sa, 0, sizeof sa);
	sa.sa_sigaction = segv;
	sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
	sigemptyset(&sa.sa_mask);
	for (i = 0; i < sizeof sigs / sizeof sigs[0]; i++)
		sigaction(sigs[i], &sa, 0);
	emit("segv-shim: installed\n");
}
