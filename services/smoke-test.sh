#!/bin/bash
# Checks run inside the services image before it is pushed. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < services/smoke-test.sh
#
# What matters here is that the manifests still say what they were patched to
# say. MicroShift renders these roots itself at start-up, so a root that does
# not render is a component that is silently never applied, on a node nobody
# can ssh into. The layers below were checked by their own tests, and a curl or
# COPY that failed would have failed the build.
set -euo pipefail

fail() { echo "$*"; exit 1; }
cache=/usr/lib/containers-image-cache
not_embedded() {
	echo "$*"
	echo "-- $cache/mapping.txt"
	sed 's/^/   /' "$cache/mapping.txt"
	exit 1
}

echo "== renders =="
# oc's kustomize is the closest thing in the image to the one MicroShift links
# into its own binary. It is also older than the standalone tool, which is why
# no patch file here holds more than one document. `oc patch --local` with an
# empty patch never contacts a server; it parses the render and prints it back
# as JSON, which jq can then query.
render=$(mktemp -d)
roots=(/usr/lib/microshift/manifests.d/*/)
for root in "${roots[@]}"; do
	name=$(basename "$root")
	oc kustomize "$root" | oc patch --local -f - --type=merge -p '{}' -o json |
		jq -s . > "$render/$name.json" || fail "does not render: $root"
	echo "   $name: $(jq length "$render/$name.json") objects"
done

# Prefixed to the jq programs below: every object in a render that makes pods,
# and the pod spec inside it, wherever its kind keeps one. `pods` adds serving
# runtimes, whose containers become every predictor pod.
W='def workloads:
	.[] | select(.kind | test("^(Deployment|DaemonSet|StatefulSet|Job|CronJob|Pod)$"));
def podspec:
	if .kind == "Pod" then .spec
	elif .kind == "CronJob" then .spec.jobTemplate.spec.template.spec
	else .spec.template.spec end;
def runtimes: .[] | select(.kind | test("^(Cluster)?ServingRuntime$"));
def pods: (workloads | {o: "\(.kind)/\(.metadata.name)", s: podspec}),
	(runtimes | {o: "\(.kind)/\(.metadata.name)", s: .spec});'

echo "== workloads =="
# kustomize fails the build on a patch that matches nothing, so a rename
# upstream cannot slip through silently — but a workload upstream *adds* can,
# and it would arrive with no resources and possibly a pinned UID. Name the set
# each root may contain; anything else has to be looked at before it ships.
expect_workloads() {
	name=$1 want=$2
	got=$(jq -r "$W"' workloads | "\(.kind)/\(.metadata.name)"' "$render/$name.json" | sort)
	if [[ $got != "$want" ]]; then
		echo "unexpected workloads in the $name render:"
		echo "$got" | sed 's/^/   /'
		echo "expected:"
		echo "$want" | sed 's/^/   /'
		exit 1
	fi
	echo "   $name: $(wc -l <<< "$got") workloads, as expected"
}
expect_workloads 010-cert-manager \
"Deployment/cert-manager
Deployment/cert-manager-cainjector
Deployment/cert-manager-webhook"
expect_workloads 020-external-secrets \
"Deployment/external-secrets
Deployment/external-secrets-cert-controller
Deployment/external-secrets-webhook"
expect_workloads 030-kserve "Deployment/kserve-controller-manager"

eso=$render/020-external-secrets.json

echo "== external secrets is out of the default namespace =="
# Checked on the render, not the patches: which fields the namespace
# transformer reaches depends on the kustomize version, and one it misses is a
# silent no-op.
jq -e 'any(.[]; .kind == "Namespace" and .metadata.name == "external-secrets-operator")' \
	"$eso" >/dev/null \
	|| fail "the render creates no external-secrets-operator namespace;" \
		"nothing else in the root can be applied without it"
echo "   Namespace/external-secrets-operator is in the render"
# Every string value outside the CRDs, whose schemas are full of the word:
# metadata, a subject, a webhook clientConfig, a service DNS name inside an
# argument. Case-sensitive, so RuntimeDefault is not a false alarm.
stale=$(jq -r '.[] | select(.kind != "CustomResourceDefinition")
	| "\(.kind)/\(.metadata.name)" as $obj
	| paths(strings) as $p | getpath($p) | select(test("default"))
	| "\($obj) \($p | map(tostring) | join(".")): \(.)"' "$eso")
if [[ -n $stale ]]; then
	echo "the render still points at the default namespace:"
	echo "$stale" | sed 's/^/   /'
	exit 1
fi
echo "   nothing outside the CRDs names the default namespace"

echo "== external secrets runs as an SCC-assigned uid =="
# Upstream pins runAsUser: 1000 on all three. restricted-v2 assigns a UID out
# of the namespace's openshift.io/sa.scc.uid-range instead and rejects a pod
# that names its own, so the Deployments would be admitted and every pod they
# create refused. The patches delete the field with an explicit null, which is
# invisible in the patch file if it stops matching — kustomize would fail the
# build on that, but not on upstream adding the field somewhere new, so every
# object is searched, not only the workloads named above. CRDs are skipped:
# their schemas describe the field without setting it.
pinned=$(jq -r '.[] | select(.kind != "CustomResourceDefinition")
	| select([.. | objects | has("runAsUser")] | any)
	| "\(.kind)/\(.metadata.name)"' "$eso")
[[ -z $pinned ]] || fail "still pins a UID, which restricted-v2 will refuse:" $pinned
echo "   no runAsUser in the render"
# Deleting runAsUser must not have taken runAsNonRoot with it: without it the
# SCC is the only thing between this and a root container. Per container,
# falling back to the pod only where the container does not set it at all, the
# way the kubelet reads it. Not jq's `//`: it treats an explicit false as unset
# and would take the pod's true over it.
rootable=$(jq -r "$W"' workloads | .metadata.name as $w | podspec
	| .securityContext.runAsNonRoot as $pod
	| (.containers + (.initContainers // []))[]
	| select((if .securityContext.runAsNonRoot == null then $pod
		else .securityContext.runAsNonRoot end) != true)
	| "\($w)/\(.name)"' "$eso")
[[ -z $rootable ]] || fail "runAsNonRoot is not true on:" $rootable
echo "   runAsNonRoot: true on every container"

echo "== kserve configuration =="
ksv=$render/030-kserve.json
# One JSON string per key. Read per key: upstream's _example key mentions every
# setting in comments.
isvc_config() {
	jq -er --arg k "$1" '.[] | select(.kind == "ConfigMap"
		and .metadata.name == "inferenceservice-config") | .data[$k] | fromjson' "$ksv"
}
expect_config() {
	key=$1 test=$2 why=$3
	isvc_config "$key" | jq -e "$test" >/dev/null \
		|| fail "inferenceservice-config $key: $test does not hold; $why"
	echo "   $key: $test"
}
expect_config deploy '.defaultDeploymentMode == "Standard"' \
	"anything else needs Knative and Istio, neither of which is installed"
expect_config ingress '.disableIngressCreation == true' \
	"an Ingress per InferenceService would name a host nothing here resolves"
expect_config storageInitializer 'has("uidModelcar") | not' \
	"restricted-v2 refuses every pod a pinned uidModelcar lands on"
# Named only in this JSON string, which the image scan cannot see.
si_image=$(isvc_config storageInitializer | jq -r .image)
[[ $si_image == docker.io/kserve/storage-initializer:* ]] \
	|| fail "storageInitializer image is $si_image," \
		"want docker.io/kserve/storage-initializer:<tag>"
echo "   storageInitializer image: $si_image"
# For one upstream adds under another name; a renamed one fails the delete.
csc=$(jq -r '.[] | select(.kind == "ClusterStorageContainer") | .metadata.name' "$ksv")
[[ -z $csc ]] || fail "the kserve render carries a ClusterStorageContainer:" $csc
echo "   no ClusterStorageContainer"

echo "== restricted-v2 =="
# Every pod template and serving runtime container, checked for what the SCC
# requires rather than left for it to default, so a broken patch fails the
# build instead of a pod. Pods KServe builds at run time are in no render.
# The pod fallback tests for null, not //, as for runAsNonRoot above.
for root in "${roots[@]}"; do
	name=$(basename "$root")
	out=$(jq -r "$W"'
		def either($c; $p): if $c == null then $p else $c end;
		pods | .o as $o | .s as $s | ($s.securityContext // {}) as $p
		| (if [$p.runAsUser, $p.runAsGroup, $p.fsGroup] | any(. != null)
			then "\($o): the pod pins a UID, GID or fsGroup" else empty end),
		  (if [$s.hostNetwork, $s.hostPID, $s.hostIPC] | any(. == true)
			then "\($o): shares a host namespace" else empty end),
		  (if any($s.volumes[]?; .hostPath != null)
			then "\($o): mounts a hostPath" else empty end),
		  (($s.containers + ($s.initContainers // []))[]
			| "\($o)/\(.name)" as $c | (.securityContext // {}) as $x
			| (if [$x.runAsUser, $x.runAsGroup] | any(. != null)
				then "\($c): pins a UID or GID" else empty end),
			  (if $x.privileged == true then "\($c): privileged" else empty end),
			  (if $x.allowPrivilegeEscalation != false
				then "\($c): allowPrivilegeEscalation is not false" else empty end),
			  (if any($x.capabilities.drop[]?; . == "ALL") | not
				then "\($c): capabilities do not drop ALL" else empty end),
			  (if ($x.capabilities.add // []) != []
				then "\($c): adds capabilities" else empty end),
			  (if either($x.runAsNonRoot; $p.runAsNonRoot) != true
				then "\($c): runAsNonRoot is not true, on it or on the pod" else empty end),
			  (if either($x.seccompProfile.type; $p.seccompProfile.type) != "RuntimeDefault"
				then "\($c): seccompProfile is not RuntimeDefault, on it or on the pod"
				else empty end))' "$render/$name.json")
	[[ -z $out ]] || fail "$(sed "s|^|$name: |" <<<"$out")"
	n=$(jq "[$W"' pods | .s | (.containers + (.initContainers // []))[]] | length' \
		"$render/$name.json")
	echo "   $name: $n containers, all admissible"
done

echo "== requests and limits =="
# Upstream ships almost none of these, so every pod would be BestEffort and the
# first thing evicted under pressure. The ratios are the house rule: memory
# request equals limit, CPU limit is four times the request. Checked by
# arithmetic rather than by grepping the numbers, so editing a patch cannot
# quietly break the ratio, and a container upstream adds without resources at
# all is caught as well.
for root in "${roots[@]}"; do
	name=$(basename "$root")
	out=$(jq -r "$W"'
		def cpu: tostring | if endswith("m") then .[:-1] | tonumber else tonumber * 1000 end;
		pods | .o as $w
		| (.s | .containers + (.initContainers // []))[]
		| .resources as $r | "\($w)/\(.name): " +
		if [$r.requests.cpu, $r.limits.cpu, $r.requests.memory, $r.limits.memory]
			| any(. == null) then
			"is missing a cpu or memory request or limit"
		elif ($r.requests.memory | tostring) != ($r.limits.memory | tostring) then
			"memory \($r.requests.memory) -> \($r.limits.memory), want request == limit"
		elif ($r.limits.cpu | cpu) != 4 * ($r.requests.cpu | cpu) then
			"cpu \($r.requests.cpu) -> \($r.limits.cpu), want limit == 4x request"
		else "ok" end' "$render/$name.json")
	# A root of plain objects, a SecretStore say, has nothing to size.
	if [[ -z $out ]]; then
		echo "   $name: no workloads"
		continue
	fi
	if grep -v ': ok$' <<<"$out" | sed "s|^|$name: |" | grep .; then
		exit 1
	fi
	echo "   $name: $(wc -l <<<"$out") containers, memory 1:1, cpu 1:4"
done

echo "== pull policy =="
# Always makes the kubelet ask the registry even with the image already in
# containers-storage, which on a node with no network is ErrImagePull with the
# image sitting right there. KServe's manager shipped that way. Unset, the API
# server defaults to Always for a :latest or untagged reference, IfNotPresent
# for anything else, a digest included; the check applies the same rule.
for root in "${roots[@]}"; do
	name=$(basename "$root")
	out=$(jq -r "$W"'
		pods | .o as $o | (.s | .containers + (.initContainers // []))[]
		| (.imagePullPolicy // (if (.image | split("/") | last | test("[:@]") | not)
			or (.image | endswith(":latest")) then "Always (defaulted)"
			else "IfNotPresent" end)) as $p
		| select($p | test("^(IfNotPresent|Never)$") | not)
		| "\($o)/\(.name): \(.image) pulls \($p)"' "$render/$name.json")
	[[ -z $out ]] || fail "$(sed "s|^|$name: |" <<<"$out")"
	echo "   $name: no container pulls Always"
done

echo "== images the manifests name =="
# A manifest naming an image that was not embedded means ImagePullBackOff on a
# node with no registry. Captured first: a scan that fails inside `< <(...)`
# leaves the loop reading nothing and passing.
images=$(/opt/microshift/manifest-images.sh "${roots[@]}") \
	|| fail "/opt/microshift/manifest-images.sh failed"
[[ -n $images ]] || fail "the manifest roots name no images at all"

# embed_image.sh keys the cache on `echo "$ref" | sha256sum`, newline included.
while read -r img; do
	# CRI-O resolves a short name against unqualified-search-registries
	# (registry.access.redhat.com first, docker.io last) rather than looking
	# in the local store first, so an unqualified reference is a pull attempt
	# on a node that has no network. The upstreams qualify their own images
	# today, or an images: transformer does; this is what notices if one stops. With no slash at all there is
	# no host, only a name and its tag.
	host=${img%%/*}
	[[ $img == */* && ( $host == *.* || $host == *:* ) ]] \
		|| fail "unqualified image reference: $img;" \
			"give it a registry host, or the node will try to pull it"
	fsha=$(echo "$img" | sha256sum | awk '{ print $1 }')
	[[ -f $cache/$fsha/manifest.json ]] \
		|| not_embedded "a manifest names $img, which is not embedded;" \
			"the build embeds what this same scan prints, check its log"
	echo "   embedded: $img"
done <<< "$images"

# The ConfigMap's storage initializer is patched by hand and does not move
# with KSERVE_VER.
kserve_tags=$(printf '%s\n%s\n' "$images" "$si_image" |
	sed -n 's|^docker\.io/kserve/[^:]*:\(.*\)$|\1|p' | sort -u)
[[ $(wc -l <<< "$kserve_tags") -eq 1 ]] \
	|| fail "docker.io/kserve images do not share one tag:" $kserve_tags \
		"— bump KSERVE_VER and inferenceservice-config.yaml together"
echo "   docker.io/kserve images all at $kserve_tags"

echo "== embedded images =="
# The whole mapping, not only what the manifests name: SERVICE_IMAGES adds
# images no manifest does, and this is the file copy_embedded_images.sh replays
# at boot. Cumulative — the control plane came from the layer below.
if [[ ! -s $cache/mapping.txt ]]; then
	echo "missing: $cache/mapping.txt"
	ls -la "$cache" 2>&1 | sed 's/^/   /'
	exit 1
fi
while IFS=, read -r img sha; do
	[[ -f $cache/$sha/manifest.json ]] || not_embedded "no manifest.json for $img under $cache/$sha"
done < "$cache/mapping.txt"
# Printed, not asserted: the cache is copied into containers-storage at first
# boot, so every embedded image is paid for twice on a 40 GiB root. The number
# belongs in the log — it is the first thing to look at when a build stops
# fitting.
echo "embedded: $(wc -l < "$cache/mapping.txt") images"
du -sh "$cache"

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
