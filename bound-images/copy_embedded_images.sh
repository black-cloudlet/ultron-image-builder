#!/bin/bash
# Replay the baked-in image cache into containers-storage, and remove what an
# earlier version of this OS image left there. Runs once per boot from
# copy-embedded-images.service, before MicroShift starts.
#
# Adapted from redhat-et/edge-ai-image-pipelines (Apache-2.0),
# tegra/physically-bound-images/copy_embedded_images.sh.
set -euxo pipefail

CACHE_DIR=/usr/lib/containers-image-cache
MAPPING="$CACHE_DIR/mapping.txt"

# An upgrade replaces the cache but not containers-storage, so what a previous
# boot put there is known only from a record this script keeps.
APPLIED=/var/lib/physically-bound-images/applied.txt

mkdir -p "${APPLIED%/*}"
keep="$APPLIED.new"
if [[ -s $MAPPING ]]; then
	cp "$MAPPING" "$keep"
else
	# Nothing embedded is not an error; a previous set may still need clearing.
	echo "no embedded images at $MAPPING, nothing to copy"
	: > "$keep"
fi

# Before the copy: the superseded set is what makes room for its replacement,
# and the source is local disk, so the copy cannot fail for want of an upstream.
# A removal CRI-O refuses — it still holds the image through last boot's
# containers — stays on the list so the next boot retries instead of orphaning it.
if [[ -f $APPLIED ]]; then
	while IFS=, read -r image sha; do
		if grep -qxF "$image,$sha" "$keep"; then
			continue
		fi
		if podman rmi --ignore "$image"; then
			continue
		fi
		echo "leaving $image in containers-storage: could not remove it"
		echo "$image,$sha" >> "$keep"
	done < "$APPLIED"
fi

if [[ -s $MAPPING ]]; then
	while IFS="," read -r image sha; do
		skopeo copy --preserve-digests "dir:$CACHE_DIR/$sha" "containers-storage:$image"
	done < "$MAPPING"
fi

mv "$keep" "$APPLIED"
