#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""tpu-setup-payload: build the Edge TPU firmware's type-1 setup command.

The firmware refuses every VII command until its one-time setup has run
(TPU-PLAN U151/U163). The Tachyon core sends a legacy setup the firmware reads
as type 0, and the A17 HAL's builder is the only stock producer of the type-1
command; its serializer (TPU-PLAN U162) builds a 13-slot table whose field 2 is
a vector of 16-byte entries and field 3 a vector of 64-byte entries.

This writes that flatbuffer as a raw payload, so tools/edgetpu-run can submit it
through the driver (`edgetpu-run mapped 0 FILE`) and the firmware's own log line
in dmesg says what it still wants: "No global scratches were provided in setup
command.", "Global scratch is too small...", or the pre-setup gate.

Layout, matching the client's build_setup(): root Command table at 36 (vtable
at 24) with {seq u64, privileged u8, union type u8 = 1, union uoffset}; the
setup table at 96 (vtable at 56) with 13 slots; the scratch vector at 160 and
the resource vector at 224.
"""
import argparse
import struct


def ranges(text):
    out = []
    for item in text.split(","):
        if not item:
            continue
        addr, size = item.split(":")
        out.append((int(addr, 0), int(size, 0)))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--scratch", default="0x10000000:0x1000000,"
                    "0x11000000:0x10000,0x11010000:0x10000",
                    help="comma-separated address:size scratch ranges")
    ap.add_argument("--resources", default="", help="address:size pairs")
    ap.add_argument("--cluster", type=lambda s: int(s, 0), default=0,
                    help="value for the 4-byte slot field 0 (cluster bitset?)")
    ap.add_argument("--seq", type=lambda s: int(s, 0), default=0)
    ap.add_argument("--type", type=lambda s: int(s, 0), default=1,
                    help="union type byte (1 = setup)")
    ap.add_argument("--out", default="setup-t1.bin")
    args = ap.parse_args()

    scr = ranges(args.scratch)
    res = ranges(args.resources)
    b = bytearray(512)

    def u16(off, v):
        struct.pack_into("<H", b, off, v)

    def u32(off, v):
        struct.pack_into("<I", b, off, v)

    def u64(off, v):
        struct.pack_into("<Q", b, off, v)

    # Root Command table at 36, vtable at 24: seq, privileged, union type, union.
    u32(0, 36)
    u16(24, 0x0C)
    u16(26, 0x18)
    u16(28, 4)
    u16(30, 12)
    u16(32, 13)
    u16(34, 16)
    u32(36, 12)                 # soffset back to vtable 24
    u64(40, args.seq)
    b[48] = 1                   # privileged
    b[49] = args.type & 0xFF    # union type
    u32(52, 96 - 52)            # union table at 96

    # Setup table at 96, vtable at 56: 13 slots, field 2 and field 3 vectors.
    u16(56, 4 + 2 * 13)
    u16(58, 24)
    u16(64, 16)                 # field 2 offset
    u16(66, 20)                 # field 3 offset
    u32(96, 96 - 56)
    u32(96 + 16, 160 - (96 + 16))
    u32(96 + 20, 224 - (96 + 20))
    if args.cluster:
        # Field 0 is a 4-byte slot (TPU-PLAN U162: fields 0/1/10 are 4-byte).
        u16(62, 8)              # field 0 offset
        u32(96 + 8, args.cluster)

    # Field 2: the 16-byte entries, count first, data 8-aligned.
    u32(160, len(scr))
    for i, (addr, size) in enumerate(scr):
        u64(168 + 16 * i, addr)
        u64(168 + 16 * i + 8, size)

    # Field 3: 64-byte entries (the HAL sends one per resource).
    u32(224, len(res))
    for i, (addr, size) in enumerate(res):
        base = 232 + 64 * i
        u64(base, addr)
        u64(base + 8, size)

    with open(args.out, "wb") as f:
        f.write(bytes(b[:256]))
    print(f"{args.out}: {len(scr)} scratch ranges, {len(res)} resources, "
          f"type {args.type}")
    for addr, size in scr:
        print(f"  scratch {addr:#x} + {size:#x}")
    for addr, size in res:
        print(f"  resource {addr:#x} + {size:#x}")


if __name__ == "__main__":
    main()
