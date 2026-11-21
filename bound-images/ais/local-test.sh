#!/bin/bash
# The proof end to end on one machine, standing in for CI and the node:
#   1. podman build an image whose RUN step runs build_proof_store.sh, the
#      way services/Containerfile does;
#   2. unpack it, commit it to a throwaway ostree sysroot and
#      `ostree admin deploy` it: the code that writes /usr on a node;
#   3. check_store.sh on the deployed store, with the kernel's overlay.
# Twice: translated, which must pass, and the control (-n), which must fail:
# a test that passes both ways proves nothing.
#
# Needs root, podman, ostree and tar, and network for the Alpine base. Alpine,
# not the RHEL base: nothing here needs RHEL, and the step runs the same.
# Not reproduced: ostree-ext's layer-by-layer import (the image is flattened
# with `podman export` instead) and composefs. Both are node questions.
set -euo pipefail

here=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
repo=$(cd "$here/../.." && pwd)
build_opts=()
keep=0

usage() {
	cat <<EOF
usage: $0 [-b OPT]... [-k]
  -b OPT  extra podman build option, repeatable (e.g. -b --network=host)
  -k      keep the work directory and images
EOF
	exit 2
}

while getopts b:k opt; do
	case $opt in
	b) build_opts+=("$OPTARG") ;;
	k) keep=1 ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))
[[ $# -eq 0 ]] || usage
if [[ $EUID -ne 0 ]]; then
	echo "run as root"
	exit 1
fi
for tool in podman ostree tar; do
	command -v "$tool" >/dev/null || { echo "missing: $tool"; exit 1; }
done

work=$(mktemp -d /var/tmp/ais-local-test.XXXXXX)
cleanup() {
	if (( keep )); then
		echo "kept: $work, localhost/ais-outer:{translated,control}"
		return
	fi
	podman rmi -f localhost/ais-outer:translated localhost/ais-outer:control >/dev/null 2>&1 || true
	# ostree makes every deployment's root immutable, as on a node.
	local d
	for d in "$work"/*/sysroot/ostree/deploy/proof/deploy/*.0; do
		[[ -d $d ]] && chattr -i "$d"
	done
	rm -rf -- "${work:?}"
}
trap cleanup EXIT

cat > "$work/Containerfile" <<'EOF'
FROM docker.io/library/alpine:3.20
RUN apk add --no-cache bash coreutils findutils python3 skopeo >/dev/null
ARG FLAGS=
RUN --mount=type=bind,src=bound-images/ais,dst=/ais \
    --mount=type=cache,id=ais-proof-staging,dst=/var/tmp/ais-staging \
    /ais/build_proof_store.sh $FLAGS /var/tmp/ais-staging /usr/lib/containers/storage-proof
EOF

# The capabilities are podman's defaults; spelled out because a nested
# sandbox may not grant defaults it cannot raise as ambient.
caps=--cap-add=CHOWN,DAC_OVERRIDE,FOWNER,SETFCAP,MKNOD

run_variant() {
	local name=$1 flags=$2 dir=$work/$1
	mkdir -p "$dir/rootfs" "$dir/sysroot"
	echo "===== $name: build"
	podman build -q "${build_opts[@]}" "$caps" --build-arg FLAGS="$flags" \
		-t "localhost/ais-outer:$name" -f "$work/Containerfile" "$repo" >/dev/null

	echo "===== $name: deploy with ostree"
	local ctr
	ctr=$(podman create "localhost/ais-outer:$name" /none)
	podman export "$ctr" | tar -x -C "$dir/rootfs" --numeric-owner \
		--exclude='dev/*' --exclude='proc/*' --exclude='run/*' --exclude='sys/*' --exclude='var/*'
	podman rm -f "$ctr" >/dev/null
	# What ostree needs to deploy a tree: a kernel, and /etc under /usr.
	mkdir -p "$dir/rootfs/usr/lib/modules/0.0.0"
	echo kernel > "$dir/rootfs/usr/lib/modules/0.0.0/vmlinuz"
	echo initramfs > "$dir/rootfs/usr/lib/modules/0.0.0/initramfs.img"
	mv "$dir/rootfs/etc" "$dir/rootfs/usr/etc"
	ostree admin init-fs --modern "$dir/sysroot"
	ostree admin --sysroot="$dir/sysroot" os-init proof >/dev/null
	ostree --repo="$dir/sysroot/ostree/repo" commit -b proof --no-xattrs \
		--tree=dir="$dir/rootfs" >/dev/null
	ostree admin --sysroot="$dir/sysroot" deploy --os=proof proof >/dev/null

	local deployed
	deployed=$(echo "$dir"/sysroot/ostree/deploy/proof/deploy/*.0)
	echo "===== $name: check"
	bash "$here/check_store.sh" -s "$deployed/usr/lib/containers/storage-proof"
}

result=0
if run_variant translated ""; then
	echo ">>> translated: passed, as it must"
else
	echo ">>> translated: FAILED"
	result=1
fi
if run_variant control -n; then
	echo ">>> control: passed, so the check cannot tell lost markers apart: FAILED"
	result=1
else
	echo ">>> control: failed, as it must"
fi
exit $result
