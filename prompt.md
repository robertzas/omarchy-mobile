# Next cycle: make the Edge TPU run one inference

The goal is unchanged: the Pixel 7 Pro's Edge TPU (`cheetah`, gs201, mainline
`janeiro` driver) must run one real inference, then a 720p object-detection
benchmark against CPU and GPU.

Read `device/cheetah/TPU-PLAN.md` first: U64 and U65 are the current state.
Slot B only; never load the A14 firmware; the TPU powers up once per cold boot
and a wedged PSM needs `systemctl poweroff` plus a human Power press.

## Where it stands

- The kernel driver is healthy: firmware load, KCI, `/dev/janeiro`, one clean
  power-up (`PSM0_STATUS=0x4b27091`).
- The tegu A17 Tachyon core runs on gs201 (ARMv9 patch, platform `gs201`), but
  its **GXP DSP half cannot start**: `gxp_main_actor.cc:286 Could not setup
  the main actor`, then `scoped_eventfd.cc:34 !fd.IsEmpty()`, then SIGSEGV.
  Stock needs the vendor `gxp` driver (`/dev/gxp`, `/sys/class/gxp`); mainline
  has none. The service therefore dies when the first client connects, before
  `createSession`.
- The firmware still refuses every VII command with
  `Setup is not done yet` (error 9). The setup is a `CommandMessage` the core
  would push lazily; the probe owns the command FMQ and can push it instead.

## Order of work

1. **Recover the setup message layout.** In
   `out/factory/tegu-cp21/vendor-libs/libtachyon_core.patched.so`
   (vaddr == file offset), the log site is at `0xa4d5c`
   (`Sending firmware-setup VII command. type: `, string at `0xcf73`); the
   type byte comes from `[sp,#0xa0]` and `PushFirmwareSetupCmdToVII failed`
   (string `0x8b7e`) is logged from the helper's return at `0xa4d84`. The
   push helper is at `0xa4dec`; the flatbuffer build is the block that fills
   the message before the log. Work out: the union type value, the field
   order, the `cluster_id_bitset`, and the `global scratches` entries
   (firmware strings: `No global scratches were provided in setup command.`,
   `Setup is not done yet received a command of type %d`). Cross-check with
   `libtachyon_dsp_core.so`'s `GxpTachyonServer` setup path and with
   `libedgetpu_tachyon.google.so`'s `SetupCommandFmq`/`SendCommandMessage`.
2. **Send it from the probe.** Add `build_setup_cmd()` to
   `tools/tpu-tachyon-client.c` (keep the existing `build_cmd` as the control
   case), send it first, then a normal command, and watch the response FMQ.
   Success is a response instead of `service 8`, and `dmesg` showing the
   firmware accepting setup.
3. **Then the delegate's direct path** (`bin/omamobile` chain, no Tachyon):
   `tools/tpu-tachyon-run` without `NO_DELEGATE`, checking that
   `Sync VII command failed: error_code=9` is gone and `/dev/janeiro` shows a
   VII element.
4. **One int8 inference** on `detect_edgetpu.tflite`, compared with CPU
   TFLite; record `uname -r`, latency and the exact log lines in TPU-PLAN.md.
5. **720p 10+-object benchmark** through `tools/bench-object-detection.py`
   against XNNPACK CPU and Mesa/panthor GPU, same video and threshold.

## Useful current facts

- Runner: `NO_DELEGATE=1 /root/tpu-tachyon-run` (skips the HAL, which leaks an
  IOMMU domain and makes the next group allocation oops). It starts the Power
  HAL first, then the vendor service, `tpu-hold`, the Tachyon service as
  `system`, the app service.
- Probe: `STYPE`, `CVER_MAJOR`, `CVER_MINOR`, `DELAY`, `ROUNDS`; build with
  the command in its header, copy to the chroot's `/vendor/bin/`.
- Chroot test state: `/dev/gxp -> janeiro`, `edgetpu-soc` 0660 root:system,
  `/vendor/firmware/gxp_callisto_fw_core{0,1,2}`.
- Host trap: the OnePlus 8T's `enp0s20f0u5` takes `172.16.42.1`; neutralize
  its profile (`ipv4.method disabled`, addresses cleared, autoconnect no) and
  keep the route on `enp0s20f0u4`.
- The probe must run as uid 10000 with the shim `LD_PRELOAD`; the Tachyon
  service must run as uid 1000.

## Definition of done

The firmware's setup is accepted, one inference produces detections on the
TPU, and the same 720p clip is benchmarked on TPU, CPU and GPU with the
numbers in TPU-PLAN.md. Do not report a benchmark that was not run.
