#!/bin/sh
# PostgreSQL rereads its certificate and key only on a reload, and cert-manager
# renews them in place 30 days before they expire. Hourly, as Valkey's
# tls-auto-reload-interval: kubelet has the new files in the mounted Secret
# within a minute or so of the renewal. A reload rereads postgresql.conf and
# pg_hba.conf too, unchanged: a change to those rolls the pod (the ConfigMap's
# name suffix). The password is the superuser's, from the projected Secret,
# used over the pod's own socket.
# Usage: tls-reload.sh <socket directory> <superuser password file>
set -euo pipefail
sock=$1
PGPASSWORD=$(cat "$2")
export PGPASSWORD
# sh as PID 1 ignores SIGTERM without a trap, and the pod would wait out its
# grace period for this container. INT too: the image's STOPSIGNAL is SIGINT.
trap 'exit 0' INT TERM
while :; do
	sleep 3600 &
	wait $!
	psql -X -Atq -h "$sock" -U postgres -d postgres \
		-c 'SELECT pg_reload_conf()' >/dev/null || echo "reload failed; next try in an hour"
done
