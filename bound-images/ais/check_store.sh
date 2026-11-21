#!/bin/bash
# Check the proof store as CRI-O would use it: as an additional image store,
# read-only, under the kernel's overlay. As root; on a node, after booting an
# image built with the proof step:
#   sudo bash check_store.sh
# local-test.sh runs it against a deployment it makes itself (-s).
#
# Passes when a container's view of the test image is exactly what
# make_test_image.py intends: four names present, four deleted ones absent.
# Leaves nothing behind: its storage is a temporary directory under /var/tmp.
set -euo pipefail

store=/usr/lib/containers/storage-proof
IMAGE=localhost/ais-proof:1
PRESENT=(data/keep data/dir/new data/dir/sub/y data/gonedir/again)
ABSENT=(data/gone data/gonedir/f data/dir/old data/dir/sub/x)

usage() {
	cat <<EOF
usage: $0 [-s STORE]
  -s STORE  the proof store (default: $store)
EOF
	exit 2
}

while getopts s: opt; do
	case $opt in
	s) store=$OPTARG ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))
[[ $# -eq 0 ]] || usage
if [[ $EUID -ne 0 ]]; then
	echo "run as root: the check mounts overlay"
	exit 1
fi
if [[ ! -d $store/overlay ]]; then
	echo "no proof store at $store"
	ls -la "${store%/*}" || true
	exit 1
fi

echo "== where the store sits"
findmnt -no SOURCE,FSTYPE,OPTIONS --target "$store" || true
if [[ -f /usr/lib/ostree/prepare-root.conf ]]; then
	grep -A2 -i composefs /usr/lib/ostree/prepare-root.conf || echo "no composefs section"
fi

# ostree turns `.ostree-wh.NAME` into a 0:0 device when it deploys. A marker
# still a file means the deployment skipped that, and the deletions are lost.
echo "== deletion markers"
files=$(find "$store/overlay" -path '*/diff/*' -name '.ostree-wh.*' | wc -l)
devices=$(find "$store/overlay" -path '*/diff/*' -type c | wc -l)
echo "$devices whiteout devices, $files untranslated .ostree-wh. files"
find "$store/overlay" -path '*/diff/*' \( -type c -o -name '.ostree-wh.*' \) \
	-printf '%y %P\n' | sed 's|^\(.\) [^/]*/diff/|   \1 |'
fail=0
if [[ $files -ne 0 ]]; then
	echo "FAIL: the deployment left .ostree-wh. files as files"
	fail=1
fi

work=$(mktemp -d /var/tmp/ais-proof.XXXXXX)
# Its own empty storage.conf and root: the node's configuration stays out of
# the test, and the test out of the node's containers-storage.
: > "$work/storage.conf"
podman() {
	CONTAINERS_STORAGE_CONF=$work/storage.conf command podman \
		--root "$work/root" --runroot "$work/run" --storage-driver overlay \
		--storage-opt "additionalimagestore=$store" "$@"
}
cleanup() {
	podman umount -a >/dev/null 2>&1 || true
	podman rm -fa >/dev/null 2>&1 || true
	rm -rf -- "${work:?}"
}
trap cleanup EXIT

echo "== the image, from the store"
podman images --format '{{.Repository}}:{{.Tag}} read-only={{.ReadOnly}}' | grep -F "$IMAGE" || {
	echo "FAIL: $IMAGE is not in the store"
	exit 1
}
podman create -q --pull=never --name ais-proof "$IMAGE" /none >/dev/null
root=$(podman mount ais-proof)

echo "== what a container sees"
for f in "${PRESENT[@]}"; do
	if [[ -f $root/$f ]]; then
		echo "   present, as it should be: /$f"
	else
		echo "FAIL: missing /$f"
		fail=1
	fi
done
for f in "${ABSENT[@]}"; do
	if [[ -e $root/$f ]]; then
		echo "FAIL: deleted in the image, but there: /$f"
		fail=1
	else
		echo "   absent, as it should be: /$f"
	fi
done

if (( fail )); then
	echo "proof store check FAILED"
	exit 1
fi
echo "proof store check passed"
