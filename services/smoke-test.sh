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
expect_workloads 050-valkey "StatefulSet/valkey"
expect_workloads 060-mongodb "StatefulSet/mongodb"

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

# Shared by the database roots below (valkey, mongodb): each sets db, its
# directory, and dbr, its render, first. Every failure lists the root.
dbfail() { fail "$@" "-- $db:" "$(ls -la "$db" 2>&1)"; }
# Mounts, by volume: what the pod spec says is mounted at a directory, in the
# main container (c) or the init container (i).
vol_at() {
	jq -c --arg which "$1" --arg d "$2" "$W"' workloads | podspec | . as $s
		| (if $which == "i" then .initContainers // [] else .containers end)[]
		| .volumeMounts[]? | select(.mountPath == $d) | . as $m
		| $s.volumes[] | select(.name == $m.name) | . + {readOnly: ($m.readOnly == true)}' "$dbr"
}
# generated_once <user> <Secret>: the user's password is made on the node,
# from a Password generator in the render, by an ExternalSecret that writes it
# once and does not own it. Prints itself: called in $(...), a failure would be
# lost.
generated_once() {
	local user=$1 sec=$2 es gen g
	es=$(jq -c --arg n "$sec" '.[] | select(.kind == "ExternalSecret" and .spec.target.name == $n)' "$dbr")
	[[ $(jq -r .spec.refreshPolicy <<<"$es") == CreatedOnce ]] \
		|| dbfail "Secret $sec is not from an ExternalSecret with refreshPolicy CreatedOnce" \
			"(anything else regenerates the password):" "${es:-none}"
	# Owner would cascade-delete the password with its ExternalSecret, and a
	# renamed one in a later image would generate a new password.
	[[ $(jq -r .spec.target.creationPolicy <<<"$es") == Orphan ]] \
		|| dbfail "ExternalSecret for $sec must say creationPolicy: Orphan:" "$es"
	gen=$(jq -r '.spec.dataFrom[0].sourceRef.generatorRef | "\(.kind)/\(.name)"' <<<"$es")
	g=$(jq -c --arg n "${gen#*/}" '.[] | select(.kind == "Password" and .metadata.name == $n)' "$dbr")
	[[ $gen == Password/* && -n $g ]] || dbfail "Secret $sec is not generated by a Password generator in the render: $gen"
	# Without repeats a 64-character password asks for 16 distinct digits, and
	# the generator fails: the Secret never appears and the pod never starts.
	[[ $(jq -r '.spec.length // 24' <<<"$g") -ge 32 && $(jq -r .spec.allowRepeat <<<"$g") == true ]] \
		|| dbfail "Password generator $gen needs length >= 32 and allowRepeat: true:" "$g"
	echo "   $user: Secret $sec, generated once by $gen"
}
# distribution_guarded <root's Secret>: the client copy reaches labelled
# namespaces only, and nothing in the render can read root's password.
distribution_guarded() {
	local rootsec=$1 wide outside ces store sel cond
	# A Role that reaches root's Secret, or every Secret, would let a client
	# read root.
	wide=$(jq -r --arg r "$rootsec" '.[] | select(.kind == "Role" or .kind == "ClusterRole")
		| .metadata.name as $n | .rules[]? | select(any(.resources[]?; . == "secrets" or . == "*"))
		| select((.resourceNames // []) == [] or any(.resourceNames[]; . == $r)) | $n' "$dbr")
	[[ -z $wide ]] || dbfail "these Roles reach root's Secret $rootsec or every Secret:" $wide
	# That check sees only roles in the render: a binding to one outside it
	# (admin, edit, any ClusterRole on the node) could read every Secret here
	# unseen.
	outside=$(jq -r '[.[] | select(.kind == "Role" or .kind == "ClusterRole")
		| "\(.kind)/\(.metadata.name)"] as $have | .[]
		| select(.kind == "RoleBinding" or .kind == "ClusterRoleBinding")
		| select("\(.roleRef.kind)/\(.roleRef.name)" as $r | $have | index($r) | not)
		| "\(.kind)/\(.metadata.name) -> \(.roleRef.kind)/\(.roleRef.name)"' "$dbr")
	[[ -z $outside ]] || dbfail "these bindings name a role outside the render, whose rules this check cannot see:" "$outside"
	while read -r ces; do
		store=$(jq -r '.spec.externalSecretSpec.secretStoreRef | "\(.kind)/\(.name)"' <<<"$ces")
		sel=$(jq -c '.spec.namespaceSelectors' <<<"$ces")
		cond=$(jq -c --arg n "${store#*/}" '[.[] | select(.kind == "ClusterSecretStore" and .metadata.name == $n)
			| .spec.conditions[]?.namespaceSelector]' "$dbr")
		[[ $sel != '[{}]' && $sel != null && $sel == "$cond" ]] \
			|| dbfail "ClusterExternalSecret $(jq -r .metadata.name <<<"$ces") selects namespaces $sel," \
				"but its store $store is limited to $cond: any namespace could name the store"
		echo "   $(jq -r .metadata.name <<<"$ces"): to namespaces $sel only, its store limited alike"
	done < <(jq -c '.[] | select(.kind == "ClusterExternalSecret")' "$dbr")
}
headless_governed() {
	local headless
	# A StatefulSet's pod name resolves only through a headless governing Service.
	headless=$(jq -r "$W"' (workloads | .spec.serviceName) as $n
		| .[] | select(.kind == "Service" and .metadata.name == $n) | .spec.clusterIP' "$dbr")
	[[ $headless == None ]] || dbfail "the StatefulSet's serviceName is not a headless Service in the render"
	echo "   headless governing Service"
}

echo "== valkey =="
# Valkey ships with a passwordless default user, and the pod is reachable from
# every other pod. users.acl is a template: the init container writes it with
# the SHA-256s of passwords ESO generates on the node. Checked here because a
# wrong ACL, password or TLS wiring does not fail the build: the pod crash-loops
# or waits on a node nobody can ssh into, or, worse, starts open, or a password
# reaches a namespace it should not. Every failure lists the root.
db=/usr/lib/microshift/manifests.d/050-valkey
acl=$db/users.acl
conf=$db/valkey.conf
dbr=$render/050-valkey.json
[[ -s $acl ]] || dbfail "missing or empty: $acl"
# Valkey trims each line and reads every one as a user, so a line the greps
# below cannot see (leading blanks, say) would still be a user.
odd=$(grep -v '^user [^ ]' "$acl" | grep -v '^$' || true)
[[ -z $odd ]] || dbfail "$acl has lines that do not start with 'user <name>':" "$odd"
# Valkey makes the default user itself when the file does not mention it, and
# that one is on, nopass and allowed everything: an unauthenticated write works.
grep -qx 'user default off -@all' "$acl" \
	|| dbfail "$acl has no 'user default off -@all' line; without it Valkey keeps its" \
		"built-in default user, which needs no password and can run anything"
echo "   default user: off"
# The probe user exists so the pod can be checked with the default user off.
# The whole line, not its tokens: ACL aliases (allcommands, allkeys), %RW~ key
# patterns and (...) selectors would all grant more than PING.
grep -qx 'user probe on nopass -@all +ping' "$acl" \
	|| dbfail "the probe user must read exactly 'user probe on nopass -@all +ping'," \
		"which the readiness and liveness probes log in as; it reads:" \
		"$(grep '^user probe ' "$acl" || echo nothing)"
nopass=$(grep -E '(^| )nopass( |$)' "$acl" | grep -v '^user probe ' || true)
[[ -z $nopass ]] || dbfail "a user other than probe has no password:" "$nopass"
echo "   probe user: PING only"
# Token by token: a > token is a plaintext password, in git and in every
# registry; a # token other than the user's own placeholder is a hash that
# belongs on the node, or another user's password. read -a, not a for over
# $rules, which would glob ~* and &*.
users=()
while read -r _ name rules; do
	[[ $name == default || $name == probe ]] && continue
	ph="#@VALKEY_${name^^}_PASSWORD_SHA256@"
	read -ra toks <<<"$rules"
	own=0
	for t in "${toks[@]}"; do
		case $t in
		'>'*) dbfail "valkey user $name in $acl has a plaintext > password; it takes $ph only" ;;
		"$ph") own=1 ;;
		'#'*) dbfail "valkey user $name in $acl has the hash or placeholder '$t'; it takes $ph only" ;;
		esac
	done
	(( own == 1 )) || dbfail "valkey user $name in $acl has no $ph password"
	users+=("$name")
done < <(grep '^user ' "$acl")
for want in root app; do
	[[ " ${users[*]} " == *" $want "* ]] || dbfail "$acl has no $want user"
done
echo "   users ${users[*]}: password placeholders"
# The conf and the pod spec are separate files that have to agree. Valkey
# refuses to start with user lines in the conf next to an aclfile.
conf_val() { awk -v k="$1" '$1 == k { print $2 }' "$conf"; }
aclpath=$(conf_val aclfile)
acldir=$(dirname "$aclpath")
[[ $aclpath == */users.acl ]] \
	|| dbfail "valkey.conf must say aclfile <dir>/users.acl, got: ${aclpath:-nothing}"
! grep -Eq '^user ' "$conf" || dbfail "valkey.conf has user lines next to an aclfile; Valkey refuses to start"
! grep -Eq '^protected-mode[[:space:]]+no' "$conf" \
	|| dbfail "valkey.conf turns protected-mode off, which is the net under the ACL"
# TLS only: a plaintext port would carry every password in the clear.
[[ $(conf_val port) == 0 && -n $(conf_val tls-port) ]] \
	|| dbfail "valkey.conf must say port 0 and a tls-port, got port '$(conf_val port)'" \
		"tls-port '$(conf_val tls-port)'"
tlsdir=$(dirname "$(conf_val tls-cert-file)")
for k in tls-cert-file tls-key-file tls-ca-cert-file; do
	[[ $(conf_val $k) == "$tlsdir"/* ]] \
		|| dbfail "valkey.conf's $k '$(conf_val $k)' is not in $tlsdir with tls-cert-file"
done
# cert-manager renews the certificate in place; without a reload interval
# Valkey serves the old one until it expires.
[[ $(conf_val tls-auto-reload-interval) =~ ^[1-9][0-9]*$ ]] \
	|| dbfail "valkey.conf has no tls-auto-reload-interval above 0"
echo "   TLS only, files in $tlsdir, reloaded"
# The ACL is written by the init container into memory, and read there.
[[ $(vol_at c "$acldir" | jq -r '.emptyDir.medium // empty') == Memory ]] \
	|| dbfail "Valkey does not read $aclpath from a memory emptyDir:" "$(vol_at c "$acldir")"
[[ $(vol_at i "$acldir" | jq -r 'select(.readOnly | not) | .emptyDir.medium // empty') == Memory ]] \
	|| dbfail "no init container writes the memory emptyDir at $acldir"
init=$(jq -r "$W"' workloads | podspec | .initContainers[]? | .command | join(" ")' "$dbr")
[[ $init == *render-acl.sh* ]] || dbfail "the init container does not run render-acl.sh:" "$init"
script=$db/render-acl.sh
sh -n "$script" || dbfail "$script does not parse"
# Each placeholder user's password: a file named after it in the init
# container (render-acl.sh fills one placeholder per file), from a Secret an
# ExternalSecret generates once, from a Password generator, here in the render.
pwdir=$(jq -r "$W"' workloads | podspec | . as $s | .initContainers[]? | .volumeMounts[]?
	| . as $m | select(any($s.volumes[]; .name == $m.name and .projected != null))
	| .mountPath' "$dbr")
[[ $(wc -w <<<"$pwdir") == 1 ]] || dbfail "the init container must mount one projected volume of passwords, got: ${pwdir:-none}"
paths=$(vol_at i "$pwdir" | jq -r '.projected.sources[]?.secret.items[]?.path' | sort | tr '\n' ' ')
[[ $paths == "$(printf '%s\n' "${users[@]}" | sort | tr '\n' ' ')" ]] \
	|| dbfail "the password files in $pwdir ($paths) are not the template's users (${users[*]})"
for u in "${users[@]}"; do
	sec=$(vol_at i "$pwdir" | jq -r --arg u "$u" '.projected.sources[]?.secret
		| select(.items[]?.path == $u) | .name')
	[[ -n $sec ]] || dbfail "no Secret is projected as $pwdir/$u for the init container"
	generated_once "$u" "$sec"
done
rootsec=$(vol_at i "$pwdir" | jq -r '.projected.sources[]?.secret | select(.items[]?.path == "root") | .name')
distribution_guarded "$rootsec"
tlssec=$(vol_at c "$tlsdir" | jq -r '.secret.secretName // empty')
[[ -n $tlssec ]] || dbfail "no Secret volume is mounted at $tlsdir, where valkey.conf looks for its certificate"
issuer=$(jq -r --arg n "$tlssec" '.[] | select(.kind == "Certificate" and .spec.secretName == $n)
	| "\(.spec.issuerRef.kind)/\(.spec.issuerRef.name)"' "$dbr")
[[ $issuer == ClusterIssuer/device-ca ]] \
	|| dbfail "Secret $tlssec, mounted at $tlsdir, is not from a Certificate issued by ClusterIssuer/device-ca:" "${issuer:-no Certificate}"
missing=$(jq -r --arg n "$tlssec" '(.[] | select(.kind == "Certificate" and .spec.secretName == $n)
	| .spec.dnsNames) as $d | .[] | select(.kind == "Service")
	| "\(.metadata.name).\(.metadata.namespace).svc.cluster.local"
	| select(. as $f | $d | index($f) | not)' "$dbr")
[[ -z $missing ]] || dbfail "the valkey Certificate does not name:" $missing
echo "   certificate: Secret $tlssec from ClusterIssuer/device-ca, every Service named"
headless_governed

echo "== mongodb =="
# One standalone mongod from Percona's image, whose entrypoint creates root
# from MONGO_INITDB_ROOT_* and runs /docker-entrypoint-initdb.d (app) once, on
# an empty /data/db. Checked here because none of this fails the build: without
# --auth any pod reads and writes everything, and a wrong mount or variable
# starts the server with no users, which on a node nobody can ssh into is a
# database no client can log in to, for good.
db=/usr/lib/microshift/manifests.d/060-mongodb
dbr=$render/060-mongodb.json
mc=$(jq -c "$W"' workloads | podspec | .containers[] | select(.name == "mongodb")' "$dbr")
[[ -n $mc ]] || dbfail "the StatefulSet has no container named mongodb"
# A command replaces the image entrypoint, and with it every user it makes.
[[ $(jq -r .command <<<"$mc") == null ]] \
	|| dbfail "the mongodb container sets command, which skips the image entrypoint" \
		"that creates the users: $(jq -c .command <<<"$mc")"
jq -e '.args[0] == "mongod" and any(.args[]; . == "--auth")' <<<"$mc" >/dev/null \
	|| dbfail "the mongodb container must run mongod with --auth, got: $(jq -c .args <<<"$mc")"
echo "   mongod --auth, through the image entrypoint"
env_val() { jq -r --arg n "$1" '[.env[]? | select(.name == $n)] | if . == [] then "" else .[0].value // "(from a source)" end' <<<"$mc"; }
# Any other value is the agent phoning out; the entrypoint tests it as a
# non-zero integer, so "true" counts as 0.
[[ $(env_val PERCONA_TELEMETRY_DISABLE) =~ ^[1-9][0-9]*$ ]] \
	|| dbfail "PERCONA_TELEMETRY_DISABLE is '$(env_val PERCONA_TELEMETRY_DISABLE)'," \
		"want a non-zero integer; anything else starts Percona's telemetry agent"
echo "   telemetry off"
# A password set as a plain value would be in git and every registry.
plain=$(jq -r '.env[]? | select((.name | test("PASS"; "i")) and .value != null and (.name | endswith("_FILE") | not)) | .name' <<<"$mc")
[[ -z $plain ]] || dbfail "the mongodb container takes a password as a value, not a file:" $plain
[[ $(env_val MONGO_INITDB_ROOT_USERNAME) == root ]] \
	|| dbfail "MONGO_INITDB_ROOT_USERNAME is '$(env_val MONGO_INITDB_ROOT_USERNAME)', want root"
rootfile=$(env_val MONGO_INITDB_ROOT_PASSWORD_FILE)
pwdir=$(dirname "$rootfile")
[[ $(vol_at c "$pwdir" | jq -r '.projected != null') == true ]] \
	|| dbfail "MONGO_INITDB_ROOT_PASSWORD_FILE '$rootfile' is not in a projected volume of passwords"
initdb=$(vol_at c /docker-entrypoint-initdb.d | jq -r '.configMap.name // empty')
[[ -n $initdb ]] || dbfail "no ConfigMap is mounted at /docker-entrypoint-initdb.d; app would never be created"
scripts=$(jq -r --arg n "$initdb" '.[] | select(.kind == "ConfigMap" and .metadata.name == $n)
	| .data | to_entries[] | select(.key | test("\\.(js|sh)$")) | .value' "$dbr")
# Every projected file is a user's password: root's the entrypoint reads, the
# others an init script must read, or the Secret is generated and never used.
users=()
for u in $(vol_at c "$pwdir" | jq -r '.projected.sources[]?.secret.items[]?.path'); do
	if [[ $pwdir/$u != "$rootfile" ]]; then
		grep -qF "$pwdir/$u" <<<"$scripts" \
			|| dbfail "$pwdir/$u is projected, but no script in ConfigMap $initdb reads it"
	fi
	sec=$(vol_at c "$pwdir" | jq -r --arg u "$u" '.projected.sources[]?.secret
		| select(.items[]?.path == $u) | .name')
	generated_once "$u" "$sec"
	users+=("$u")
done
for want in root app; do
	[[ " ${users[*]} " == *" $want "* ]] || dbfail "no password file for mongodb user $want in $pwdir"
done
rootsec=$(vol_at c "$pwdir" | jq -r --arg r "${rootfile##*/}" '.projected.sources[]?.secret
	| select(.items[]?.path == $r) | .name')
distribution_guarded "$rootsec"
headless_governed

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
