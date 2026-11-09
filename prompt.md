# Next: make the device owner come up, then re-test the delegate

Measured (U102): the chroot now has `/dev/janeiro`, `/dev/edgetpu`,
`/dev/edgetpu-soc` and `/dev/dma_heap/system`, so the status 13 was a missing
node, not permissions. With nodes present the vendor HAL dies with a SIGSEGV
in its setup path, the app service still never opens the device, and no
Tachyon session exists.

1. Run the app service alone under the runner's preloads as uid 1000 and read
   its own output: does it publish `com.google.edgetpu.IEdgeTpuAppService`,
   open `/dev/janeiro`, and stay up? Confirm with `ls -l /proc/<pid>/fd` and
   `dumpsys`/`svclookup-check`.
2. Get the HAL's SIGSEGV stack (CORES=1 leaves a core, or run it under gdb
   with the chroot sysroot) and fix the failing mapping; the fault address
   `0x72656b6e694c00` is ASCII-ish and looks like a string pointer, not a
   device address.
3. With a device owner and a live HAL, the delegate as uid 10000 should get a
   device fd instead of status 13; if it then reports "Setup is not done",
   the setup is the HAL's own path, and the Tachyon RegisterGraph capture from
   the previous prompt stays the fallback.
