# SPDX-License-Identifier: MIT
# The OWL conformance container (docs/WIDGET-INTEROP-PLAN.md §7): Qt 6 and
# Quickshell from Arch, node, the Omarchy font, and the two upstream
# repositories at pinned commits. Their files stay in this image: nothing
# from them is copied into our tree. Rendering is offscreen (no compositor,
# no Wayland), so nothing here touches the desktop it runs on.
FROM archlinux:latest

ARG UID=1000
ARG GID=1000
ARG WIDGETS_REPO=https://github.com/SimonSchubert/omarchy-widgets.git
ARG WIDGETS_COMMIT=b63886b
ARG LAUNCHER_REPO=https://github.com/SimonSchubert/omalauncher.git
ARG LAUNCHER_COMMIT=d355bdb

RUN pacman -Syu --noconfirm --needed qt6-declarative qt6-svg qt6-imageformats quickshell nodejs git \
      ttf-jetbrains-mono-nerd noto-fonts-emoji imagemagick python fontconfig \
    && pacman -Scc --noconfirm

RUN git clone -q "$WIDGETS_REPO" /ref/omarchy-widgets && git -C /ref/omarchy-widgets checkout -q "$WIDGETS_COMMIT" \
    && git clone -q --filter=blob:none "$LAUNCHER_REPO" /ref/omalauncher && git -C /ref/omalauncher checkout -q "$LAUNCHER_COMMIT"

RUN (getent group $GID || groupadd -g $GID owl) && useradd -m -u $UID -g $GID -s /bin/bash owl
USER owl
ENV QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software TZ=Europe/Berlin LANG=C.UTF-8 \
    XDG_RUNTIME_DIR=/tmp/xdg QML_DISABLE_DISK_CACHE=1
WORKDIR /home/owl
