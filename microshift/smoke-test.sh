#!/bin/bash
# Checks that run inside the built image, before it is pushed. Fed to the
# container on stdin by the build workflow:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < microshift/smoke-test.sh
#
# This proves the image was assembled correctly. It proves nothing about the
# GPU or the cluster — only a boot on real hardware does that. The base image
# was checked by the layers below, and a file the Containerfile COPYs or a
# package it installs fails the build by itself when it is missing, so neither
# is re-checked here.
set -euo pipefail

fail() { echo "$*"; exit 1; }
# missing <what> <path>...: names what it looked for and lists where it should
# have been.
missing() {
	echo "missing: $1"
	shift
	for p in "$@"; do
		echo "-- $p"
		ls -la "$p" 2>&1 | sed 's/^/   /'
	done
	exit 1
}
cache=/usr/lib/containers-image-cache
not_embedded() {
	echo "$*"
	echo "-- $cache/mapping.txt"
	sed 's/^/   /' "$cache/mapping.txt"
	exit 1
}

echo "== units enabled =="
# `systemctl enable` on a unit whose [Install] section is missing or misspelt
# only warns and exits 0, so the build does not notice. make-rshared is written
# in the Containerfile itself, and nothing Requires= it.
wants=/etc/systemd/system/multi-user.target.wants
for unit in microshift microshift-make-rshared; do
	[[ -L $wants/$unit.service ]] || missing "$wants/$unit.service" "$wants"
done

echo "== node ip on lo =="
# Two files in git that must name the same address, and nothing in the build
# compares them. If they disagree, nodeIP is an address no interface carries
# and MicroShift fails to start, or sysconfwatch keeps restarting it.
nm=/usr/lib/NetworkManager/system-connections/stable-microshift.nmconnection
lo=$(sed -n 's|^address1=\([^/,]*\).*|\1|p' "$nm")
node=$(awk '$1 == "nodeIP:" { print $2 }' /etc/microshift/config.d/*.yaml)
[[ -n $lo && $lo == "$node" ]] \
	|| fail "lo carries '$lo' ($nm) but nodeIP is '$node' (/etc/microshift/config.d)"
echo "   nodeIP $node is on lo"

echo "== split dns =="
# dns=dnsmasq and the kubelet resolvConf are separate files; either alone breaks pod DNS.
mode=$(NetworkManager --print-config | awk -F= '$1 == "dns" { print $2 }')
[[ $mode == dnsmasq ]] || fail "NetworkManager dns is '$mode', expected dnsmasq"
rc=$(awk '$1 == "resolvConf:" { print $2 }' /etc/microshift/config.d/*.yaml)
[[ $rc == /run/NetworkManager/no-stub-resolv.conf ]] && grep -qaF "$rc" /usr/sbin/NetworkManager \
	|| fail "kubelet resolvConf '$rc' (/etc/microshift/config.d) is not a file NetworkManager writes"

echo "== nvidia runtime for cri-o =="
# nvidia-ctk renames a .conf drop-in to .toml and still exits 0, so only a check
# spelling the name notices.
f=/etc/crio/crio.conf.d/99-nvidia.toml
[[ -s $f ]] || missing "$f" "${f%/*}"

echo "== gpu time slicing =="
# A patch that stops matching is a no-op in kustomize, not an error, and a
# strategic merge whose list key stops matching is worse: it appends an entry
# instead of merging into upstream one. Both render cleanly here and fail on
# the node, where the kustomizer retries for ten minutes and then gives up in
# one journal line.
#
# So the render is checked for how it is wired, never for which line upstream
# happens to write. The plugin manifest is fetched by tag and upstream renames
# fields between tags - v0.18.0 dropped FAIL_ON_INIT_ERROR, v0.20.0 renamed the
# kubelet socket volume - and none of that is a broken patch. What has to hold:
# one container, CONFIG_FILE pointing into a mount that resolves to the
# replicas ConfigMap, and the kubelet socket directory mounted.
#
# `oc patch --local` with an empty patch never contacts a server; it parses the
# render and prints it back as JSON, which jq can then query.
r=$(oc kustomize /usr/lib/microshift/manifests |
	oc patch --local -f - --type=merge -p '{}' -o json | jq -s .) \
	|| fail "does not render: /usr/lib/microshift/manifests"

# Prefixed to the jq programs below: the device plugin's pod spec.
P='def pod: .[] | select(.kind == "DaemonSet") | .spec.template.spec;'
n=$(jq "$P"' [pod | .containers[]] | length' <<<"$r")
[[ $n == 1 ]] || fail "the pod has $n containers, expected 1: a merge key" \
	"that stopped matching appends one instead of patching upstream"

cfg=$(jq -r "$P"' pod | .containers[0].env[]? | select(.name == "CONFIG_FILE") | .value // empty' <<<"$r")
[[ -n $cfg ]] || fail "no CONFIG_FILE with a literal value in the render:" \
	"the patch never reached the container"

vol=$(jq -r --arg dir "${cfg%/*}" "$P"' pod
	| .containers[0].volumeMounts[]? | select(.mountPath == $dir) | .name' <<<"$r")
[[ -n $vol ]] || fail "CONFIG_FILE is $cfg but no volumeMount covers ${cfg%/*}"

cm=$(jq -r --arg vol "$vol" "$P"' pod
	| .volumes[]? | select(.name == $vol) | .configMap.name // empty' <<<"$r")
[[ -n $cm ]] || fail "the volume mounted at ${cfg%/*} is not a configMap"

# The count printed is the one the plugin will read: the key the mount turns
# into the file CONFIG_FILE names.
conf=$(jq -r --arg cm "$cm" --arg key "${cfg##*/}" '.[]
	| select(.kind == "ConfigMap" and .metadata.name == $cm)
	| .data[$key] // empty' <<<"$r")
[[ -n $conf ]] || fail "configMap $cm is not in the render, or has no ${cfg##*/}"
replicas=$(sed -n 's/^ *replicas: *\([0-9][0-9]*\).*/\1/p' <<<"$conf")
[[ -n $replicas ]] || fail "configMap $cm's ${cfg##*/} names no replica count"
echo "   time-slicing replicas: $replicas"

# On Tegra the uuid strategy hands the runtime "tegra", which its csv mode
# refuses; index hands it "0". The env var would win over the file, so an
# upstream tag that starts setting it must fail here.
grep -Eq '^ *deviceIDStrategy: *index *$' <<<"$conf" \
	|| fail "configMap $cm's ${cfg##*/} does not set deviceIDStrategy: index"
env=$(jq -r "$P"' pod | .containers[0].env[]?
	| select(.name == "DEVICE_ID_STRATEGY") | .value' <<<"$r")
[[ -z $env ]] || fail "the container sets DEVICE_ID_STRATEGY=$env, which" \
	"overrides deviceIDStrategy in $cm"
echo "   device ID strategy: index"

# Upstream ships this one, but it is checked because the plugin cannot register
# with kubelet without it, not to prove a merge merged.
jq -e "$P"' pod | .containers[0].volumeMounts[]?
	| select(.mountPath == "/var/lib/kubelet/device-plugins")' >/dev/null <<<"$r" \
	|| fail "nothing mounts /var/lib/kubelet/device-plugins: the plugin cannot register with kubelet"

echo "== embedded images =="
[[ -s $cache/mapping.txt ]] || missing "$cache/mapping.txt" "$cache"
echo "embedded: $(wc -l < "$cache/mapping.txt") images"
while IFS=, read -r img sha; do
	[[ -f $cache/$sha/manifest.json ]] || not_embedded "no manifest.json for $img under $cache/$sha"
done < "$cache/mapping.txt"

# Whether the images the manifests will ask for are actually in the cache.
# embed_image.sh names the directory after `echo "$ref" | sha256sum`, newline
# and all, so recompute it rather than match the mapping's rewritten name.
# Captured first: a scan that fails inside `< <(...)` leaves the loop reading
# nothing and passing.
echo "== manifest images =="
images=$(/opt/microshift/manifest-images.sh \
	/usr/lib/microshift/manifests /usr/lib/microshift/manifests.d/*/ \
	/etc/microshift/manifests /etc/microshift/manifests.d/*/) \
	|| fail "/opt/microshift/manifest-images.sh failed"
[[ -n $images ]] || fail "the manifest roots name no images at all; the device plugin's should be there"
while read -r img; do
	fsha=$(echo "$img" | sha256sum | awk '{ print $1 }')
	[[ -f $cache/$fsha/manifest.json ]] || not_embedded "manifest image was not embedded: $img"
	echo "   embedded: $img"
done <<<"$images"

echo "== embedded images pinned =="
# From `crio config`, the merged drop-ins: catches a list replaced by a later
# drop-in, a registry missing from it, and an upstream that moved registry.
cfg=$(crio config) || fail "crio config failed; its stderr is above"
mapfile -t pins < <(sed -n '/^[[:space:]]*pinned_images = \[/,/^[[:space:]]*\]/s/^[[:space:]]*"\(.*\)",$/\1/p' <<<"$cfg")
(( ${#pins[@]} )) || fail "crio config pins no images:" \
	"$(grep -n -A8 'pinned_images' <<<"$cfg")"
# CRI-O's three pattern forms: *keyword*, prefix* and exact.
pinned() {
	local p
	for p in "${pins[@]}"; do
		case $p in
		\**\*) [[ $1 == *"${p:1:${#p}-2}"* ]] ;;
		*\*) [[ $1 == "${p%\*}"* ]] ;;
		*) [[ $1 == "$p" ]] ;;
		esac && return 0
	done
	return 1
}
unpinned=()
while IFS=, read -r img sha; do
	pinned "$img" || unpinned+=("$img")
done < "$cache/mapping.txt"
(( ${#unpinned[@]} == 0 )) || fail "embedded but not pinned by crio config" \
	"(${pins[*]}), so kubelet may delete them: ${unpinned[*]}"
echo "   pinned: ${pins[*]}"

echo "all checks passed"
