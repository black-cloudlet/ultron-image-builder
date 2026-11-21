#!/bin/bash
# Build the proof store: the test image in an overlay image store under /usr,
# with its deletion markers in ostree's form so they survive the build.
#
# Runs inside a `podman build` RUN step, with this directory bind-mounted and
# a cache mount for the staging store:
#   RUN --mount=type=bind,src=bound-images/ais,dst=/ais \
#       --mount=type=cache,id=ais-proof-staging,dst=/var/tmp/ais-staging \
#       /ais/build_proof_store.sh /var/tmp/ais-staging /usr/lib/containers/storage-proof
#
# The store is written in STAGING first because a cache mount is a directory
# on the build host's own disk, not the build's overlay: there the store's
# whiteouts are real 0:0 devices, visible to translate_whiteouts.py. Only the
# translated tree is copied into DEST. (A tmpfs would do, but the storage
# library refuses overlay on tmpfs.) STAGING is emptied before and after, so
# the cache directory left on the build host holds nothing.
set -euo pipefail

here=${BASH_SOURCE[0]%/*}
IMAGE=localhost/ais-proof:1

usage() {
	cat <<EOF
usage: $0 [-n] STAGING DEST
  STAGING  directory on a plain filesystem (a cache mount in the build);
           its contents are deleted
  DEST     where the store lands in the image, created; must not exist
  -n       skip the translation: the control that shows the markers lost
EOF
	exit 2
}

translate=1
while getopts n opt; do
	case $opt in
	n) translate=0 ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))
[[ $# -eq 2 ]] || usage
staging=$1 dest=$2

if [[ -e $dest ]]; then
	echo "$dest already exists"
	exit 1
fi
if [[ ! -d $staging ]]; then
	echo "not a directory: $staging"
	exit 1
fi
# Nesting on overlay is the very thing this avoids.
fstype=$(stat -f -c %T "$staging")
if [[ $fstype == overlayfs ]]; then
	echo "$staging is on overlayfs; it must be a plain filesystem (a cache mount)"
	exit 1
fi
# An earlier build interrupted half way may have left a store behind.
empty() { find "$staging" -mindepth 1 -delete; }
empty
trap empty EXIT

store=$staging/store
python3 -I "$here/make_test_image.py" "$staging/oci"

# Its own policy: the test image is built here and carries no signature, and
# the image's policy is no business of this test.
printf '{"default":[{"type":"insecureAcceptAnything"}]}' > "$staging/policy.json"
# An empty storage.conf: none of the image's own options (an additional
# store, mount options) may leak into the store being written. Two options
# stand in for the CAP_SYS_ADMIN a RUN step does not have:
#   skip_mount_home  no bind mount of the store onto itself;
#   mount_program    no probe that mounts overlay to see whether it works.
#                    Nothing is ever mounted here, so /bin/true never runs.
#                    It also makes the store keep deletions as `.wh.` files
#                    (fuse-overlayfs form) rather than devices; the store
#                    records neither, and translate_whiteouts.py takes both.
: > "$staging/storage.conf"
CONTAINERS_STORAGE_CONF=$staging/storage.conf skopeo --policy "$staging/policy.json" \
	copy --preserve-digests \
	"oci:$staging/oci" \
	"containers-storage:[overlay@$store+$staging/run:overlay.skip_mount_home=true,overlay.mount_program=/bin/true]$IMAGE"

# The test proves nothing if the store holds no markers to lose: layer 2's two
# whiteouts, as devices or as `.wh.` files.
markers=$(find "$store/overlay" -path '*/diff/*' \( -type c -o -name '.wh.*' ! -name '.wh..wh..opq' \) | wc -l)
if [[ $markers -ne 2 ]]; then
	echo "expected 2 whiteouts in the staging store, found $markers:"
	find "$store/overlay" -path '*/diff/*' -printf '%y %p\n'
	exit 1
fi
echo "staging store: $markers whiteouts"

# What make_test_image.py's layer 2 must become: its two deletions, and the
# opaque data/dir spelt out as the two names below it, one a level down.
expected='data/.ostree-wh.gone
data/.ostree-wh.gonedir
data/dir/.ostree-wh.old
data/dir/sub/.ostree-wh.x'
if (( translate )); then
	python3 -I "$here/translate_whiteouts.py" "$store"
	got=$(find "$store/overlay" -path '*/diff/*' -name '.ostree-wh.*' |
		sed 's|.*/diff/||' | sort)
	if [[ $got != "$expected" ]]; then
		printf 'expected markers:\n%s\nfound:\n%s\n' "$expected" "$got"
		exit 1
	fi
else
	echo "control: translation skipped"
fi

# Only the store: its run root stays behind in the cache mount, emptied.
mkdir -p "${dest%/*}"
cp -a "$store" "$dest"
echo "proof store at $dest:"
find "$dest/overlay" -path '*/diff/*' -printf '%y %P\n' |
	sed 's|^\(.\) \([0-9a-f]\{12\}\)[0-9a-f]*/diff/|\1 \2 |' | sort -k3
