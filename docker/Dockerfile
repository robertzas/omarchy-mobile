# SPDX-License-Identifier: MIT
# Omandroid build environment: Ubuntu LTS with the LineageOS build packages.
FROM ubuntu:24.04

ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      bc bison build-essential ca-certificates ccache curl erofs-utils flex \
      g++-multilib gcc-multilib git git-lfs gnupg gperf imagemagick \
      protobuf-compiler python3-protobuf lib32readline-dev lib32z1-dev \
      libdw-dev libelf-dev libgnutls28-dev lz4 libsdl1.2-dev libssl-dev \
      libxml2 libxml2-utils lzop pngcrush python-is-python3 rsync schedtool \
      squashfs-tools xsltproc xxd zip unzip zlib1g-dev openssh-client \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo \
    && chmod 755 /usr/local/bin/repo

# Build as an unprivileged user matching the host user, so files stay owned by them.
RUN (id -u $UID >/dev/null 2>&1 && userdel -r $(id -nu $UID) || true) \
    && (getent group $GID || groupadd -g $GID builder) \
    && useradd -m -u $UID -g $GID -s /bin/bash builder

USER builder
WORKDIR /home/builder

ENV USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache CCACHE_DIR=/ccache
