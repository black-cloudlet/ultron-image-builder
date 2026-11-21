#!/usr/bin/python3 -I
"""Write a three-layer OCI image whose layers delete and replace files.

Usage: make_test_image.py OCI_DIR

The proof's test image. Built here rather than pulled so it needs no registry
and holds exactly the cases an embedded image's deletions can take:

  layer 1  data/keep, data/gone, data/gonedir/f, data/dir/old, data/dir/sub/x
  layer 2  deletes data/gone and data/gonedir (whiteouts); replaces data/dir
           with data/dir/new and data/dir/sub/y (an opaque directory, whose
           subdirectory exists below as well)
  layer 3  re-adds data/gonedir/again

A correct store shows data/keep, data/dir/new, data/dir/sub/y and
data/gonedir/again, and none of data/gone, data/gonedir/f, data/dir/old or
data/dir/sub/x. node-check.sh and local-test.sh test exactly that.
"""
import hashlib
import io
import json
import os
import sys
import tarfile

ARCH = {"aarch64": "arm64", "x86_64": "amd64"}

LAYERS = [
    [
        ("data/", None),
        ("data/keep", b"keep\n"),
        ("data/gone", b"gone\n"),
        ("data/gonedir/", None),
        ("data/gonedir/f", b"f\n"),
        ("data/dir/", None),
        ("data/dir/old", b"old\n"),
        ("data/dir/sub/", None),
        ("data/dir/sub/x", b"x\n"),
    ],
    [
        ("data/", None),
        ("data/.wh.gone", b""),
        ("data/.wh.gonedir", b""),
        ("data/dir/", None),
        ("data/dir/.wh..wh..opq", b""),
        ("data/dir/new", b"new\n"),
        ("data/dir/sub/", None),
        ("data/dir/sub/y", b"y\n"),
    ],
    [
        ("data/", None),
        ("data/gonedir/", None),
        ("data/gonedir/again", b"again\n"),
    ],
]


def layer_tar(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for name, data in entries:
            info = tarfile.TarInfo(name.rstrip("/"))
            info.mtime = 0
            if data is None:
                info.type, info.mode = tarfile.DIRTYPE, 0o755
                tar.addfile(info)
            else:
                info.size, info.mode = len(data), 0o644
                tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def put_blob(blobs, data):
    digest = hashlib.sha256(data).hexdigest()
    with open(os.path.join(blobs, digest), "wb") as f:
        f.write(data)
    return "sha256:" + digest


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.split("\n\n")[1])
    out = sys.argv[1]
    if os.path.exists(out):
        sys.exit(f"{out} already exists")
    blobs = os.path.join(out, "blobs", "sha256")
    os.makedirs(blobs)

    layers = []
    for entries in LAYERS:
        data = layer_tar(entries)
        layers.append({
            "mediaType": "application/vnd.oci.image.layer.v1.tar",
            "digest": put_blob(blobs, data),
            "size": len(data),
        })
    config = json.dumps({
        "architecture": ARCH.get(os.uname().machine, os.uname().machine),
        "os": "linux",
        "config": {},
        "rootfs": {"type": "layers", "diff_ids": [l["digest"] for l in layers]},
    }, sort_keys=True).encode()
    manifest = json.dumps({
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "config": {
            "mediaType": "application/vnd.oci.image.config.v1+json",
            "digest": put_blob(blobs, config),
            "size": len(config),
        },
        "layers": layers,
    }, sort_keys=True).encode()
    index = {
        "schemaVersion": 2,
        "manifests": [{
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "digest": put_blob(blobs, manifest),
            "size": len(manifest),
        }],
    }
    with open(os.path.join(out, "index.json"), "w") as f:
        json.dump(index, f)
    with open(os.path.join(out, "oci-layout"), "w") as f:
        json.dump({"imageLayoutVersion": "1.0.0"}, f)


if __name__ == "__main__":
    main()
