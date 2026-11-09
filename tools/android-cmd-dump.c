// SPDX-License-Identifier: MIT
// Dump every Tachyon command the vendor client sends, as length-prefixed
// frames, so the exact litebuf layout of a working RegisterGraph can be read
// instead of guessed.
//
// The Tachyon client library hands each command flatbuffer to
// TachyonComputeSession_sendCommand (libedgetpu_tachyon.google.so). The stock
// delegate is the one caller whose commands the core accepts, so preloading
// this into the delegate interposes that call and tees the bytes to
// /data/local/tmp/tpu-cmds.bin inside the chroot (host:
// $R/data/local/tmp/tpu-cmds.bin). Format: u32 length + payload, repeated.
//
// Build (Android clang, aarch64):
//   $CL --target=aarch64-linux-android30 -O2 -fPIC -shared -nostdlib \
//     -o out/tpu-client/libcmddump.so tools/android-cmd-dump.c
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <unistd.h>

typedef void *(*send_fn)(void *, const void *, size_t);

static send_fn real_send;
static int out = -1;

static void put(const void *p, size_t n)
{
	const char *c = p;

	while (n) {
		ssize_t r = write(out, c, n);

		if (r <= 0)
			return;
		c += r;
		n -= (size_t)r;
	}
}

void *TachyonComputeSession_sendCommand(void *session, const void *buf, size_t n)
{
	uint32_t len = n > 8192 ? 8192 : (uint32_t)n;

	if (!real_send)
		real_send = (send_fn)dlsym(RTLD_NEXT, "TachyonComputeSession_sendCommand");
	if (out >= 0) {
		put(&len, 4);
		put(buf, len);
	}
	return real_send ? real_send(session, buf, n) : 0;
}

__attribute__((constructor)) static void install(void)
{
	out = open("/data/local/tmp/tpu-cmds.bin", O_WRONLY | O_CREAT | O_APPEND, 0644);
	write(2, "cmddump: installed\n", 19);
}
