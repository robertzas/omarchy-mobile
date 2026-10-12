# SPDX-License-Identifier: MIT
# Builds the bionic (aarch64) pieces of the vendor chroot:
#   out/omandroid-fp-shim.so    the preload shim (source: ../fingerprint/shim)
#   out/stubs/*.so              stand-ins for libraries a profile's closure
#                               needs but the image doesn't give us
#
#   make NDK=/opt/android-ndk          (Android NDK r27 or later)
#   make CLANG=... BIONIC=... CHROOT=...
#                                      (an AOSP/LineageOS tree's prebuilt
#                                       clang and bionic headers, linked
#                                       against an extracted chroot's libc)
#
# Installed on the phone under /usr/lib/omandroid-vendor/.

API      ?= 35
OUT      ?= out
CFLAGS   ?= -O2
WARN     := -Wall -Wextra -Werror
SHIM_SRC := ../fingerprint/shim/omandroid-fp-shim.c
STUB     := $(OUT)/stubs/libcom.android.tethering.connectivity_native.so

ifdef NDK
CC       := $(NDK)/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android$(API)-clang
LIBS     := -ldl
STUBLIBS :=
else ifdef BIONIC
CC       := $(CLANG) --target=aarch64-linux-android$(API) -nostdinc \
	    -isystem $(BIONIC)/include -isystem $(BIONIC)/kernel/uapi \
	    -isystem $(BIONIC)/kernel/uapi/asm-arm64 \
	    -isystem $(BIONIC)/kernel/android/uapi \
	    -isystem $(shell $(CLANG) -print-resource-dir)/include
LIBS     := -nostdlib $(CHROOT)/apex/com.android.runtime/lib64/bionic/libc.so \
	    $(CHROOT)/apex/com.android.runtime/lib64/bionic/libdl.so
STUBLIBS := -nostdlib
else
$(error set NDK=<android-ndk> or CLANG=, BIONIC= and CHROOT=)
endif

all: $(OUT)/omandroid-fp-shim.so $(STUB)

$(OUT)/omandroid-fp-shim.so: $(SHIM_SRC)
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(WARN) -fPIC -fvisibility=hidden -shared \
		-Wl,--no-undefined -Wl,-soname,omandroid-fp-shim.so -o $@ $< $(LIBS)

$(STUB): stubs/connectivity_native_stub.c stubs/connectivity_native_stub.map
	@mkdir -p $(OUT)/stubs
	$(CC) $(CFLAGS) $(WARN) -fPIC -fvisibility=hidden -shared \
		-Wl,--version-script=stubs/connectivity_native_stub.map \
		-Wl,-soname,$(notdir $@) -o $@ $< $(STUBLIBS)

clean:
	rm -rf $(OUT)

.PHONY: all clean
