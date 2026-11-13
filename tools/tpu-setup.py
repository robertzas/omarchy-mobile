#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""tpu-setup: build and decode the Edge TPU firmware-setup command.

The A17 HAL's captured setup command (TPU-PLAN U262, out/tpu/setup-hal-128.bin)
is a 128-byte FlatBuffer whose schema differs from the 13-slot table the earlier
U162 field map described:

  root table at 20, vtable at 10 (3 fields, table size 18)
    field 0: uoffset -> zero-length vector at 76 (the command seq vector)
    field 1: u8 at 27  = 5 (the union type)
    field 2: uoffset -> table at 44
      table at 44, vtable at 38 (1 field, table size 8)
        field 0: uoffset -> vector at 52: length 1, then 16-byte
                 {u64 address, u64 size} entries

The captured entry is {0xffe80000, 0x80000}: a 512 KiB allocation at the top of
the TPU's 32-bit address space. That is the only allocation the stock HAL sends
in this command, and it is the payload this tool can rebuild byte for byte.

`decode` is read-only and works on any command that follows this shape;
`build` writes exactly the captured 128-byte layout so a replay can vary only
the allocation, never the schema.

Examples:
  tools/tpu-setup.py decode out/tpu/setup-hal-128.bin
  tools/tpu-setup.py build --addr 0xffe80000 --size 0x80000 -o setup.bin
"""

import argparse
import hashlib
import struct
import sys


class BadCommand(ValueError):
    pass


def u16(b, o):
    if o < 0 or o + 2 > len(b):
        raise BadCommand(f"u16 out of range at {o}")
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    if o < 0 or o + 4 > len(b):
        raise BadCommand(f"u32 out of range at {o}")
    return struct.unpack_from("<I", b, o)[0]


def u64(b, o):
    if o < 0 or o + 8 > len(b):
        raise BadCommand(f"u64 out of range at {o}")
    return struct.unpack_from("<Q", b, o)[0]


def table(b, at):
    """Return (vtable, vtable_size, table_size, field offsets) or raise."""
    vt = at - struct.unpack_from("<i", b, at)[0]
    if vt < 0 or vt + 4 > len(b):
        raise BadCommand(f"table at {at} points outside the buffer")
    vs = u16(b, vt)
    ts = u16(b, vt + 2)
    if vs < 4 or vs % 2 or vs > 64 or ts < 4 or at + ts > len(b):
        raise BadCommand(f"bad vtable at {vt}: size {vs}, table {ts}")
    fields = [u16(b, vt + 4 + 2 * i) for i in range((vs - 4) // 2)]
    return vt, vs, ts, [f if f else None for f in fields]


def decode(path):
    b = open(path, "rb").read()
    root = u32(b, 0)
    vt, vs, ts, fields = table(b, root)
    print(f"file {path} ({len(b)} bytes)")
    print(f"root table {root}, vtable {vt}, vtable size {vs}, table size {ts}")
    for i, off in enumerate(fields):
        if off is None:
            print(f"  field {i}: absent")
            continue
        at = root + off
        raw = b[at:at + 16].hex()
        print(f"  field {i}: offset {off} @ {at}: {raw}")
        if i == 1:
            print(f"    union type: {b[at]}")
        if off + 4 <= ts:
            target = at + u32(b, at)
            if 0 < u32(b, at) < len(b) - at:
                inner = b[target:target + 8].hex()
                print(f"    uoffset -> {target}: {inner}")
                try:
                    ivt, ivs, its, ifields = table(b, target)
                except BadCommand:
                    continue
                print(f"    table {target}, vtable {ivt}, "
                      f"size {ivs}, table size {its}")
                for j, ioff in enumerate(ifields):
                    if ioff is None:
                        print(f"      field {j}: absent")
                        continue
                    iat = target + ioff
                    print(f"      field {j}: offset {ioff} @ {iat}: "
                          f"{b[iat:iat + 16].hex()}")
                    vec = iat + u32(b, iat)
                    if not (0 < u32(b, iat) < len(b) - iat):
                        continue
                    n = u32(b, vec)
                    print(f"        uoffset -> {vec}: vector length {n}")
                    for k in range(min(n, 8)):
                        e = vec + 4 + 16 * k
                        if e + 16 > len(b):
                            print(f"        entry {k}: truncated")
                            break
                        print(f"        entry {k}: address {u64(b, e):#x} "
                              f"size {u64(b, e + 8):#x}")


def build(addr, size, utype, out):
    b = bytearray(128)

    def w16(o, v):
        struct.pack_into("<H", b, o, v)

    def w32(o, v):
        struct.pack_into("<I", b, o, v)

    def w64(o, v):
        struct.pack_into("<Q", b, o, v)

    w32(0, 20)                 # root uoffset
    w16(10, 10)                # vtable size
    w16(12, 18)                # table size
    w16(14, 8)                 # field 0 offset
    w16(16, 7)                 # field 1 offset
    w16(18, 12)                # field 2 offset
    w32(20, 10)                # table soffset -> vtable at 10
    b[27] = utype & 0xFF       # union type
    w32(28, 76 - 28)           # command seq vector (zero length) at 76
    w32(32, 44 - 32)           # union table at 44
    w16(38, 6)                 # nested vtable size
    w16(40, 8)                 # nested table size
    w16(42, 4)                 # nested field 0 offset
    w32(44, 6)                 # nested table soffset -> vtable at 38
    w32(48, 52 - 48)           # allocation vector at 52
    w32(52, 1)                 # one entry
    w64(56, addr)
    w64(64, size)
    open(out, "wb").write(b)
    print(f"wrote {out} ({len(b)} bytes, sha256 "
          f"{hashlib.sha256(b).hexdigest()})")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("decode", help="decode a setup command")
    d.add_argument("file")
    b = sub.add_parser("build", help="write the captured 128-byte layout")
    b.add_argument("--addr", type=lambda s: int(s, 0), default=0xFFE80000)
    b.add_argument("--size", type=lambda s: int(s, 0), default=0x80000)
    b.add_argument("--type", type=lambda s: int(s, 0), default=5)
    b.add_argument("-o", "--out", default="setup.bin")
    args = ap.parse_args()
    try:
        if args.cmd == "decode":
            decode(args.file)
        else:
            build(args.addr, args.size, args.type, args.out)
    except (BadCommand, OSError) as e:
        print(f"tpu-setup: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
