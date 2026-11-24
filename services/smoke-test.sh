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
expect_workloads 060-postgresql "StatefulSet/postgresql"

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

# Shared by the two stateful services below, Valkey and PostgreSQL, which are
# built alike: one StatefulSet pod behind a headless Service, a certificate
# from the device CA, passwords ESO generates on the node, the application
# user's sent to labelled namespaces. Each section sets sroot (its root) and sr
# (its render); every failure lists the root.
sfail() { fail "$@" "-- $sroot:" "$(ls -la "$sroot" 2>&1)"; }
# Mounts, by volume: what the pod spec says is mounted at a directory, in the
# main containers (c) or the init containers (i), or only the one named.
# Usage: vol_at <c|i> <dir> [container]
vol_at() {
	jq -c --arg which "$1" --arg d "$2" --arg n "${3:-}" "$W"' workloads | podspec | . as $s
		| (if $which == "i" then .initContainers // [] else .containers end)[]
		| select($n == "" or .name == $n)
		| .volumeMounts[]? | select(.mountPath == $d) | . as $m
		| $s.volumes[] | select(.name == $m.name) | . + {readOnly: ($m.readOnly == true)}' "$sr"
}
# Sets pwdir, where the init container reads the passwords: its one projected
# volume, one file per user, named after the user. Not printed: a failure
# inside $(...) would lose its message.
password_dir() {
	local d
	d=$(jq -r "$W"' workloads | podspec | . as $s | .initContainers[]? | .volumeMounts[]?
		| . as $m | select(any($s.volumes[]; .name == $m.name and .projected != null))
		| .mountPath' "$sr")
	[[ $(wc -w <<<"$d") == 1 ]] \
		|| sfail "the init container must mount one projected volume of passwords, got: ${d:-none}"
	pwdir=$d
}
# The Secret projected as <dir>/<user> into the init container.
password_secret() {
	vol_at i "$1" | jq -r --arg u "$2" '.projected.sources[]?.secret | select(.items[]?.path == $u) | .name'
}
# Each user's password, from a Secret an ExternalSecret generates once from a
# Password generator, here in the render.
# Usage: passwords_generated <dir> <user>...
passwords_generated() {
	local dir=$1 u sec es gen g
	shift
	for u in "$@"; do
		sec=$(password_secret "$dir" "$u")
		[[ -n $sec ]] || sfail "no Secret is projected as $dir/$u for the init container"
		es=$(jq -c --arg n "$sec" '.[] | select(.kind == "ExternalSecret" and .spec.target.name == $n)' "$sr")
		[[ $(jq -r .spec.refreshPolicy <<<"$es") == CreatedOnce ]] \
			|| sfail "Secret $sec is not from an ExternalSecret with refreshPolicy CreatedOnce" \
				"(anything else regenerates the password):" "${es:-none}"
		# Owner would cascade-delete the password with its ExternalSecret, and
		# a renamed one in a later image would generate a new password.
		[[ $(jq -r .spec.target.creationPolicy <<<"$es") == Orphan ]] \
			|| sfail "ExternalSecret for $sec must say creationPolicy: Orphan:" "$es"
		gen=$(jq -r '.spec.dataFrom[0].sourceRef.generatorRef | "\(.kind)/\(.name)"' <<<"$es")
		g=$(jq -c --arg n "${gen#*/}" '.[] | select(.kind == "Password" and .metadata.name == $n)' "$sr")
		[[ $gen == Password/* && -n $g ]] || sfail "Secret $sec is not generated by a Password generator in the render: $gen"
		# Without repeats a 64-character password asks for 16 distinct digits,
		# and the generator fails: the Secret never appears, the pod never starts.
		[[ $(jq -r '.spec.length // 24' <<<"$g") -ge 32 && $(jq -r .spec.allowRepeat <<<"$g") == true ]] \
			|| sfail "Password generator $gen needs length >= 32 and allowRepeat: true:" "$g"
		echo "   $u: Secret $sec, generated once by $gen"
	done
}
# Distribution: the application user's password only, into labelled
# namespaces only. A Role that reaches the superuser's Secret, or every Secret,
# would let a client read it.
# Usage: distribution_limited <superuser's Secret>
distribution_limited() {
	local wide outside ces store sel cond
	wide=$(jq -r --arg r "$1" '.[] | select(.kind == "Role" or .kind == "ClusterRole")
		| .metadata.name as $n | .rules[]? | select(any(.resources[]?; . == "secrets" or . == "*"))
		| select((.resourceNames // []) == [] or any(.resourceNames[]; . == $r)) | $n' "$sr")
	[[ -z $wide ]] || sfail "these Roles reach the superuser's Secret $1 or every Secret:" $wide
	# That sees only roles in the render: a binding to one outside it (admin,
	# edit, any ClusterRole on the node) could read every Secret here unseen.
	outside=$(jq -r '[.[] | select(.kind == "Role" or .kind == "ClusterRole")
		| "\(.kind)/\(.metadata.name)"] as $have | .[]
		| select(.kind == "RoleBinding" or .kind == "ClusterRoleBinding")
		| select("\(.roleRef.kind)/\(.roleRef.name)" as $r | $have | index($r) | not)
		| "\(.kind)/\(.metadata.name) -> \(.roleRef.kind)/\(.roleRef.name)"' "$sr")
	[[ -z $outside ]] || sfail "these bindings name a role outside the render, whose rules this check cannot see:" "$outside"
	while read -r ces; do
		store=$(jq -r '.spec.externalSecretSpec.secretStoreRef | "\(.kind)/\(.name)"' <<<"$ces")
		sel=$(jq -c '.spec.namespaceSelectors' <<<"$ces")
		cond=$(jq -c --arg n "${store#*/}" '[.[] | select(.kind == "ClusterSecretStore" and .metadata.name == $n)
			| .spec.conditions[]?.namespaceSelector]' "$sr")
		[[ $sel != '[{}]' && $sel != null && $sel == "$cond" ]] \
			|| sfail "ClusterExternalSecret $(jq -r .metadata.name <<<"$ces") selects namespaces $sel," \
				"but its store $store is limited to $cond: any namespace could name the store"
		echo "   $(jq -r .metadata.name <<<"$ces"): to namespaces $sel only, its store limited alike"
	done < <(jq -c '.[] | select(.kind == "ClusterExternalSecret")' "$sr")
}
# The Secret mounted at <dir> in the main container is a Certificate's from the
# device CA, naming every Service in the render.
# Usage: certificate_at <dir> [container]
certificate_at() {
	local vol sec issuer missing
	vol=$(vol_at c "$1" "${2:-}")
	sec=$(jq -r '.secret.secretName // empty' <<<"$vol")
	[[ -n $sec ]] || sfail "no Secret volume is mounted at $1, where the server looks for its certificate"
	issuer=$(jq -r --arg n "$sec" '.[] | select(.kind == "Certificate" and .spec.secretName == $n)
		| "\(.spec.issuerRef.kind)/\(.spec.issuerRef.name)"' "$sr")
	[[ $issuer == ClusterIssuer/device-ca ]] \
		|| sfail "Secret $sec, mounted at $1, is not from a Certificate issued by ClusterIssuer/device-ca:" "${issuer:-no Certificate}"
	missing=$(jq -r --arg n "$sec" '(.[] | select(.kind == "Certificate" and .spec.secretName == $n)
		| .spec.dnsNames) as $d | .[] | select(.kind == "Service")
		| "\(.metadata.name).\(.metadata.namespace).svc.cluster.local"
		| select(. as $f | $d | index($f) | not)' "$sr")
	[[ -z $missing ]] || sfail "the Certificate for $sec does not name:" $missing
	echo "   certificate: Secret $sec from ClusterIssuer/device-ca, every Service named"
}
# A StatefulSet's pod name resolves only through a headless governing Service.
headless_service() {
	local h
	h=$(jq -r "$W"' (workloads | .spec.serviceName) as $n
		| .[] | select(.kind == "Service" and .metadata.name == $n) | .spec.clusterIP' "$sr")
	[[ $h == None ]] || sfail "the StatefulSet's serviceName is not a headless Service in the render"
	echo "   headless governing Service"
}

echo "== valkey =="
# Valkey ships with a passwordless default user, and the pod is reachable from
# every other pod. users.acl is a template: the init container writes it with
# the SHA-256s of passwords ESO generates on the node. Checked here because a
# wrong ACL, password or TLS wiring does not fail the build: the pod crash-loops
# or waits on a node nobody can ssh into, or, worse, starts open, or a password
# reaches a namespace it should not. Every failure lists the root.
sroot=/usr/lib/microshift/manifests.d/050-valkey
sr=$render/050-valkey.json
acl=$sroot/users.acl
conf=$sroot/valkey.conf
[[ -s $acl ]] || sfail "missing or empty: $acl"
# Valkey trims each line and reads every one as a user, so a line the greps
# below cannot see (leading blanks, say) would still be a user.
odd=$(grep -v '^user [^ ]' "$acl" | grep -v '^$' || true)
[[ -z $odd ]] || sfail "$acl has lines that do not start with 'user <name>':" "$odd"
# Valkey makes the default user itself when the file does not mention it, and
# that one is on, nopass and allowed everything: an unauthenticated write works.
grep -qx 'user default off -@all' "$acl" \
	|| sfail "$acl has no 'user default off -@all' line; without it Valkey keeps its" \
		"built-in default user, which needs no password and can run anything"
echo "   default user: off"
# The probe user exists so the pod can be checked with the default user off.
# The whole line, not its tokens: ACL aliases (allcommands, allkeys), %RW~ key
# patterns and (...) selectors would all grant more than PING.
grep -qx 'user probe on nopass -@all +ping' "$acl" \
	|| sfail "the probe user must read exactly 'user probe on nopass -@all +ping'," \
		"which the readiness and liveness probes log in as; it reads:" \
		"$(grep '^user probe ' "$acl" || echo nothing)"
nopass=$(grep -E '(^| )nopass( |$)' "$acl" | grep -v '^user probe ' || true)
[[ -z $nopass ]] || sfail "a user other than probe has no password:" "$nopass"
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
		'>'*) sfail "valkey user $name in $acl has a plaintext > password; it takes $ph only" ;;
		"$ph") own=1 ;;
		'#'*) sfail "valkey user $name in $acl has the hash or placeholder '$t'; it takes $ph only" ;;
		esac
	done
	(( own == 1 )) || sfail "valkey user $name in $acl has no $ph password"
	users+=("$name")
done < <(grep '^user ' "$acl")
for want in root app; do
	[[ " ${users[*]} " == *" $want "* ]] || sfail "$acl has no $want user"
done
echo "   users ${users[*]}: password placeholders"
# The conf and the pod spec are separate files that have to agree. Valkey
# refuses to start with user lines in the conf next to an aclfile.
conf_val() { awk -v k="$1" '$1 == k { print $2 }' "$conf"; }
aclpath=$(conf_val aclfile)
acldir=$(dirname "$aclpath")
[[ $aclpath == */users.acl ]] \
	|| sfail "valkey.conf must say aclfile <dir>/users.acl, got: ${aclpath:-nothing}"
! grep -Eq '^user ' "$conf" || sfail "valkey.conf has user lines next to an aclfile; Valkey refuses to start"
! grep -Eq '^protected-mode[[:space:]]+no' "$conf" \
	|| sfail "valkey.conf turns protected-mode off, which is the net under the ACL"
# TLS only: a plaintext port would carry every password in the clear.
[[ $(conf_val port) == 0 && -n $(conf_val tls-port) ]] \
	|| sfail "valkey.conf must say port 0 and a tls-port, got port '$(conf_val port)'" \
		"tls-port '$(conf_val tls-port)'"
tlsdir=$(dirname "$(conf_val tls-cert-file)")
for k in tls-cert-file tls-key-file tls-ca-cert-file; do
	[[ $(conf_val $k) == "$tlsdir"/* ]] \
		|| sfail "valkey.conf's $k '$(conf_val $k)' is not in $tlsdir with tls-cert-file"
done
# cert-manager renews the certificate in place; without a reload interval
# Valkey serves the old one until it expires.
[[ $(conf_val tls-auto-reload-interval) =~ ^[1-9][0-9]*$ ]] \
	|| sfail "valkey.conf has no tls-auto-reload-interval above 0"
echo "   TLS only, files in $tlsdir, reloaded"
# The ACL is written by the init container into memory, and read there.
[[ $(vol_at c "$acldir" | jq -r '.emptyDir.medium // empty') == Memory ]] \
	|| sfail "Valkey does not read $aclpath from a memory emptyDir:" "$(vol_at c "$acldir")"
[[ $(vol_at i "$acldir" | jq -r 'select(.readOnly | not) | .emptyDir.medium // empty') == Memory ]] \
	|| sfail "no init container writes the memory emptyDir at $acldir"
init=$(jq -r "$W"' workloads | podspec | .initContainers[]? | .command | join(" ")' "$sr")
[[ $init == *render-acl.sh* ]] || sfail "the init container does not run render-acl.sh:" "$init"
script=$sroot/render-acl.sh
sh -n "$script" || sfail "$script does not parse"
# Each placeholder user's password: a file named after it in the init
# container (render-acl.sh fills one placeholder per file).
password_dir
paths=$(vol_at i "$pwdir" | jq -r '.projected.sources[]?.secret.items[]?.path' | sort | tr '\n' ' ')
[[ $paths == "$(printf '%s\n' "${users[@]}" | sort | tr '\n' ' ')" ]] \
	|| sfail "the password files in $pwdir ($paths) are not the template's users (${users[*]})"
passwords_generated "$pwdir" "${users[@]}"
distribution_limited "$(password_secret "$pwdir" root)"
certificate_at "$tlsdir"
headless_service

echo "== postgresql =="
# The image's entrypoint is skipped, so init-db.sh is what makes the cluster,
# its roles and their passwords, and pg_hba.conf is all that stands between
# every pod on the node and the database. Read from the render's ConfigMap,
# the files the pod mounts, because a wrong line does not fail the build: the
# pod crash-loops on a node nobody can ssh into, or, worse, takes plaintext or
# the superuser from the network, or a password reaches a namespace it should
# not. Every failure lists the root.
sroot=/usr/lib/microshift/manifests.d/060-postgresql
sr=$render/060-postgresql.json
main=$(jq -c "$W"' workloads | podspec | .containers[] | select(.command[0] == "postgres")' "$sr")
[[ $(jq -s length <<<"$main") == 1 ]] \
	|| sfail "want one container whose command is postgres, got:" "$(jq -r .name <<<"$main")"
mname=$(jq -r .name <<<"$main")
# The text of a file the postgres container mounts from a ConfigMap.
mounted_file() {
	local cm
	cm=$(vol_at c "$(dirname "$1")" "$mname" | jq -r '.configMap.name // empty')
	[[ -n $cm ]] || return 1
	jq -er --arg n "$cm" --arg f "$(basename "$1")" \
		'.[] | select(.kind == "ConfigMap" and .metadata.name == $n) | .data[$f]' "$sr"
}
cfgfile=$(jq -r '.command as $c | range(1; $c | length) | select($c[. - 1] == "-c")
	| $c[.] | select(startswith("config_file=")) | sub("^config_file="; "")' <<<"$main")
[[ -n $cfgfile ]] || sfail "the postgres command has no '-c config_file=', so the" \
	"postgresql.conf initdb wrote into the data directory would be read instead"
pgconf=$(mounted_file "$cfgfile") \
	|| sfail "config_file $cfgfile is not a file in a ConfigMap the $mname container mounts"
# The last setting wins, as in PostgreSQL; comments and quotes dropped.
pg_conf() {
	awk -v k="$1" '{ sub(/#.*/, "") }
		match($0, "^[[:space:]]*" k "([[:space:]]*=[[:space:]]*|[[:space:]]+)") {
			v = substr($0, RLENGTH + 1); sub(/[[:space:]]+$/, "", v)
			gsub(/^\047|\047$/, "", v); val = v; f = 1 }
		END { if (f) print val }' <<<"$pgconf"
}
[[ $(pg_conf ssl) == on ]] || sfail "$cfgfile must say ssl = on, got '$(pg_conf ssl)'"
[[ $(pg_conf allow_alter_system) == off ]] \
	|| sfail "$cfgfile must say allow_alter_system = off: ALTER SYSTEM writes" \
		"postgresql.auto.conf into the data directory, where it outlives every image"
[[ $(pg_conf password_encryption) =~ ^(scram-sha-256)?$ ]] \
	|| sfail "$cfgfile stores passwords as '$(pg_conf password_encryption)', want scram-sha-256"
echo "   $cfgfile: ssl on, ALTER SYSTEM off, scram-sha-256"
# TLS. PostgreSQL refuses a key file that others can read, and as root's (a
# Secret volume) it reads the key through its group, the fsGroup.
tlsdir=$(dirname "$(pg_conf ssl_cert_file)")
[[ $(dirname "$(pg_conf ssl_key_file)") == "$tlsdir" ]] \
	|| sfail "$cfgfile's ssl_key_file '$(pg_conf ssl_key_file)' is not in $tlsdir with ssl_cert_file"
certificate_at "$tlsdir" "$mname"
mode=$(vol_at c "$tlsdir" "$mname" | jq -r '.secret.defaultMode // 420')
(( (mode & 07) == 0 && (mode & 040) )) \
	|| sfail "the Secret volume at $tlsdir has defaultMode $(printf 0%o "$mode"); PostgreSQL" \
		"refuses a key others can read, and needs group read: want 0440"
echo "   key mode $(printf 0%o "$mode")"
# pg_hba.conf, line by line. Only local and hostssl (host also takes
# plaintext), only scram-sha-256 or reject (no trust, password, md5, peer), no
# options, no @file, +group or /regex the check cannot follow. The superuser:
# the first hostssl line that can match it from beyond loopback must reject it.
# Every other accepting line lets a role into its own database only.
hbafile=$(pg_conf hba_file)
[[ -n $hbafile ]] || sfail "$cfgfile names no hba_file, so the pg_hba.conf initdb" \
	"wrote into the data directory would be read instead"
hba=$(mounted_file "$hbafile") \
	|| sfail "hba_file $hbafile is not a file in a ConfigMap the $mname container mounts"
super=0
while read -r line; do
	read -ra f <<<"$line"
	case ${f[0]} in
	local) addr=local method=${f[3]:-} extra=("${f[@]:4}") ;;
	hostssl) addr=${f[3]:-} method=${f[4]:-} extra=("${f[@]:5}") ;;
	*) sfail "$hbafile: '$line': only local and hostssl lines; host also takes plaintext" ;;
	esac
	[[ $method == scram-sha-256 || $method == reject ]] \
		|| sfail "$hbafile: '$line': the method must be scram-sha-256 or reject, got '$method'"
	(( ${#extra[@]} == 0 )) || sfail "$hbafile: '$line': options after the method"
	[[ ${f[1]}${f[2]} != *[@+/]* ]] \
		|| sfail "$hbafile: '$line': @file, +group and /regex are not followed by this check"
	[[ ${f[0]} == hostssl && $addr != 127.0.0.1/32 && $addr != ::1/128 ]] || continue
	if (( ! super )) && [[ ,${f[2]}, == *,postgres,* || ,${f[2]}, == *,all,* ]]; then
		[[ $method == reject ]] || sfail "$hbafile: '$line' lets the superuser in from" \
			"beyond loopback; 'hostssl all postgres all reject' must come first"
		super=1
		continue
	fi
	[[ $method == reject || ${f[1]} == sameuser ]] \
		|| sfail "$hbafile: '$line' lets a role into a database other than its own; want sameuser"
done < <(sed 's/#.*//' <<<"$hba" | grep -v '^[[:space:]]*$')
(( super )) || sfail "$hbafile has no line refusing the superuser from beyond loopback"
echo "   $hbafile: local and hostssl, scram-sha-256, superuser on loopback only, sameuser"
# The socket: the probes come in on it, and so does tls-reload, which has to
# share the directory. pg_isready never authenticates, but without -U libpq
# looks the assigned UID up in passwd, finds nothing, and gives up.
sock=$(pg_conf unix_socket_directories)
sockvol=$(vol_at c "$sock" "$mname")
[[ $(jq -r '.emptyDir.medium // empty' <<<"$sockvol") == Memory ]] \
	|| sfail "the socket directory $sock is not a memory emptyDir in $mname:" "${sockvol:-nothing mounted}"
probes=$(jq -r '[.startupProbe, .readinessProbe, .livenessProbe][] | .exec.command // ["none"] | join(" ")' <<<"$main")
while read -r p; do
	[[ $p == "pg_isready "* && "$p " == *" -h $sock "* && $p == *" -U "* ]] \
		|| sfail "$mname needs startup, readiness and liveness probes running" \
			"'pg_isready -h $sock -U <role>', got: '$p'"
done <<<"$probes"
reload=$(jq -c "$W"' workloads | podspec | .containers[] | select(any(.command[]?; endswith("/tls-reload.sh")))' "$sr")
[[ -n $reload ]] || sfail "no container runs tls-reload.sh: PostgreSQL would serve its" \
	"first certificate until it expires"
[[ $(jq -r '.command[2]' <<<"$reload") == "$sock" \
	&& $(vol_at c "$sock" "$(jq -r .name <<<"$reload")") == "$sockvol" ]] \
	|| sfail "tls-reload must be given $sock and share its volume with $mname:" "$reload"
echo "   probes and $(jq -r .name <<<"$reload") on the socket in $sock"
# The data directory: one PGDATA for the init container, the server and its
# preStop, below the claim's mount (the volume's root belongs to root and the
# fsGroup; initdb makes PGDATA itself, 0700), and kubelet's recursive fsGroup
# pass only on a mismatch, which would otherwise widen PGDATA at every mount.
pgdata=$(jq -r '.env[]? | select(.name == "PGDATA") | .value' <<<"$main")
[[ $pgdata == /*/* ]] || sfail "$mname has no PGDATA below a mount point: '${pgdata}'"
[[ " $(jq -r '.command | join(" ")' <<<"$main") " == *' -D $(PGDATA) '* ]] \
	|| sfail "the postgres command must say -D \$(PGDATA)"
init=$(jq -c "$W"' workloads | podspec | .initContainers[]? | select(any(.command[]?; endswith("/init-db.sh")))' "$sr")
[[ -n $init ]] || sfail "no init container runs init-db.sh: nothing would create the cluster or set the passwords"
[[ $(jq -r '.env[]? | select(.name == "PGDATA") | .value' <<<"$init") == "$pgdata" ]] \
	|| sfail "PGDATA differs between the init container and $mname"
claims=$(jq -r "$W"' workloads | .spec.volumeClaimTemplates[]?.metadata.name' "$sr")
for c in "$init" "$main"; do
	m=$(jq -r --arg d "$(dirname "$pgdata")" '.volumeMounts[]? | select(.mountPath == $d) | .name' <<<"$c")
	[[ -n $m ]] && grep -qx "$m" <<<"$claims" \
		|| sfail "$(jq -r .name <<<"$c") does not mount a volumeClaimTemplate at $(dirname "$pgdata")"
done
[[ $(jq -r "$W"' workloads | podspec | .securityContext.fsGroupChangePolicy' "$sr") == OnRootMismatch ]] \
	|| sfail "the pod must say fsGroupChangePolicy: OnRootMismatch"
[[ $(jq -r '.lifecycle.preStop.exec.command // [] | join(" ")' <<<"$main") == *"stop -m fast"* ]] \
	|| sfail "$mname needs a preStop 'pg_ctl stop -m fast': the default smart shutdown waits" \
		"for every client to leave, and the pod is killed at the end of its grace period"
echo "   PGDATA $pgdata on claim $(dirname "$pgdata"), OnRootMismatch, fast shutdown"
for s in init-db.sh tls-reload.sh; do
	sh -n "$sroot/$s" || sfail "$sroot/$s does not parse"
done
# Passwords: one file per role, which init-db.sh creates, postgres and app
# among them.
password_dir
[[ " $(jq -r '.command | join(" ")' <<<"$init") " == *" $pwdir "* ]] \
	|| sfail "init-db.sh is not given the password directory $pwdir"
mapfile -t roles < <(vol_at i "$pwdir" | jq -r '.projected.sources[]?.secret.items[]?.path' | sort)
for want in postgres app; do
	[[ " ${roles[*]} " == *" $want "* ]] || sfail "no password file for role $want in $pwdir: ${roles[*]}"
done
for r in "${roles[@]}"; do
	[[ $r =~ ^[a-z][a-z0-9_]*$ && $r != pg_* ]] \
		|| sfail "password file $pwdir/$r: init-db.sh takes role names [a-z][a-z0-9_]*, not pg_*"
done
passwords_generated "$pwdir" "${roles[@]}"
distribution_limited "$(password_secret "$pwdir" postgres)"
headless_service

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
