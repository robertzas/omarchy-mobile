# Next cycle: force the firmware setup from the patched HAL

Goal unchanged: the Pixel 7 Pro's Edge TPU (`cheetah`, gs201) runs one
inference on mainline `janeiro`, then a 720p object-detection benchmark against
CPU and GPU, each row recorded in `device/cheetah/TPU-PLAN.md` with `uname -r`
and the exact log lines. A benchmark that was not run is reported as not run.

Read TPU-PLAN U55–U67 first. Slot B only; never load the A14 firmware; the TPU
powers up once per cold boot; a reboot clears a leaked IOMMU domain.

## Where it stands (U67)

The KCI lead is dead: every code-6 scratch variant (and code 9) answers 3, so 3
is a generic "setup not done" precondition, not the global-scratch check.

Cheetah's stock HAL is patched at file offset `0x14d9a48` from `mov x21, x2` to
`mov w21, #0x21` (bytes `35 04 80 52`), which forces the `SetupFirmware` call
its `tbz x21, #0x20` gate otherwise skips; the original is
`$R/vendor/lib64/libdarwinn_hal.so.bitset-orig`. The patched run has not been
evaluated: the first attempt oopsed on a leaked IOMMU domain, and the
fresh-boot attempt stopped at `[Darwinn] Unable to connect to Power HAL` before
the setup, inside the runner's 4 s window.

## Order of work

1. **Run the patched HAL as the first group on a clean boot.** Start the chain
   with the power HAL up (`vendor/bin/hw/android.hardware.power-service.pixel-
   libperfmgr`, which the runner starts; check it is alive), then run
   `HAL_ONLY=1 /root/tpu-tachyon-run` and give the HAL 20–30 s instead of 4.
   Watch `/tmp/tpu-tachyon.log` for `Sending firmware-setup VII command. type:`
   and `Firmware setup failed for commands[%d]`, and the firmware ring for
   `Setup is already done`. If the gate opens, run the delegate on
   `/vendor/etc/model.tflite` in the same boot.
2. **If the HAL still sends type 0 or fails, recover the type-1
   `CommandMessage` layout** from `libtachyon_core.patched.so`: the builder is
   inlined near the `0xa4d5c` log site (the type byte is at `[sp,#0xa0]`), the
   verifier at `0xb9c48` checks the cluster bitset (the string at `0x139f4`),
   and the class is
   `platforms::darwinn::tachyon::command::CommandMessageT`. Build it in
   `tools/edgetpu-run.c` and submit it on a mapped buffer.
3. **Fallback: build Google's `gxp` driver** for gs201 against the phone's
   kernel, blacklist `janeiro`, and let the tegu Tachyon service start the DSP
   actor that pushes the setup itself.

## Current facts

- Phone: up since the reboot, TPU powered once (`tpu-hold` 4109), cheetah's
  HAL patched (backup on the phone) and the HAL service still up (4186).
- The chroot root is `/usr/lib/omamobile-vendor/edgetpu/root` and must be mode
  755 for the uid-10000 client; the delegate runs as root.
- The OnePlus 8T re-takes `172.16.42.1` after every reconnect: disconnect
  `enp0s20f0u5` and set its profile `connection.autoconnect no` by UUID before
  every phone command. `OMAMOBILE_SSH_KEY=~/.ssh/id_ed25519`.
- CPU baseline (U27): XNNPACK 11.52 ms/frame at 1 thread, 3.98 ms at 4, 10
  detections/frame at threshold 0.4 on `mosaic720.mp4`. GPU and TPU rows are
  still missing.

## Definition of done

The setup is accepted, one inference produces detections on the TPU, and the
same 720p clip is benchmarked on TPU, CPU and GPU with the numbers recorded in
TPU-PLAN.md, each with `uname -r` and the exact log lines.
