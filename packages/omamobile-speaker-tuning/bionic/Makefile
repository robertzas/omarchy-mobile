# SPDX-License-Identifier: MIT
# Builds omamobile-waves-host, the bionic (aarch64) helper that runs Waves'
# speaker tuning controller in the "waves" vendor chroot, on the computer
# (the phone has no bionic toolchain) into prebuilt/, which the package
# installs. prebuilt/ is not committed: run this before tools/repo-build.
#
#   make NDK=/opt/android-ndk          (Android NDK r23 or later; API 30)
#
# Nothing of Google's or Waves' is linked: the helper needs only bionic's
# libc and libdl, and dlopen()s the controller at run time.
# device/cheetah/AOC-TUNING-RESEARCH.md.

API    ?= 30
OUT    ?= prebuilt
CFLAGS ?= -O2
WARN   := -Wall -Wextra -Werror -Wformat=2 -Wshadow -Wstrict-prototypes
HOST   := $(OUT)/omamobile-waves-host

ifndef NDK
$(error set NDK=<android-ndk>)
endif
CC := $(NDK)/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android$(API)-clang

all: $(HOST)

# -rdynamic: the controller's liblog calls bind to the helper's own
# __android_log_* (stderr), see the source
$(HOST): omamobile-waves-host.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(WARN) -fPIE -pie -rdynamic -o $@ $< -ldl

clean:
	rm -f $(HOST)

.PHONY: all clean
