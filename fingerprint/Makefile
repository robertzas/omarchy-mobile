# SPDX-License-Identifier: MIT
# Builds the fingerprint chroot's bionic (aarch64) programs on the computer:
#
#   out/omamobile-fp-shim.so   the preload shim (every Android process)
#   out/omamobile-fp-bridge    the HAL client that fprintd's driver talks to
#
#   make NDK=/opt/android-ndk CHROOT=...   (Android NDK r27 or later)
#   make CLANG=... BIONIC=... CHROOT=...   (an AOSP/LineageOS tree: its
#                                          prebuilt clang and bionic headers)
#
# CHROOT is tools/extract-fingerprint-vendor's output root
# (out/fingerprint-vendor/root): both programs link against its libc, and
# the bridge against its libbinder_ndk, so they match the phone exactly.
# Installed on the phone under /usr/lib/omamobile-fp/.

API      ?= 35
OUT      ?= out
CFLAGS   ?= -O2
WARN     := -Wall -Wextra -Werror
SHIM_SRC := shim/omamobile-fp-shim.c
BRIDGE_SRC := bridge/omamobile-fp-bridge.c

ifndef CHROOT
$(error set CHROOT=<extract-fingerprint-vendor output>/root)
endif
LIBC     := $(CHROOT)/apex/com.android.runtime/lib64/bionic/libc.so
LIBDL    := $(CHROOT)/apex/com.android.runtime/lib64/bionic/libdl.so
LIBBINDER_NDK := $(CHROOT)/system/lib64/libbinder_ndk.so

ifdef NDK
CC       := $(NDK)/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android$(API)-clang
else ifdef BIONIC
# BIONIC=<tree>/bionic/libc
CC       := $(CLANG) --target=aarch64-linux-android$(API) -nostdinc \
	    -isystem $(BIONIC)/include -isystem $(BIONIC)/kernel/uapi \
	    -isystem $(BIONIC)/kernel/uapi/asm-arm64 \
	    -isystem $(BIONIC)/kernel/android/uapi \
	    -isystem $(shell $(CLANG) -print-resource-dir)/include \
	    -fuse-ld=lld
else
$(error set NDK=<android-ndk> or CLANG=, BIONIC= and CHROOT=)
endif

all: $(OUT)/omamobile-fp-shim.so $(OUT)/omamobile-fp-bridge

$(OUT)/omamobile-fp-shim.so: $(SHIM_SRC)
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(WARN) -fPIC -fvisibility=hidden -shared -nostdlib \
		-Wl,--no-undefined -Wl,-soname,omamobile-fp-shim.so -o $@ $< \
		$(LIBC) $(LIBDL)

# No crtbegin: the bridge has its own _start (see its header).
$(OUT)/omamobile-fp-bridge: $(BRIDGE_SRC)
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(WARN) -fPIE -pie -nostdlib -fno-stack-protector \
		-Wl,--dynamic-linker=/system/bin/linker64 -Wl,-z,now \
		-Wl,-z,relro -Wl,--hash-style=gnu -Wl,--no-undefined \
		-Wl,--allow-shlib-undefined \
		-o $@ $< $(LIBBINDER_NDK) $(LIBC)

clean:
	rm -rf $(OUT)

.PHONY: all clean
