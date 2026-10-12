# omandroid-device-cheetah

Omandroid's system support for the Google Pixel 7 Pro (codename cheetah, Tensor G2 / gs201). It sits beside Omarchy's own packages, the way `omarchy-mac` adds Apple Silicon support.

| Path | Installs to | What it does |
| --- | --- | --- |
| `bin/omandroid-boot-success` + `vendor/systemd/system/omandroid-boot-success.service` | `/usr/bin`, `/usr/lib/systemd/system` (enabled by a vendor wants link) | Marks the booted A/B slot successful after each healthy boot, as Android's boot-control service does |
| `bin/omandroid-wifi-start` + `vendor/systemd/system/omandroid-wifi.service` | `/usr/bin`, `/usr/lib/systemd/system` (**not enabled**: no wants link until gate W4 passes) | Brings up Wi-Fi behind its DMA window at boot (System MMU first, then PCIe, then brcmfmac), skipping it on the next boot if a bring-up never finished |
| `src/omandroid-bootctl.c` | `/usr/bin/omandroid-bootctl` | Reads and updates the slot flags in `devinfo`. Ported from Google's Apache-2.0 Pixel boot-control code; only ever changes bytes 0x30-0x37, verified |
| `src/reboot-to.c` | `/usr/bin/reboot-to` | Reboot with a reason the bootloader understands |
| `bin/omandroid-setup-system` | `/usr/bin` | System setup: UTF-8 locale, timezone, NTP (Omarchy lifecycle `setup-system`) |
| `vendor/udev/rules.d/10-omandroid-storage.rules` | `/usr/lib/udev/rules.d` | Continues the initramfs storage guard: Android partitions stay hidden and the whole-disk node unusable |
| `vendor/systemd/network/20-usb-gadget.network` | `/usr/lib/systemd/network` | USB networking to a host (172.16.42.1) |
| `vendor/NetworkManager/conf.d/10-omandroid-usb.conf` | `/usr/lib/NetworkManager/conf.d` | Keeps NetworkManager off the USB link |
| `vendor/systemd/logind.conf.d/10-omandroid-power-key.conf` | `/usr/lib/systemd/logind.conf.d` | A short power press opens the system menu instead of powering off |

`./build [DIR]` compiles the C tools, `./install DESTDIR [DIR]` stages everything and enables nothing, and `test/all` runs the package tests.

Licences: MIT, except `omandroid-bootctl`, which is Apache-2.0 and keeps Google's notice.
