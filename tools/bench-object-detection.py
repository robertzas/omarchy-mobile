#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Object detection benchmark for the Edge TPU bring-up.

Runs an SSD-style TFLite detector over a video and reports latency and
detection counts. The source video is decoded and scaled by ffmpeg to the
model's input size, so no image library is needed.

Usage:
  tools/bench-object-detection.py --model M.tflite --labels labelmap.txt \
      --video clip.mp4 [--threads 4] [--threshold 0.5] [--backend note]

Output is one JSON line per run plus a short table, so a TPU run and a CPU run
compare directly. The TPU backend is added once the VII gate opens; this tool
only measures whatever interpreter it is given.
"""
import argparse
import json
import subprocess
import sys
import time

import numpy as np
from ai_edge_litert.interpreter import Interpreter


def load_labels(path):
    if not path:
        return {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        names = [line.strip() for line in f]
    labels = {}
    for i, name in enumerate(names):
        if not name or name == "???":
            continue
        labels[i - 1 if i > 0 else 0] = name
    return labels


def decode_ssd(outputs, threshold):
    boxes, classes, scores, count = outputs
    n = min(int(count.reshape(-1)[0]), boxes.shape[1])
    found = []
    for i in range(n):
        score = float(scores[0, i])
        if score < threshold:
            continue
        ymin, xmin, ymax, xmax = [float(v) for v in boxes[0, i]]
        found.append(
            {
                "class": int(classes[0, i]),
                "score": round(score, 4),
                "box": [round(ymin, 3), round(xmin, 3), round(ymax, 3), round(xmax, 3)],
            }
        )
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--labels")
    ap.add_argument("--video", required=True)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--threshold", type=float, default=0.5)
    ap.add_argument("--backend", default="cpu")
    ap.add_argument("--max-frames", type=int, default=0)
    args = ap.parse_args()

    labels = load_labels(args.labels)
    interp = Interpreter(model_path=args.model, num_threads=args.threads)
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    outs = interp.get_output_details()
    h, w = int(inp["shape"][1]), int(inp["shape"][2])

    cmd = [
        "ffmpeg", "-v", "error", "-i", args.video,
        "-vf", f"scale={w}:{h}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    frame_bytes = w * h * 3
    lat = []
    counts = []
    per_class = {}
    frames = 0

    while True:
        buf = proc.stdout.read(frame_bytes)
        if len(buf) < frame_bytes:
            break
        frame = np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 3)
        if inp["dtype"] == np.uint8:
            x = frame.reshape(1, h, w, 3)
        else:
            x = (frame.astype(np.float32) / 255.0 - 0.5).reshape(1, h, w, 3)
        t0 = time.perf_counter()
        interp.set_tensor(inp["index"], x.astype(inp["dtype"]))
        interp.invoke()
        lat.append(time.perf_counter() - t0)
        found = decode_ssd([interp.get_tensor(o["index"]) for o in outs], args.threshold)
        counts.append(len(found))
        for det in found:
            name = labels.get(det["class"], str(det["class"]))
            per_class[name] = per_class.get(name, 0) + 1
        frames += 1
        if args.max_frames and frames >= args.max_frames:
            break
    proc.stdout.close()
    proc.wait()

    if not frames:
        print("no frames decoded", file=sys.stderr)
        return 1
    lat_ms = np.array(lat) * 1000.0
    result = {
        "backend": args.backend,
        "model": args.model,
        "video": args.video,
        "input": [h, w],
        "threads": args.threads,
        "threshold": args.threshold,
        "frames": frames,
        "mean_ms": round(float(lat_ms.mean()), 2),
        "p50_ms": round(float(np.percentile(lat_ms, 50)), 2),
        "p95_ms": round(float(np.percentile(lat_ms, 95)), 2),
        "fps": round(1000.0 / float(lat_ms.mean()), 2),
        "mean_detections": round(float(np.mean(counts)), 2),
        "max_detections": int(np.max(counts)),
        "classes": dict(sorted(per_class.items(), key=lambda kv: -kv[1])),
    }
    print(json.dumps(result, sort_keys=True))
    print(
        f"{args.backend}: {frames} frames, {result['mean_ms']} ms mean "
        f"({result['fps']} fps), detections mean {result['mean_detections']} "
        f"max {result['max_detections']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
