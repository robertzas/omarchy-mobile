# TPU bring-up: next iteration (2026-11-09, after U152)

Read `device/cheetah/TPU-PLAN.md` U150-U152 and `AGENTS.md` first. Phone:
up, Tachyon service alive; the boot's one TPU power-up is spent, so reboot
before a client run (`reboot-to`, slot B, under the grant), then
`NO_DELEGATE=1 TPU_VLOG=5 /root/tpu-tachyon-run`.

**State.** `RegisterGraph` passes the core's dependency check with
`UORDER=MDMK` plus a gdb patch at `core+0x5968c` (`set
{unsigned long}($x21+8)=2; set $x8=$x21+8`), and the virtual device reaches
`PENDING_FIRMWARE_SETUP`. The core wakes the firmware and sends
`Sending firmware-setup VII command. type: 1 seq: 0`, then the firmware
answers `Setup is not done yet received a command of type 0.` The element
is the legacy code-0 payload (fields 48/5/6) with no global scratches. The
stock delegate through the Tachyon client path fails at the same setup
three times (`create device status: 13`) before sending any command.

1. **Test the vendor service as the setup producer.** On a cold boot start
   servicemanager, the Power HAL, the vendor service and the app service,
   but no Tachyon session and no client; read `dmesg` for a `vii-payload`
   before the first `OPEN_DEVICE`/session. If the vendor service sends a
   setup, the firmware is ready and the ring client can skip its own setup.
2. **If it does not, build the type-1 setup.** The firmware wants the
   cluster bitset and the global scratch list. Recover the message layout
   from the cheetah A17 firmware's setup handler (32-bit ARM, strings at
   `0xefbdc`/`0xefd8c`/`0xefddc`/`0xefe18`) or from a userspace that
   produces it, then submit it as the setup element and read the answer.
3. **Then the pipeline.** CreateExecution (9), BindInputBuffers (12),
   BindOutputBuffers (13), Invoke (11) on the SSD 300x300 int8 model; run
   60 frames of `out/bench/mosaic12.mp4` through
   `tools/bench-object-detection.py`; fill the TPU row in U118 (CPU 4t
   4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3 fps, both 10.0
   detections/frame), record the result with the date and `uname -r`,
   replace this prompt, and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the
commit.
