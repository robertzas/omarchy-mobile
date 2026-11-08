# Next cycle: the type-1 setup payload

Goal: the Pixel 7 Pro's Edge TPU (`cheetah`, gs201) runs one inference on
mainline `janeiro`, then a 720p object-detection benchmark against CPU and GPU.

Read `device/cheetah/TPU-PLAN.md` U55–U66 first. Slot B only; never load the
A14 firmware; the TPU powers up once per cold boot (a second power-up wedges
the PSM, and only `systemctl poweroff` plus a human Power press clears it).

## Where it stands (U66)

Everything up to the firmware's one-time setup is working: firmware load, KCI,
`/dev/janeiro`, MMU, a clean power-up, and the vendor services under binder.

Every producer of the setup has now been eliminated with evidence:

- **cheetah's HAL** (A14/A17) sends the legacy command (`type 0`) and the A17
  firmware answers `Setup is not done yet received a command of type 0`.
- **tegu's HAL** (extracted to `out/tegu-hal/`) is the same legacy producer
  (`Firmware setup failed for commands[%d]` in its 57 MB library) and dies
  with `SIGILL, ILL_ILLOPC` before it creates a group on our CPU.
- **tegu's Tachyon core** is real and authorizes sessions, but its DSP actor
  needs stock's `gxp` driver (`/dev/gxp`, `/sys/class/gxp`) and dies at
  `gxp_main_actor.cc:286` before it pushes the setup.

The firmware wants a **type-1 setup command carrying `global scratches`**;
the core's hint path prints the type from a byte the code sets to 1. That
payload is the missing piece.

## Order of work

1. **Recover the type-1 payload from the tegu core**
   (`libtachyon_core.patched.so`, vaddr == file offset). The push failures
   log at `0x7531c` and `0xd36e0`; the setup command is built before the push
   and `0xd35c8` mmaps a firmware-scratch region in 24-byte entries from an
   fd (prot 3, offset `0x1a00000`). Find the builder, decode the flatbuffer
   fields (union type, `global_scratches` vector, `cluster_id_bitset`) and
   the scratch allocation it expects.
2. **Send it directly through the driver** on a cold boot, from
   `tools/edgetpu-run.c` (which already creates a group and submits VII
   elements) or the tachyon client: map the scratches, build the type-1
   message, submit, and read the response. Success is no `error_code=9` and
   `Setup is already done` on a second setup attempt; then run one int8
   model.
3. **Fallback: build Google's `gxp` driver** for gs201 against the phone's
   kernel, blacklist `janeiro`, and let tegu's Tachyon service start the DSP
   actor, which sends the setup itself. The module tree is the one under
   `~/omamobile-kernel/edgetpu-janeiro`; the `gxp` driver is in Google's gs201
   module source, not in that checkout.
4. Then one int8 inference on `detect_edgetpu.tflite`, then the 720p 10+
   object benchmark through `tools/bench-object-detection.py`.

## Current facts

- Phone: up 2200+ s, `tpu-hold` (pid 4054) holds the boot's one power-up,
  services down, cheetah's HAL and `libdarwinn_hal.so` restored (tegu's copies
  are in `out/tegu-hal/`; `.cheetah` backups were consumed by the restore).
- `tools/tpu-tachyon-run` has `HAL_ONLY=1` (stops after the HAL), `NO_DELEGATE=1`
  (skips the HAL, keeps the chain for clients) and `CORES=1`.
- Host SSH: export `OMAMOBILE_SSH_KEY=~/.ssh/id_ed25519`; bind with
  `ssh -B enp0s20f0u4` because the OnePlus's DHCP keeps stealing
  `172.16.42.1`. `tools/phone-ssh` does not pass `-B`.
- CPU baseline measured (U27): XNNPACK 11.52 ms/frame at 1 thread, 3.98 ms at
  4, 10 detections/frame at threshold 0.4 on `mosaic720.mp4`. GPU and TPU
  rows are missing; do not report them until measured.

## Definition of done

The setup is accepted, one inference produces detections on the TPU, and the
same 720p clip is benchmarked on TPU, CPU and GPU with the numbers recorded in
TPU-PLAN.md, each with `uname -r` and the exact log lines. A benchmark that
was not run is reported as not run.
