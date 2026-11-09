#!/usr/bin/env python3
"""Send one all-zeros request to a Triton model over KServe's v2 REST protocol.

Reads the model's inputs from its metadata, so no input name or shape is
hard-coded. Zeros only prove the server answers; they are not a test of what
the model predicts. Standard library only: runs on the node's own python3.

usage: infer.py BASE_URL MODEL [RUNS]   e.g. infer.py http://localhost:8080 resnet50 20
"""
import json
import math
import statistics
import sys
import time
import urllib.error
import urllib.request


def get(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__.strip().splitlines()[-1])
    base, model = sys.argv[1].rstrip("/"), sys.argv[2]
    runs = int(sys.argv[3]) if len(sys.argv) == 4 else 10

    meta = get(f"{base}/v2/models/{model}")
    inputs = []
    for i in meta["inputs"]:
        if i["datatype"] == "BYTES":
            sys.exit(f"input {i['name']} is BYTES: zeros do not fit, send a real request")
        # -1 is the batch (or any dynamic) dimension: send one.
        shape = [d if d > 0 else 1 for d in i["shape"]]
        zero = False if i["datatype"] == "BOOL" else 0
        inputs.append({"name": i["name"], "shape": shape, "datatype": i["datatype"],
                       "data": [zero] * math.prod(shape)})
        print(f"input  {i['name']} {i['datatype']} {shape}")
    body = json.dumps({"inputs": inputs}).encode()

    times = []
    for _ in range(runs):
        req = urllib.request.Request(f"{base}/v2/models/{model}/infer", data=body,
                                     headers={"Content-Type": "application/json"})
        start = time.monotonic()
        with urllib.request.urlopen(req, timeout=120) as r:
            out = json.load(r)
        times.append((time.monotonic() - start) * 1000)

    for o in out["outputs"]:
        print(f"output {o['name']} {o['datatype']} {o['shape']} first: {o['data'][:5]}")
    # The first request warms up (CUDA context, ORT session): report it apart.
    rest = times[1:] or times
    print(f"{runs} requests: first {times[0]:.1f} ms, median of the rest "
          f"{statistics.median(rest):.1f} ms (JSON over HTTP included)")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        # Triton says why in the body ("unknown model", a shape mismatch).
        sys.exit(f"{e.url}: HTTP {e.code}: {e.read().decode(errors='replace')}")
