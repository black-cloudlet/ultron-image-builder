#!/bin/sh
# Valkey's init container: users.acl with the generated passwords' SHA-256s in
# place of the placeholders, into the memory-backed volume Valkey reads. Each
# user's password is a file named after it, from the Secrets in passwords.yaml.
# Usage: render-acl.sh <template> <password dir> <output>
set -eu
template=$1 pwdir=$2 out=$3
rendered=$(cat "$template")
for user in root app; do
	pw=$pwdir/$user
	if [ ! -s "$pw" ]; then
		echo "no password for valkey user $user at $pw"; ls -la "$pwdir"; exit 1
	fi
	name=$(echo "$user" | tr a-z A-Z)
	hash=$(sha256sum < "$pw" | cut -d' ' -f1)
	rendered=$(printf '%s\n' "$rendered" | sed "s/@VALKEY_${name}_PASSWORD_SHA256@/$hash/")
done
case $rendered in
*@VALKEY_*) echo "a placeholder in $template has no password:"
	printf '%s\n' "$rendered" | grep '@VALKEY_' | cut -d' ' -f1-2; exit 1 ;;
esac
printf '%s\n' "$rendered" > "$out"
