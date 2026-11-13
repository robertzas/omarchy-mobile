#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Decode a captured Tachyon response as a generic FlatBuffer.

The gate-K reply is 88 bytes and starts with a valid root-table offset.  This
tool does not assume a schema: it prints each table's vtable, the present
fields, scalar words, and forward uoffsets that resolve to another table or a
zero-length object.  Use it to compare replies byte-for-byte without calling
an unknown field a length or a setup acknowledgement.

Examples:
  tools/tpu-response.py --hex '18 00 00 00 00 00 00 00 ...'
  tools/tpu-response.py --file logs/tpu/20261113-gatek-response.hex
"""
import argparse
import re
import struct
import sys


class BadFlatBuffer(ValueError):
    pass


def u16(b, o):
    if o < 0 or o + 2 > len(b):
        raise BadFlatBuffer(f"u16 out of bounds at {o}")
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    if o < 0 or o + 4 > len(b):
        raise BadFlatBuffer(f"u32 out of bounds at {o}")
    return struct.unpack_from("<I", b, o)[0]


def i32(b, o):
    if o < 0 or o + 4 > len(b):
        raise BadFlatBuffer(f"i32 out of bounds at {o}")
    return struct.unpack_from("<i", b, o)[0]


def u64(b, o):
    if o < 0 or o + 8 > len(b):
        raise BadFlatBuffer(f"u64 out of bounds at {o}")
    return struct.unpack_from("<Q", b, o)[0]


def vtable(b, table):
    """Return (vtable offset, vtable size, table size) or None."""
    try:
        soff = i32(b, table)
    except BadFlatBuffer:
        return None
    vt = table - soff
    if vt < 0 or vt + 4 > len(b):
        return None
    vt_size = u16(b, vt)
    table_size = u16(b, vt + 2)
    if vt_size < 4 or vt_size % 2 or vt_size > len(b) - vt:
        return None
    if table_size < 4 or table_size > len(b) - table:
        return None
    return vt, vt_size, table_size


def is_table(b, at):
    return vtable(b, at) is not None


def zero_target(b, at):
    """A uoffset to four zero bytes: a zero-length vector/string, not a table."""
    return at >= 0 and at + 4 <= len(b) and b[at:at + 4] == b"\0\0\0\0"


def length_prefixed(b, at):
    """Return N for a length-prefixed string/vector at `at`, else None."""
    if at < 0 or at + 4 > len(b):
        return None
    n = u32(b, at)
    if n > len(b) - at - 4:
        return None
    return n


def describe(b, table, label, depth=0):
    """Print one table and its nested tables, up to two levels."""
    vt = vtable(b, table)
    if not vt:
        raise BadFlatBuffer(f"{label} @ {table}: no valid vtable")

    vt_off, vt_size, table_size = vt
    nfields = (vt_size - 4) // 2
    print(f"{'  ' * depth}{label} @ {table}: vtable {vt_off}, "
          f"table {table_size} B, {nfields} slots")
    for i in range(nfields):
        off = u16(b, vt_off + 4 + 2 * i)
        if not off:
            print(f"{'  ' * depth}  field {i}: absent")
            continue
        at = table + off
        if at + 4 > len(b):
            print(f"{'  ' * depth}  field {i}: offset {off} out of bounds")
            continue
        raw8 = b[at:at + 8]
        raw_hex = " ".join(f"{x:02x}" for x in raw8)
        # A uoffset points forward to another table.  Check the target's
        # vtable; this is what separates a nested table from a scalar.
        target = at + u32(b, at)
        # A FlatBuffer table/uoffset is 4-byte aligned.  Without this check a
        # scalar 1 followed by zeroes looks like a pointer to an empty table.
        aligned = target > at and target % 4 == 0
        if depth < 2 and aligned and is_table(b, target):
            print(f"{'  ' * depth}  field {i}: @ {at} uoffset -> {target} "
                  f"(raw {raw_hex})")
            describe(b, target, f"field {i}", depth + 1)
        elif depth < 2 and aligned and zero_target(b, target):
            print(f"{'  ' * depth}  field {i}: @ {at} uoffset -> {target} "
                  f"zero-length target (u32 0; empty vector/string) "
                  f"(raw {raw_hex})")
        elif depth < 2 and aligned and length_prefixed(b, target) is not None:
            n = length_prefixed(b, target)
            print(f"{'  ' * depth}  field {i}: @ {at} uoffset -> {target} "
                  f"length-prefixed target ({n} B; string/vector) "
                  f"(raw {raw_hex})")
            body = b[target + 4:target + 4 + n].rstrip(b"\0")
            if body and all(32 <= x < 127 or x in (9, 10, 13) for x in body):
                print(f"{'  ' * depth}    text: {body[:200].decode('ascii')!r}")
        else:
            print(f"{'  ' * depth}  field {i}: @ {at} scalar byte "
                  f"0x{b[at]:02x} raw {raw_hex}")
            if at % 8 == 0 and at + 8 <= len(b):
                print(f"{'  ' * depth}    u64 0x{u64(b, at):016x}")
            elif at % 4 == 0 and at + 4 <= len(b):
                print(f"{'  ' * depth}    u32 0x{u32(b, at):08x}")


def parse_hex(text):
    found = re.findall(r"(?<![0-9a-fA-F])0x([0-9a-fA-F]{1,2})(?![0-9a-fA-F])",
                       text)
    if not found:
        # Also accept a bare byte list, e.g. "18 00 0e ...".
        found = re.findall(r"(?<![0-9a-fA-F])([0-9a-fA-F]{2})(?![0-9a-fA-F])",
                           text)
    return bytes(int(x, 16) for x in found)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--hex", help="hex bytes, with or without 0x prefixes")
    src.add_argument("--file", help="file containing hex bytes or a log line")
    ap.add_argument("--width", type=int, default=0,
                    help="only keep the first N bytes (the captured response size)")
    args = ap.parse_args()

    text = args.hex if args.hex is not None else open(args.file, encoding="utf-8").read()
    data = parse_hex(text)
    if args.width:
        data = data[:args.width]
    if len(data) < 8:
        sys.exit(f"need at least 8 bytes, got {len(data)}")

    root = u32(data, 0)
    print(f"payload {len(data)} B; root offset {root} -> table {root}")
    print("bytes:", " ".join(f"{x:02x}" for x in data))
    try:
        describe(data, root, "root")
    except BadFlatBuffer as exc:
        sys.exit(f"not a FlatBuffer: {exc}")

    print("\nnote: field names are unknown; offsets and values are exact.")


if __name__ == "__main__":
    main()
