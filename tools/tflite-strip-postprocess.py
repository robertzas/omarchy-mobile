#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Strip the TFLite_Detection_PostProcess custom op from an SSD detector.

The stock DarwiNN compiler has no kernel for the CPU-only NMS/decode op, so a
plain SSD TFLite model cannot be compiled as-is. Removing the final operator
and exposing its two real inputs (box encodings and class scores) as the
model's outputs leaves exactly the part the Edge TPU runs; the caller does the
decode and NMS on the CPU.

Usage: tools/tflite-strip-postprocess.py IN.tflite OUT.tflite
"""
import sys

import flatbuffers
import numpy as np
from ai_edge_litert import schema_py_generated as schema

POSTPROCESS = b"TFLite_Detection_PostProcess"


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as f:
        data = f.read()
    model = schema.ModelT.InitFromObj(schema.Model.GetRootAsModel(data, 0))
    subgraph = model.subgraphs[0]
    last = subgraph.operators[-1]
    opcode = model.operatorCodes[last.opcodeIndex]
    if opcode.customCode != POSTPROCESS:
        print(f"last op is {opcode.customCode!r}, not {POSTPROCESS!r}", file=sys.stderr)
        return 1
    boxes, scores = int(last.inputs[0]), int(last.inputs[1])
    subgraph.outputs = np.array([boxes, scores], dtype=np.int32)
    subgraph.operators.pop()
    builder = flatbuffers.Builder(0)
    builder.Finish(model.Pack(builder), file_identifier=b"TFL3")
    with open(dst, "wb") as f:
        f.write(bytes(builder.Output()))
    print(f"{src} -> {dst}: {len(subgraph.operators)} ops, outputs {boxes} {scores}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
