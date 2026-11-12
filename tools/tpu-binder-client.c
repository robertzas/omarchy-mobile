/* SPDX-License-Identifier: MIT */
/*
 * tpu-binder-client: talk to the tachyon compute service over raw binder.
 *
 * Why not the C API: libedgetpu_tachyon.google.so is bionic, and the phone's
 * Arch root has no bionic toolchain (tools/tpu-session.c ended at SIGTRAP).
 * Binder is a kernel interface, so a glibc process can resolve the service
 * and transact to it directly (see device/cheetah/TPU-PLAN.md U238).
 *
 * Usage: tpu-binder-client [NODE] [METHOD] [WORD...]
 *   NODE    binder device (default /dev/binderfs/vndbinder)
 *   METHOD  createSession method code (default 1)
 *   WORDs   32-bit words for the SessionConfig, after the header+descriptor
 *
 * Prints the reply parcel words and offsets so the layout can be read off
 * the service's own answer instead of guessed.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef int32_t s32;
typedef uint64_t u64;

struct binder_write_read {
	u64 write_size, write_consumed;
	u64 write_buffer;
	u64 read_size, read_consumed;
	u64 read_buffer;
};

struct binder_transaction_data {
	union { u32 handle; u64 ptr; } target;
	u64 cookie;
	u32 code;
	u32 flags;
	s32 sender_pid;
	u32 sender_euid;
	u64 data_size;
	u64 offsets_size;
	union { struct { u64 buffer; u64 offsets; } ptr; u8 buf[8]; } data;
};

#define BINDER_WRITE_READ	_IOWR('b', 1, struct binder_write_read)
#define BC_TRANSACTION		_IOW('c', 0, struct binder_transaction_data)
#define BC_FREE_BUFFER		_IOW('c', 3, u64)
#define BR_REPLY		_IOR('r', 1, struct binder_transaction_data)
#define BR_TRANSACTION_COMPLETE	0x7206

#define FLAT_BINDER_BINDER	1
#define FLAT_BINDER_HANDLE	3

struct parcel {
	u8 buf[1024];
	u32 len;
	u32 off[8];
	u32 noff;
};

static void put32(struct parcel *p, u32 v)
{
	memcpy(p->buf + p->len, &v, 4);
	p->len += 4;
}

static void putstr16(struct parcel *p, const char *s)
{
	u32 n = strlen(s), i;

	put32(p, n);
	for (i = 0; i < n; i++) {
		u16 c = (u8)s[i];

		memcpy(p->buf + p->len, &c, 2);
		p->len += 2;
	}
	while (p->len % 4)
		p->buf[p->len++] = 0;
}

/* flat_binder_object: type, flags, binder/handle, cookie */
static void put_obj(struct parcel *p, u32 type, u64 value)
{
	p->off[p->noff++] = p->len;
	put32(p, type);
	put32(p, 0);
	memcpy(p->buf + p->len, &value, 8);
	p->len += 8;
	put32(p, 0);
	put32(p, 0);
}

static void dump_parcel(const char *what, const u8 *b, u32 len, const u32 *off,
			u32 noff)
{
	u32 i;

	printf("%s: %u bytes\n", what, len);
	for (i = 0; i < len; i += 4) {
		u32 v;

		memcpy(&v, b + i, 4);
		printf("  [%3u] %08x (%d)\n", i, v, (s32)v);
	}
	for (i = 0; i < noff; i++)
		printf("  object @%u: type %u handle/ptr %" PRIx64 "\n", off[i],
		       *(u32 *)(b + off[i]),
		       *(u64 *)(b + off[i] + 8));
}

/*
 * One synchronous transaction. Returns 0 and fills the reply parcel, or -1.
 * out_binder: the first object the reply returns, as a local handle, or 0.
 */
static int transact(int fd, u32 handle, u32 code, struct parcel *p,
		    struct parcel *reply, u32 *out_binder)
{
	static u8 wbuf[2048], rbuf[4096];
	/* The parcel lives in its own buffer: bytes placed after the transaction
	 * data in the write buffer are parsed by the driver as more commands. */
	u64 offs[8];
	struct binder_transaction_data td;
	struct binder_write_read bwr;
	u32 wlen = 0, i, cmd;
	u64 free_ptr;

	memcpy(offs, p->off, sizeof offs);
	memset(&td, 0, sizeof td);
	td.target.handle = handle;
	td.code = code;
	td.data_size = p->len;
	td.offsets_size = p->noff * 4;
	if (p->noff) {
		memcpy(wbuf + sizeof(u32) + sizeof(td), offs, p->noff * 4);
		td.data.ptr.offsets = (uintptr_t)(wbuf + sizeof(u32) + sizeof(td));
	}
	td.data.ptr.buffer = (uintptr_t)p->buf;
	cmd = BC_TRANSACTION;
	memcpy(wbuf, &cmd, 4);
	memcpy(wbuf + 4, &td, sizeof td);
	wlen = 4 + sizeof(td) + p->noff * 4;

	memset(&bwr, 0, sizeof bwr);
	bwr.write_size = wlen;
	bwr.write_buffer = (uintptr_t)wbuf;
	bwr.read_size = sizeof rbuf;
	bwr.read_buffer = (uintptr_t)rbuf;
	if (ioctl(fd, BINDER_WRITE_READ, &bwr) < 0) {
		perror("BINDER_WRITE_READ(write)");
		return -1;
	}

	*out_binder = 0;
	reply->len = 0;
	reply->noff = 0;
	for (i = 0; i < bwr.read_consumed; ) {
		memcpy(&cmd, rbuf + i, 4);
		i += 4;
		if (cmd == BR_TRANSACTION_COMPLETE) {
			memset(&bwr, 0, sizeof bwr);
			bwr.read_size = sizeof rbuf;
			bwr.read_buffer = (uintptr_t)rbuf;
			if (ioctl(fd, BINDER_WRITE_READ, &bwr) < 0) {
				perror("BINDER_WRITE_READ(read)");
				return -1;
			}
			i = 0;
			continue;
		}
		if (cmd == BR_REPLY) {
			struct binder_transaction_data *r =
				(struct binder_transaction_data *)(rbuf + i);
			u32 j;

			i += sizeof(*r);
			if (r->data_size > sizeof(reply->buf)) {
				printf("reply too big: %llu\n",
				       (unsigned long long)r->data_size);
				return -1;
			}
			memcpy(reply->buf, (void *)(uintptr_t)r->data.ptr.buffer,
			       r->data_size);
			reply->len = r->data_size;
			reply->noff = 0;
			for (j = 0; j < r->offsets_size / 4; j++) {
				u32 o;
				u64 b;

				memcpy(&o, (void *)(uintptr_t)r->data.ptr.offsets +
					      j * 4, 4);
				memcpy(&b, reply->buf + o + 8, 8);
				reply->off[j] = o;
				reply->noff++;
				(void)b;
			}
			free_ptr = r->data.ptr.buffer;
			{
				u8 fbuf[8];
				u32 fcmd = BC_FREE_BUFFER;
				struct binder_write_read f;

				memcpy(fbuf, &fcmd, 4);
				memcpy(fbuf + 4, &free_ptr, 4);
				memset(&f, 0, sizeof f);
				f.write_size = 8;
				f.write_buffer = (uintptr_t)fbuf;
				ioctl(fd, BINDER_WRITE_READ, &f);
			}
			if (reply->noff) {
				u32 type = *(u32 *)reply->buf;
				(void)type;
				*out_binder = reply->noff
					? (u32)*(u64 *)(reply->buf + reply->off[0] + 8)
					: 0;
			}
			return 0;
		}
		printf("unexpected read command 0x%x\n", cmd);
		break;
	}
	return -1;
}

/*
 * The IPC header position is not documented well enough to trust a guess, so
 * one run tries each pad and prints what the manager answered. A pad of N
 * means N zero words, then the VNDR magic, then the interface descriptor.
 */
int main(int argc, char **argv)
{
	const char *node = argc > 1 ? argv[1] : "/dev/binderfs/vndbinder";
	const char *iface = "android.os.IServiceManager";
	const char *name = "com.google.edgetpu.tachyon.IComputeService/default";
	struct parcel p, reply;
	u32 binder = 0, i, pad;
	int fd, rc;

	fd = open(node, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		perror(node);
		return 1;
	}

	for (pad = 0; pad < 1; pad++) {
		printf("== getService ==\n");
		memset(&p, 0, sizeof p);
		put32(&p, 0xffffffff);	/* kUnsetWorkSource */
		put32(&p, 0x564e4452);	/* kHeader, VNDR */
		putstr16(&p, iface);
		putstr16(&p, name);
		binder = 0;
		rc = transact(fd, 0, 1, &p, &reply, &binder);
		printf("getService: rc %d handle %u\n", rc, binder);
		if (rc == 0) {
			dump_parcel("reply", reply.buf, reply.len, reply.off, reply.noff);
			memset(&p, 0, sizeof p);
			put32(&p, 0xffffffff);
			put32(&p, 0x564e4452);
			putstr16(&p, "com.google.edgetpu.tachyon.IComputeService");
			put32(&p, 1);	/* privileged */
			for (i = 3; i < (u32)argc; i++)
				put32(&p, (u32)strtoul(argv[i], NULL, 0));
			rc = transact(fd, binder, 1, &p, &reply, &binder);
			printf("createSession: rc %d\n", rc);
			if (rc == 0)
				dump_parcel("session reply", reply.buf, reply.len,
					    reply.off, reply.noff);
		}
	}
	close(fd);
	return 0;
}
