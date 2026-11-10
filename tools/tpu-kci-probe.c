// SPDX-License-Identifier: MIT
// tpu-kci-probe: send the raw KCI codes the driver's command set skips
// (6, 15..18, 20) and print each ioctl's return. Development only: one TPU
// power-up per cold boot, and the firmware must already be running.
#include <stdint.h>

typedef uint32_t u32;

extern long write(int, const void *, unsigned long);
extern int open(const char *, int, ...);
extern int ioctl(int, unsigned long, ...);
extern void __libc_init(void *, void *, int (*)(int, char **), void *);

struct structors_array {
  void (**preinit)(void);
  unsigned long preinit_n;
  void (**init)(void);
  unsigned long init_n;
  void (**fini)(void);
  unsigned long fini_n;
};
struct structors_array structors;

int main(int argc, char **argv);

__attribute__((naked)) void _start(void) {
  __asm__ volatile(
      "mov x0, sp\n"
      "mov x1, xzr\n"
      "adrp x2, main\n"
      "add x2, x2, :lo12:main\n"
      "adrp x3, structors\n"
      "add x3, x3, :lo12:structors\n"
      "bl __libc_init\n");
}

static void put(const char *s) {
  unsigned long n = 0;
  while (s[n]) n++;
  write(1, s, n);
}

static void putdec(long v) {
  char b[24];
  int i = 0;
  if (v < 0) { put("-"); v = -v; }
  do { b[i++] = '0' + (v % 10); v /= 10; } while (v);
  while (i--) write(1, &b[i], 1);
}

#define IOC_WRITE 1
#define KCI_SEND_V(dir, type, nr, size) \
  (((dir) << 30) | ((size) << 16) | ((type) << 8) | (nr))

int main(int argc, char **argv) {
  (void)argc; (void)argv;
  static const int codes[] = {6, 15, 16, 17, 18, 20};
  u32 spec;
  int i, fd = open("/dev/janeiro", 2);

  put("fd="); putdec(fd); put("\n");
  if (fd < 0) return 1;
  for (i = 0; i < (int)(sizeof(codes) / sizeof(codes[0])); i++) {
    spec = (u32)codes[i] | (1u << 8); /* variant 1: {u64 addr, u32 size, u32 pad} */
    int r = ioctl(fd, KCI_SEND_V(IOC_WRITE, 0xED, 34, 4), &spec);
    put("code "); putdec(codes[i]); put(" -> "); putdec(r); put("\n");
  }
  return 0;
}
