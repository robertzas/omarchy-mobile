// SPDX-License-Identifier: MIT
// android-dba-serve: give the vendor Edge TPU DBA service a binder thread
// that actually serves its transactions.
//
// The service registers com.google.edgetpu.dba.IDevice/default and then blocks
// in libperfmgr's epoll loop, so its own thread never enters the binder pool.
// The kernel queues a client's createSession on the service's node forever
// (`tr 1` pending with no consumer, TPU-PLAN U284). This constructor starts one
// thread that waits for the process to finish initializing, then joins the
// pool; a delay is used because joining calls ProcessState::self(), and that
// must not pick the driver before the service does.
//
// Preload into the DBA service only (the chain prefixes it to DBA_PRELOAD).
typedef unsigned long size_t;

extern long write(int, const void *, size_t);
extern void *dlopen(const char *, int);
extern void *dlsym(void *, const char *);
extern int usleep(unsigned int);

#define RTLD_NOW 2
#define RTLD_DEFAULT ((void *)0)

static void mark(const char *s)
{
	size_t n = 0;

	while (s[n])
		n++;
	write(2, "DBASERVE ", 9);
	write(2, s, n);
	write(2, "\n", 1);
}

static void *worker(void *arg)
{
	void *join;

	(void)arg;
	usleep(2000000);
	join = dlsym(RTLD_DEFAULT, "ABinderProcess_joinThreadPool");
	if (!join) {
		void *h = dlopen("libbinder_ndk.so", RTLD_NOW);

		if (h)
			join = dlsym(h, "ABinderProcess_joinThreadPool");
	}
	if (!join) {
		mark("no ABinderProcess_joinThreadPool");
		return 0;
	}
	mark("joining the binder pool");
	((void (*)(void))join)();
	mark("pool returned");
	return 0;
}

__attribute__((constructor)) static void start(void)
{
	unsigned long tid = 0;
	int (*create)(unsigned long *, const void *, void *(*)(void *), void *) =
		(int (*)(unsigned long *, const void *, void *(*)(void *), void *))
		dlsym(RTLD_DEFAULT, "pthread_create");

	if (!create) {
		mark("no pthread_create");
		return;
	}
	if (create(&tid, 0, worker, 0))
		mark("pthread_create failed");
	else
		mark("spawned the serving thread");
}
