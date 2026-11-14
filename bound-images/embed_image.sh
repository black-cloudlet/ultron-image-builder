#!/bin/bash
# Copy one container image into the image cache baked into the OS image.
#
# Adapted from redhat-et/edge-ai-image-pipelines (Apache-2.0),
# tegra/physically-bound-images/embed_image.sh.
#
# Images land in /usr/lib/containers-image-cache/<sha of reference> and
# mapping.txt records reference -> sha. copy_embedded_images.sh replays that
# into containers-storage at boot. A plain cache directory is used rather than
# an additional container store at /usr/lib/containers/storage: images pulled
# into the main store would reuse its layers, and an OS upgrade that drops one
# leaves them pointing at nothing (RHEL-75827).
set -euxo pipefail

CACHE_DIR=/usr/lib/containers-image-cache

image=$1
additional_copy_args=("${@:2}")

fsha="$(echo "$image" | sha256sum | awk '{ print $1 }')"

# The same reference arriving twice is a second copy of every blob, and if the
# first copy was made in a lower layer both of them ship in the image: the write
# is a copy-up, and overlay keeps what it copied from. Callers build their lists
# by concatenation — release-info plus the manifest scan, that scan plus
# SERVICE_IMAGES — and none of them dedupe across the seam, so the embed is
# idempotent here rather than in each caller. Keyed on manifest.json because
# skopeo writes it after the blobs: a copy interrupted half way leaves the
# directory behind but not that file, and is redone rather than trusted.
if [[ -f "$CACHE_DIR/$fsha/manifest.json" ]]; then
	echo "already embedded: $image"
	exit 0
fi

src=$image
dst=$image

# skopeo rejects references of the form $REPO:$TAG@sha256:$SHA, so split them:
# pull by digest, record under the tagged name the manifests will ask for.
# Two images differing only by digest under one tag would collide here; nothing
# in MicroShift's release list does that today.
if [[ $image =~ .*:.*@sha256:.* ]]; then
	repo="${image%%:*}"
	spec="${image#*:}"
	tag="${spec%%@*}"
	sha="${spec#*@}"

	src=$repo@$sha
	dst=$repo:$tag
fi

# Only the node's architecture; builder and node are both aarch64. A reference
# pinned to a manifest-list digest still resolves: containers-storage looks an
# image up by its explicit name before it looks by digest.
mkdir -p "$CACHE_DIR"
skopeo copy --multi-arch=system --preserve-digests "${additional_copy_args[@]}" \
	"docker://$src" "dir:$CACHE_DIR/$fsha"
echo "$dst,$fsha" >> "$CACHE_DIR/mapping.txt"
