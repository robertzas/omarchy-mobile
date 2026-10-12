# SPDX-License-Identifier: MIT
# Builds the fingerprint chroot's preload shim for bionic (aarch64).
#
#   make NDK=/opt/android-ndk          (Android NDK r27 or later)
#   make CLANG=... BIONIC=...          (or an AOSP/LineageOS tree: its
#                                       prebuilt clang and bionic headers,
#                                       linked against the extracted libc)
#
# Output: out/omandroid-fp-shim.so, installed on the phone as
# /usr/lib/omandroid-fp/omandroid-fp-shim.so.

API      ?= 35
OUT      ?= out
CFLAGS   ?= -O2
WARN     := -Wall -Wextra -Werror
SRC      := shim/omandroid-fp-shim.c

ifdef NDK
CC       := $(NDK)/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android$(API)-clang
LIBS     := -ldl
else ifdef BIONIC
# BIONIC=<tree>/bionic/libc, CHROOT=<extract-fingerprint-vendor output>/root
CC       := $(CLANG) --target=aarch64-linux-android$(API) -nostdinc \
	    -isystem $(BIONIC)/include -isystem $(BIONIC)/kernel/uapi \
	    -isystem $(BIONIC)/kernel/uapi/asm-arm64 \
	    -isystem $(BIONIC)/kernel/android/uapi \
	    -isystem $(shell $(CLANG) -print-resource-dir)/include
LIBS     := -nostdlib $(CHROOT)/apex/com.android.runtime/lib64/bionic/libc.so \
	    $(CHROOT)/apex/com.android.runtime/lib64/bionic/libdl.so
else
$(error set NDK=<android-ndk> or CLANG=, BIONIC= and CHROOT=)
endif

$(OUT)/omandroid-fp-shim.so: $(SRC)
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(WARN) -fPIC -fvisibility=hidden -shared \
		-Wl,--no-undefined -Wl,-soname,omandroid-fp-shim.so -o $@ $< $(LIBS)

clean:
	rm -rf $(OUT)

.PHONY: clean
