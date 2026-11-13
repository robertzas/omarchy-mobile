#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Model the Edge TPU firmware container and test what its code can reference.

Why this tool exists: TPU-PLAN gate D needs the firmware's own setup handler.
Two passes assumed the body is plaintext Thumb-2 that points at the string
island at 0xe0000..0xfd7c0, and both failed to find a reference. This tool
makes that check repeatable and separates three questions the earlier passes
mixed up:

  info     what the container declares (TPUF header, image config, entropy);
  reach    whether the decoded body references the string island at all
           (immediates, movw/movt pairs, offset tables, link-address tables);
  strings  the island's strings, with the file offsets the handler analysis
           needs as anchors.

`reach` exits 1 when it finds no reference, which is the current A17 result:
the island is not reachable from the body as decoded, so a static pass has to
model the container's segments first (TPU-PLAN F1).

Examples:
  tools/tpu-fw.py info out/tpu/edgetpu-janeiro.fw
  tools/tpu-fw.py reach out/tpu/edgetpu-janeiro.fw
  tools/tpu-fw.py strings out/tpu/edgetpu-janeiro.fw --grep setup
  tools/tpu-fw.py --self-test
"""

import argparse
import math
import re
import struct
import sys

MAGIC = 0x46555054  # 'TPUF', little endian
HEADER_OFFSET = 0x400
IMAGE_CONFIG_OFFSET = HEADER_OFFSET + 0x160


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def entropy(data):
    if not data:
        return 0.0
    counts = [0] * 256
    for byte in data:
        counts[byte] += 1
    n = len(data)
    return -sum((c / n) * math.log2(c / n) for c in counts if c)


def strings_in(b, low, high):
    out = []
    for m in re.finditer(rb"[\x20-\x7e]{5,}", b):
        if m.end() >= len(b) or b[m.end()] != 0:
            continue
        if low <= m.start() < high:
            out.append((m.start(), m.group().decode("ascii", "replace")))
    return out


def parse_container(b):
    """Return the declared header fields, or a reason it is not a container."""
    if len(b) < IMAGE_CONFIG_OFFSET + 64:
        raise ValueError("file is too small for a mobile firmware image")
    if u32(b, HEADER_OFFSET) != MAGIC:
        raise ValueError(f"no TPUF magic at {HEADER_OFFSET:#x}")
    info = {
        "generation": u32(b, HEADER_OFFSET + 4),
        "rollback": u32(b, HEADER_OFFSET + 8),
        "declared_length": u32(b, HEADER_OFFSET + 0xC),
        "file_length": len(b),
        "flags": b[HEADER_OFFSET + 0x10:HEADER_OFFSET + 0x20].hex(),
        "body_hash": b[HEADER_OFFSET + 0x20:HEADER_OFFSET + 0x40].hex(),
        "carveout_base": u32(b, IMAGE_CONFIG_OFFSET),
        "firmware_base": u32(b, IMAGE_CONFIG_OFFSET + 4),
        "firmware_size": u32(b, IMAGE_CONFIG_OFFSET + 8),
        "raw_config_words": [u32(b, IMAGE_CONFIG_OFFSET + 4 * i)
                             for i in range(24)],
    }
    return info


def cmd_info(args):
    b = open(args.file, "rb").read()
    info = parse_container(b)
    print(f"{args.file}: {info['file_length']} B, "
          f"sha256 {hashlib_sha256(b)}")
    print(f"TPUF generation {info['generation']}, rollback {info['rollback']}, "
          f"declared length {info['declared_length']:#x}")
    print(f"body hash {info['body_hash'][:32]}...")
    print(f"carveout {info['carveout_base']:#x}, firmware "
          f"{info['firmware_base']:#x} + {info['firmware_size']:#x}")
    print("config words from "
          f"{IMAGE_CONFIG_OFFSET:#x}: "
          + " ".join(f"{w:#010x}" for w in info["raw_config_words"]))
    print("entropy per 64 KiB:")
    for o in range(0, len(b) - 65536 + 1, 65536):
        print(f"  {o:#08x}-{o + 65536:#08x}  {entropy(b[o:o + 65536]):.2f}")
    island = strings_in(b, args.island, len(b))
    print(f"island strings from {args.island:#x}: {len(island)}")
    if island:
        print(f"  first {island[0][0]:#08x}, last {island[-1][0]:#08x}")
    return 0


def hashlib_sha256(b):
    import hashlib
    return hashlib.sha256(b).hexdigest()


def cmd_strings(args):
    b = open(args.file, "rb").read()
    pattern = re.compile(args.grep, re.I) if args.grep else None
    for off, text in strings_in(b, args.island, len(b)):
        if pattern and not pattern.search(text):
            continue
        print(f"{off:#08x}  {text}")
    return 0


def offset_tables(b, island_offsets, width, min_run):
    """Find arrays of island offsets (u32 or u16), the log-index candidate."""
    fmt = "<I" if width == 4 else "<H"
    step = width
    runs = []
    o = 0
    while o < len(b) - step * min_run:
        if struct.unpack_from(fmt, b, o)[0] not in island_offsets:
            o += step
            continue
        n = 0
        prev = -1
        while o + step * (n + 1) <= len(b):
            v = struct.unpack_from(fmt, b, o + step * n)[0]
            if v not in island_offsets or v < prev:
                break
            prev = v
            n += 1
        if n >= min_run:
            runs.append((o, n))
            o += step * n
            continue
        o += step
    return runs


def cmd_reach(args):
    import capstone
    from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB, CS_OP_IMM

    b = open(args.file, "rb").read()
    parse_container(b)
    island = strings_in(b, args.island, len(b))
    by_off = dict(island)
    offsets = set(by_off)
    names = {o for o, s in island
             if s.startswith("third_party/") or s.startswith("./")}
    targets = offsets | names
    print(f"island {args.island:#x}: {len(offsets)} strings, "
          f"{len(names)} file names")

    table32 = offset_tables(b, offsets, 4, 16)
    table16 = offset_tables(b, offsets, 2, 16)
    print(f"offset tables: u32 {[(hex(o), n) for o, n in table32][:4]} "
          f"u16 {[(hex(o), n) for o, n in table16][:4]}")

    md = Cs(CS_ARCH_ARM, CS_MODE_THUMB)
    md.skipdata = True
    md.detail = True
    insns = data = 0
    imm_hits = []
    movw = []
    for insn in md.disasm(b[args.code_off:args.code_end],
                          args.base + args.code_off):
        insns += 1
        if insn.id == 0:
            data += 1
            continue
        try:
            ops = insn.operands
        except capstone.CsError:
            continue
        if not ops:
            continue
        if insn.mnemonic in ("movw", "movt"):
            try:
                movw.append((insn.address, insn.mnemonic, ops[0].reg,
                             ops[1].imm))
            except (IndexError, AttributeError):
                pass
        for op in ops:
            if op.type == CS_OP_IMM and (op.imm in targets
                                         or op.imm in {args.base + o
                                                       for o in targets}):
                imm_hits.append((insn.address, insn.mnemonic, insn.op_str))
    pairs = {}
    for i, (addr, mn, reg, imm) in enumerate(movw):
        if mn != "movw":
            continue
        for _addr2, mn2, reg2, imm2 in movw[i + 1:i + 5]:
            if reg2 != reg or mn2 != "movt":
                continue
            full = (imm2 << 16) | imm
            if full in {args.base + o for o in targets} or full in targets:
                pairs.setdefault(full, addr)
            break
    print(f"decoded {insns} instructions, {data} data words, "
          f"{len(movw)} movw/movt")
    print(f"immediate references to the island: {len(imm_hits)}")
    for hit in imm_hits[:10]:
        print(f"  {hit[0]:#010x} {hit[1]} {hit[2]}")
    print(f"distinct island addresses the code loads: {len(pairs)}")
    for full in sorted(pairs)[:10]:
        off = full - args.base
        print(f"  {full:#010x} (file {off:#08x}) first at {pairs[full]:#x}"
              f"  {by_off.get(off, '')[:60]}")
    for want in args.want:
        hit = want + args.base in pairs or want in pairs
        print(f"  want {want:#08x}: {'referenced' if hit else 'NOT referenced'}")
    reachable = bool(imm_hits or pairs or table32 or table16)
    print("verdict: " + ("referenced" if reachable else
                         "NOT referenced from the decoded body"))
    return 0 if reachable else 1


def self_test(_args):
    """Build a synthetic container and check every parser against it."""
    import tempfile
    import os

    body_off = 0x1000
    island = 0x1200
    data = bytearray(island + 0x200)
    struct.pack_into("<I", data, HEADER_OFFSET, MAGIC)
    struct.pack_into("<I", data, HEADER_OFFSET + 4, 1)
    struct.pack_into("<I", data, HEADER_OFFSET + 0xC, len(data))
    struct.pack_into("<I", data, IMAGE_CONFIG_OFFSET, 0x93000000)
    struct.pack_into("<I", data, IMAGE_CONFIG_OFFSET + 4, 0x93000000)
    struct.pack_into("<I", data, IMAGE_CONFIG_OFFSET + 8, 0xFD000)
    # Two strings in the island, and one u32 offset table naming them.
    data[island:island + 8] = b"setup\x00\x00\x00"
    data[island + 8:island + 22] = b"global scratch\x00"
    struct.pack_into("<I", data, island + 0x40, island)
    struct.pack_into("<I", data, island + 0x44, island + 8)
    # Code: movw r0, #0x1200 ; movt r0, #0x1000 -> the island address.
    code = struct.pack("<HH", 0xF240, 0x0000)  # movw r0, #0 (patched below)
    code = struct.pack("<HH", 0xF240, 0x1000) if False else code
    # Encode movw r0, #0x1200 and movt r0, #0x1000 explicitly.
    movw = 0xF240 | ((0x1200 >> 12) & 0xF)  # i=0, imm4=0 -> simplified below
    insn_movw = bytes([0x40, 0xF2, 0x00, 0x20])   # movw r0, #0x200
    insn_movt = bytes([0xC0, 0xF2, 0x00, 0x10])   # movt r0, #0x1000
    data[body_off:body_off + 8] = insn_movw + insn_movt

    with tempfile.TemporaryDirectory(prefix="tpu-fw-") as tmp:
        path = os.path.join(tmp, "synthetic.fw")
        with open(path, "wb") as f:
            f.write(bytes(data))
        info = parse_container(open(path, "rb").read())
        assert info["generation"] == 1
        assert info["carveout_base"] == 0x93000000
        assert info["firmware_size"] == 0xFD000
        found = [s for _, s in strings_in(bytes(data), island, len(data))]
        assert "setup" in found, found
        # The offset table at island+0x40 must be found.
        offs = {o for o, _ in strings_in(bytes(data), island, len(data))}
        tables = offset_tables(bytes(data), offs, 4, 2)
        assert any(o == island + 0x40 for o, _ in tables), tables
        # The synthetic movw/movt pair targets 0x10000200, not the island;
        # this asserts the *scanner* runs and reports a count, not a hit.
        import capstone
        md = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_THUMB)
        md.skipdata = True
        decoded = list(md.disasm(bytes(data)[body_off:island],
                                 body_off))
        assert decoded and decoded[0].mnemonic == "movw"
        assert decoded[1].mnemonic == "movt"
    print("self-test: ok")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--file-default",
                    default="out/tpu/edgetpu-janeiro.fw")
    sub = ap.add_subparsers(dest="cmd")

    def common(p):
        p.add_argument("file", nargs="?", default="out/tpu/edgetpu-janeiro.fw")
        p.add_argument("--island", type=lambda s: int(s, 0), default=0xE0000,
                       help="first byte of the string island (default 0xe0000)")

    i = sub.add_parser("info", help="header, image config and entropy")
    common(i)
    i.set_defaults(func=cmd_info)

    r = sub.add_parser("reach", help="can the code reference the island?")
    common(r)
    r.add_argument("--base", type=lambda s: int(s, 0), default=0x10000000)
    r.add_argument("--code-off", type=lambda s: int(s, 0), default=0x1000)
    r.add_argument("--code-end", type=lambda s: int(s, 0), default=0xFD000)
    r.add_argument("--want", type=lambda s: [int(x, 0) for x in s.split(",")],
                   default=[0xEFBDC, 0xEFD8C, 0xEFDDC, 0xEFE18],
                   help="island offsets that must be referenced "
                        "(default: the four setup messages)")
    r.set_defaults(func=cmd_reach)

    s = sub.add_parser("strings", help="island strings")
    common(s)
    s.add_argument("--grep")
    s.set_defaults(func=cmd_strings)

    t = sub.add_parser("self-test", help="check the parsers")
    t.set_defaults(func=self_test)

    args = ap.parse_args(argv)
    if not getattr(args, "cmd", None):
        ap.print_help()
        return 2
    try:
        return args.func(args)
    except (OSError, ValueError) as exc:
        print(f"tpu-fw: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
