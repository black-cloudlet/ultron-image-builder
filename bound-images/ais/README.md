# Proof: embedded images as an additional image store

Branch `ais-whiteout-proof`. Not for `main` as it stands: it answers one
question before anything is redesigned.

**The question.** Could the embedded images live in `/usr` as an additional
image store (AIS), read-only, used directly by CRI-O? That would replace today's
`dir:` cache, which a boot copies into `/var/lib/containers` so the eMMC holds
every image twice.

**The obstacle.** An overlay store records a deleted file as a whiteout (a 0:0
character device or a `.wh.NAME` file) and a replaced directory as *opaque* (an
xattr or a `.wh..wh..opq` file). Those are also overlayfs's and OCI's own
markers. When a `podman build` RUN step writes a store, the build reads them as
its own: they become deletions in the OS image's layer, the node's unpack
applies them to nothing, and the store on the node has lost every deletion its
images made. A container would see files its image deleted, with no error
(tested 2026-11-18).

**The fix being proved.** ostree has a marker of its own, an empty file named
`.ostree-wh.NAME`. To a build it is an ordinary file, and when ostree deploys a
tree it becomes a 0:0 device `NAME`. So:

1. `build_proof_store.sh` writes the store in a build cache mount. That is the
   build host's own disk, not the build's overlay, so the markers are real files
   there.
2. `translate_whiteouts.py` rewrites every whiteout as `.ostree-wh.NAME`, and
   every opaque directory as one `.ostree-wh.` marker per name the layers below
   hold there. ostree has no opaque form.
3. Only the translated tree is copied into `/usr/lib/containers/storage-proof`.
4. On the node, ostree's deploy turns the markers back into 0:0 devices, which
   is what the kernel's overlay reads.

The test image (`make_test_image.py`, 30 kB, three layers, no registry) covers
each case:
- a deleted file;
- a deleted directory;
- a replaced directory with a subdirectory on both sides;
- a name added again after its directory was deleted.

Our real images have these too: cert-manager's controller has two opaque
directories.

## Files

| File | Job |
|---|---|
| `make_test_image.py` | write the test image as an OCI layout |
| `translate_whiteouts.py` | rewrite a store's whiteouts and opaque directories as `.ostree-wh.` files |
| `build_proof_store.sh` | the RUN step: test image → staging store → translate → `/usr` (`-n`: skip the translation, as a control) |
| `check_store.sh` | as root: use the store the way CRI-O would and check what a container sees |
| `local-test.sh` | all of the above on one machine, with ostree standing in for the node |

`services/Containerfile` runs `build_proof_store.sh`. `services/smoke-test.sh`
checks the markers after the rechunk. Nothing on the node uses the store, and
no `storage.conf` names it, until `check_store.sh` does.

## What has been shown, and where

Locally (Ubuntu 24.04, podman 4.9.3, skopeo 1.13.3, libostree 2024.5, kernel
6.18), by `local-test.sh`:
- **translated:** after `ostree admin deploy`, all four markers are 0:0 devices,
  podman lists the image as read-only from the store, and a container sees
  exactly the four files it should;
- **control** (`-n`): the same check fails on all four deleted files. The check
  can tell lost deletions apart.

Also locally: the translator on a store in kernel form (devices and xattrs)
gives the same four markers, and the smoke-test section passes on the
translated image and fails on the control.

Not shown here, and what the dispatch and jetson-1 are for:
- **CI** builds the step with RHEL's podman and skopeo, with the default
  capabilities. Locally this needed `--cap-add`, but only because the sandbox
  could not raise the defaults.
- **The rechunk** keeps the markers. The smoke test runs after it.
- **bootc on RHEL 9.8 deploys like `ostree admin deploy`.** Locally the tree was
  flattened with `podman export`, not imported layer by layer by ostree-ext.
- **composefs.** If the vendor image mounts `/usr` through composefs, the
  devices must still reach the kernel's overlay as whiteouts. `check_store.sh`
  prints how `/usr` is mounted and what `prepare-root.conf` says about
  composefs.

## Running it

Locally, as root, with podman, ostree and tar, and network for the Alpine
base:

```bash
sudo bash bound-images/ais/local-test.sh -b --network=host
```

In CI: dispatch `ultron.yml` on branch `ais-whiteout-proof`. It pushes the date
tag only, never `latest` or `stable`. The `services` job's smoke test ends with
`== proof store (branch ais-whiteout-proof) ==` and `4 markers, the image
recorded`.

On jetson-1, booted from that build's ISO or `bootc switch`ed to its
`ultron-bootc` digest:

```bash
sudo bash check_store.sh
```

Copy the script over from the repo: the image does not carry it.

- **It ends `proof store check passed`:** the approach works on this hardware
  and OS, and the redesign is worth doing.
- **`untranslated .ostree-wh. files` above 0:** bootc's deploy skips the
  conversion.
- **Devices present, but a deleted file still visible:** composefs or the kernel
  hides them from overlay.

Either failure ends the idea.

## What it would take after a pass (not done here)

- `embed_image.sh` writes into the store this way. For real sizes the staging
  needs the runner's disk (the cache mount is on `/var/tmp`, bound to
  `/scratch` in CI), and one store per layer, so a layer above does not rewrite
  the metadata of the one below.
- `additionalimagestores` in the node's storage configuration, and a check that
  `crio config` sets no `storage_option` that would override it.
- SELinux labels on the store, settled on hardware.
- `copy_embedded_images.sh`, its unit and the prune go away; `20-pinned-images.conf`
  stays.
- RHEL-75827: an image pulled later can share a layer with the store and break
  when an upgrade drops it. Rule: `crictl rmi` pulled images after such an
  upgrade.
- CLAUDE.md and README.md, and this directory removed.
