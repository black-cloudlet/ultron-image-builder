#!/bin/sh
# Valkey's init container: users.acl with the generated passwords' SHA-256s in
# place of the placeholders, into the memory-backed volume Valkey reads. Each
# file in the password directory is one user's password, named after the user
# (the projected items in valkey.yaml); the template's placeholders say which
# users must have one. A user without a file, or a file whose hash is not 64
# hex digits, stops the pod here rather than in Valkey.
# Usage: render-acl.sh <template> <password dir> <output>
set -euo pipefail
template=$1 pwdir=$2 out=$3
set --
for pw in "$pwdir"/*; do
	[ -e "$pw" ] || break
	user=${pw##*/}
	case $user in
	*[!a-z0-9_]*) echo "password file $pw: user names are [a-z0-9_]"; exit 1 ;;
	esac
	if [ ! -s "$pw" ]; then
		echo "empty password for valkey user $user at $pw"; ls -la "$pwdir"; exit 1
	fi
	hash=$(sha256sum < "$pw") || { echo "sha256sum failed on $pw"; exit 1; }
	hash=${hash%% *}
	case $hash in
	*[!0-9a-f]*) echo "sha256sum gave no hash for $pw: $hash"; exit 1 ;;
	esac
	[ ${#hash} -eq 64 ] || { echo "sha256sum gave no hash for $pw: $hash"; exit 1; }
	name=$(printf '%s' "$user" | tr a-z A-Z)
	set -- "$@" -e "s/#@VALKEY_${name}_PASSWORD_SHA256@/#$hash/"
done
if [ $# -eq 0 ]; then
	echo "no password files in $pwdir"; ls -la "$pwdir"; exit 1
fi
sed "$@" "$template" > "$out"
if grep -q '@VALKEY_' "$out"; then
	echo "these users in $template have no password file in $pwdir:"
	grep '@VALKEY_' "$out" | cut -d' ' -f2
	rm -f "$out"; exit 1
fi
