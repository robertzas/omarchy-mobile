#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Inspect Edge TPU graph containers without assuming their schema.

The live Tachyon core accepts DGC0 or DWS0 at buffer+4 (U170), but the
compiler also emits DWN1 and the stock executable cache carries DGC0, DGD0 and
DWS0 sections.  This tool prints the measured layout so the next session can
compare containers instead of guessing file identifiers.

Examples:
  tools/tpu-graph.py inspect out/bench/graph-dgc0-fb.bin
  tools/tpu-graph.py inspect out/edgetpu-runtime/graph.bin --offset 8
  tools/tpu-graph.py scan out/bench/graph-cache.bin
  tools/tpu-graph.py compare out/bench/graph-dgc0.bin out/bench/graph-dgc0-fb.bin
"""
import argparse
import hashlib
import json
import struct
import sys

MARKERS = (b"DGC0", b"DWS0", b"DGD0", b"DWN1", b"TCHN", b"DIVE")


def u16(b, o):
    if o < 0 or o + 2 > len(b):
        raise ValueError(f"u16 out of bounds at {o}")
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    if o < 0 or o + 4 > len(b):
        raise ValueError(f"u32 out of bounds at {o}")
    return struct.unpack_from("<I", b, o)[0]


def i32(b, o):
    if o < 0 or o + 4 > len(b):
        raise ValueError(f"i32 out of bounds at {o}")
    return struct.unpack_from("<i", b, o)[0]


def u64(b, o):
    if o < 0 or o + 8 > len(b):
        raise ValueError(f"u64 out of bounds at {o}")
    return struct.unpack_from("<Q", b, o)[0]


def vtable(b, table):
    """Return (vtable offset, vtable size, table size) or None."""
    try:
        soff = i32(b, table)
    except ValueError:
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
    return 0 <= at < len(b) and vtable(b, at) is not None


def printable(raw):
    if not raw:
        return ""
    if all(32 <= x < 127 or x in (9, 10, 13) for x in raw):
        return raw.decode("ascii", "replace")
    return ""


def ident_at(b, offset):
    """Return (identifier string, identifier offset, root uoffset or None).

    A normal flatbuffer has its root uoffset at the base and its 4-byte file
    identifier at base+4.  The stripped DGC0 file starts with the identifier
    itself and has no root word; report that shape rather than reading the
    identifier as a huge root offset.
    """
    if offset < 0 or offset > len(b):
        raise ValueError(f"offset {offset} is outside the file")
    if offset + 4 <= len(b) and b[offset:offset + 4] in MARKERS:
        return b[offset:offset + 4].decode("ascii"), offset, None
    if offset + 8 <= len(b) and b[offset + 4:offset + 8] in MARKERS:
        return b[offset + 4:offset + 8].decode("ascii"), offset + 4, u32(b, offset)
    return "", offset + 4, u32(b, offset) if offset + 4 <= len(b) else None


def describe_table(b, table, depth, max_depth):
    vt = vtable(b, table)
    if not vt:
        return {"table": table, "error": "no valid vtable"}
    vt_off, vt_size, table_size = vt
    nfields = (vt_size - 4) // 2
    out = {
        "table": table,
        "vtable": vt_off,
        "vtable_size": vt_size,
        "table_size": table_size,
        "fields": [],
    }
    for i in range(nfields):
        off = u16(b, vt_off + 4 + 2 * i)
        field = {"index": i, "present": bool(off)}
        if not off:
            out["fields"].append(field)
            continue
        at = table + off
        field["offset_in_table"] = off
        field["at"] = at
        if at + 4 > len(b):
            field["error"] = "out of bounds"
            out["fields"].append(field)
            continue
        raw8 = b[at:at + 8]
        field["raw_hex"] = " ".join(f"{x:02x}" for x in raw8)
        field["u32"] = u32(b, at)
        if at + 8 <= len(b):
            field["u64"] = u64(b, at)
        target = at + field["u32"]
        field["uoffset_target"] = target if target <= len(b) else None
        text = printable(raw8)
        if text:
            field["ascii"] = text
        if (depth < max_depth and target > at and target % 4 == 0
                and is_table(b, target)):
            field["nested_table"] = describe_table(b, target, depth + 1,
                                                   max_depth)
        out["fields"].append(field)
    return out


def scan_markers(b):
    found = []
    for marker in MARKERS:
        start = 0
        while True:
            at = b.find(marker, start)
            if at < 0:
                break
            found.append({
                "offset": at,
                "marker": marker.decode("ascii"),
                "context": " ".join(f"{x:02x}" for x in b[max(0, at - 4):at + 8]),
            })
            start = at + 1
    found.sort(key=lambda x: x["offset"])
    return found


def inspect(path, offset, max_depth):
    with open(path, "rb") as f:
        b = f.read()
    if offset < 0 or offset >= len(b):
        raise ValueError(f"--offset {offset} is outside {path} ({len(b)} B)")
    ident, idat, root = ident_at(b, offset)
    result = {
        "path": path,
        "size": len(b),
        "sha256": hashlib.sha256(b).hexdigest(),
        "offset": offset,
        "header_hex": " ".join(f"{x:02x}" for x in b[:32]),
        "identifier": ident,
        "identifier_offset": idat,
        "root_uoffset": root,
        "root_table": None,
        "markers": scan_markers(b),
    }
    if root is not None and is_table(b, offset + root):
        result["root_table"] = describe_table(b, offset + root, 0, max_depth)
    elif root is not None:
        result["root_error"] = (
            f"root uoffset {root} -> table {offset + root} is not valid "
            f"(file size {len(b)})"
        )
    else:
        result["root_error"] = (
            "identifier-first container: no root uoffset at this offset"
        )
    return result


def print_human(data):
    print(f"{data['path']}: {data['size']} B, sha256 {data['sha256']}")
    print(f"offset {data['offset']}; header {data['header_hex']}")
    print(f"identifier {data['identifier']!r} at {data['identifier_offset']}; "
          f"root {data['root_uoffset']}")
    if data["root_table"]:
        t = data["root_table"]
        print(f"root table @ {t['table']}: vtable {t['vtable']}, "
              f"table {t['table_size']} B, {len(t['fields'])} slots")
        for f in t["fields"]:
            if not f["present"]:
                print(f"  field {f['index']}: absent")
                continue
            print(f"  field {f['index']}: @ {f['at']} "
                  f"raw {f.get('raw_hex', '')} u32 0x{f.get('u32', 0):08x} "
                  f"u64 0x{f.get('u64', 0):016x}")
            if "ascii" in f:
                print(f"    ascii {f['ascii']!r}")
            if "nested_table" in f:
                n = f["nested_table"]
                print(f"    nested table @ {n['table']}: "
                      f"{len(n['fields'])} slots")
    elif "root_error" in data:
        print(f"root: {data['root_error']}")
    if data["markers"]:
        print("markers:")
        for m in data["markers"]:
            print(f"  {m['marker']} at {m['offset']}: {m['context']}")
    if data["identifier"] == "" and data["markers"]:
        first = data["markers"][0]
        if first["marker"] in ("DGC0", "DWS0", "DWN1"):
            print(f"hint: inspect the payload with --offset {first['offset'] - 4}")


def cmd_inspect(args):
    data = inspect(args.file, args.offset, args.depth)
    if args.expect:
        if data["identifier"] != args.expect:
            print(f"{args.file}: identifier {data['identifier']!r}, "
                  f"expected {args.expect!r}", file=sys.stderr)
            return 1
    if args.json:
        print(json.dumps(data, indent=2, sort_keys=True))
    else:
        print_human(data)
    return 0


def strict_errors(data):
    """Return the reasons a container cannot be sent to the live core."""
    errors = []
    if data["identifier"] not in ("DGC0", "DWS0"):
        errors.append(
            f"identifier {data['identifier']!r} is not DGC0 or DWS0 "
            "(core verifier at 0xb9da8)"
        )
    if data["root_uoffset"] is None:
        errors.append("no root uoffset at the selected offset")
    if "root_error" in data:
        errors.append(data["root_error"])
    if not data["root_table"]:
        errors.append("no valid root table")
    markers = {m["marker"] for m in data["markers"]}
    if data["identifier"] == "DGC0":
        for required in ("DGD0", "DWS0"):
            if required not in markers:
                errors.append(f"missing {required} section")
    return errors


def cmd_verify(args):
    data = inspect(args.file, args.offset, args.depth)
    errors = strict_errors(data)
    if args.json:
        print(json.dumps({"path": args.file, "ok": not errors,
                          "errors": errors, "inspect": data},
                         indent=2, sort_keys=True))
    else:
        print(f"{args.file}: {data['identifier']!r} at "
              f"{data['identifier_offset']}, root {data['root_uoffset']}")
        if errors:
            for error in errors:
                print(f"FAIL: {error}")
        else:
            print("OK: DGC0/DWS0, root table and expected sections")
    return 1 if errors else 0


def cmd_scan(args):
    with open(args.file, "rb") as f:
        b = f.read()
    found = scan_markers(b)
    if args.json:
        print(json.dumps({"path": args.file, "size": len(b),
                          "markers": found}, indent=2, sort_keys=True))
        return 0
    print(f"{args.file}: {len(b)} B")
    for m in found:
        print(f"  {m['marker']} at {m['offset']}: {m['context']}")
    if not found:
        print("  no DGC0/DWS0/DGD0/DWN1/TCHN/DIVE marker")
    return 0


def cmd_compare(args):
    a = inspect(args.a, args.offset_a, args.depth)
    b = inspect(args.b, args.offset_b, args.depth)
    print(f"A {a['path']}: {a['size']} B, {a['sha256']}, "
          f"identifier {a['identifier']!r}, root {a['root_uoffset']}")
    print(f"B {b['path']}: {b['size']} B, {b['sha256']}, "
          f"identifier {b['identifier']!r}, root {b['root_uoffset']}")
    print(f"same bytes: {a['sha256'] == b['sha256']}")
    print(f"same identifier: {a['identifier'] == b['identifier']}")
    print(f"size delta: {b['size'] - a['size']} B")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    ins = sub.add_parser("inspect", help="inspect one container")
    ins.add_argument("file")
    ins.add_argument("--offset", type=int, default=0,
                     help="base of the flatbuffer (default 0)")
    ins.add_argument("--depth", type=int, default=2,
                     help="nested-table depth (default 2)")
    ins.add_argument("--expect", help="require this 4-byte identifier")
    ins.add_argument("--json", action="store_true")
    ins.set_defaults(func=cmd_inspect)

    ve = sub.add_parser("verify", help="strictly check a core graph container")
    ve.add_argument("file")
    ve.add_argument("--offset", type=int, default=0)
    ve.add_argument("--depth", type=int, default=1)
    ve.add_argument("--json", action="store_true")
    ve.set_defaults(func=cmd_verify)

    sc = sub.add_parser("scan", help="list graph identifier markers")
    sc.add_argument("file")
    sc.add_argument("--json", action="store_true")
    sc.set_defaults(func=cmd_scan)

    co = sub.add_parser("compare", help="compare two containers")
    co.add_argument("a")
    co.add_argument("b")
    co.add_argument("--offset-a", type=int, default=0)
    co.add_argument("--offset-b", type=int, default=0)
    co.add_argument("--depth", type=int, default=0)
    co.set_defaults(func=cmd_compare)

    args = ap.parse_args(argv)
    try:
        return args.func(args)
    except (OSError, ValueError) as exc:
        print(f"tpu-graph: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
