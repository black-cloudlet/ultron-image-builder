#!/bin/sh
# PostgreSQL's init container. Creates the cluster on first start; then, on
# every start, gives each role the password in its file, creating the role and
# a database of the same name when new. Each file in the password directory is
# one role's password, named after the role (the projected items in
# postgresql.yaml); postgres is the superuser initdb makes. A role whose file
# is gone keeps its database and its last password: nothing here drops data.
# Crash recovery after a power cut also happens here, where no probe can kill
# it half-way.
# Usage: init-db.sh <password dir>; PGDATA is the data directory.
set -euo pipefail
pwdir=$1
: "${PGDATA:?PGDATA is not set}"

roles=
for pw in "$pwdir"/*; do
	[ -e "$pw" ] || break
	role=${pw##*/}
	case $role in
	pg_* | [!a-z]* | *[!a-z0-9_]*)
		echo "password file $pw: role names are [a-z][a-z0-9_]*, not pg_*"; exit 1 ;;
	esac
	# ESO's generator, symbols 0: letters and digits. Anything else is not
	# its output, and would break the URI clients are given.
	case $(cat "$pw") in
	'' | *[!A-Za-z0-9]*)
		echo "password for role $role at $pw is empty or not letters and digits only"
		ls -la "$pwdir"; exit 1 ;;
	esac
	roles="$roles $role"
done
case " $roles " in
*" postgres "*) ;;
*) echo "no password file for the postgres superuser in $pwdir"; ls -la "$pwdir"; exit 1 ;;
esac

major=$(postgres -V | sed -n 's/^postgres (PostgreSQL) \([0-9]*\).*/\1/p')
[ -n "$major" ] || { echo "cannot tell the server's major version from: $(postgres -V)"; exit 1; }
if [ -e "$PGDATA" ]; then
	if [ ! -s "$PGDATA/PG_VERSION" ]; then
		echo "$PGDATA exists but holds no cluster (no PG_VERSION); refusing to touch it"
		ls -la "$PGDATA"; exit 1
	fi
	have=$(cat "$PGDATA/PG_VERSION")
	if [ "$have" != "$major" ]; then
		echo "$PGDATA is a PostgreSQL $have cluster and this image is PostgreSQL $major:"
		echo "a major version needs pg_upgrade or a dump and restore, never a tag bump alone"
		exit 1
	fi
	# kubelet's fsGroup pass adds g+rwx to every directory on the volume, and
	# PostgreSQL refuses a data directory its group may write.
	chmod 0700 "$PGDATA"
else
	# initdb looks the running UID up in passwd, and the one restricted-v2
	# assigns is in none. The image's /etc/passwd is writable by group 0,
	# which OpenShift runs every container in, for exactly this: its own
	# entrypoint, skipped here, adds the UID the same way. Only this
	# container's copy changes.
	if ! id -un >/dev/null 2>&1; then
		[ -w /etc/passwd ] || {
			echo "UID $(id -u) is not in /etc/passwd, which group $(id -g) cannot write;"
			echo "initdb needs the UID there (OpenShift runs containers in group 0)"
			ls -l /etc/passwd; exit 1
		}
		echo "postgres:x:$(id -u):$(id -g):PostgreSQL:$PGDATA:/sbin/nologin" >> /etc/passwd
	fi
	# Built beside it and moved into place, so a half-made cluster is never
	# mistaken for one. The builtin C.UTF-8 locale sorts by code point and is
	# versioned with PostgreSQL itself, so a new image's glibc or ICU never
	# invalidates an index. Data checksums are PostgreSQL 18's default.
	new=$PGDATA.initdb
	rm -rf "$new"
	initdb -D "$new" -U postgres --pwfile="$pwdir/postgres" \
		--no-instructions -A scram-sha-256 -E UTF8 --locale-provider=builtin --locale=C.UTF-8
	mv "$new" "$PGDATA"
fi

# A temporary server on a socket in a private directory, nothing on TCP, so
# trust there reaches this script alone. Passwords are read by psql itself
# (\set with backticks), never on a command line, and no statement is logged,
# even one that fails.
sock=$(mktemp -d)
printf 'local all postgres trust\n' > "$sock/pg_hba.conf"
pg_ctl -D "$PGDATA" -w -t 3600 start -o "-c listen_addresses= \
	-c unix_socket_directories=$sock -c hba_file=$sock/pg_hba.conf \
	-c shared_buffers=16MB -c log_statement=none -c log_min_error_statement=panic"
trap 'pg_ctl -D "$PGDATA" -m fast -w stop' EXIT
{
	printf '%s\n' '\set ON_ERROR_STOP on'
	for role in $roles; do
		printf '\\set role %s\n\\set pw `cat %s`\n' "$role" "'$pwdir/$role'"
		if [ "$role" = postgres ]; then
			printf '%s\n' "ALTER ROLE postgres PASSWORD :'pw';"
			continue
		fi
		cat <<-'SQL'
		SELECT format('CREATE ROLE %I', :'role')
			WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') \gexec
		ALTER ROLE :"role" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
			NOBYPASSRLS PASSWORD :'pw';
		SELECT format('CREATE DATABASE %I OWNER %I', :'role', :'role')
			WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'role') \gexec
		REVOKE ALL ON DATABASE :"role" FROM PUBLIC;
		SQL
	done
} | psql -X -q -h "$sock" -U postgres -d postgres
trap - EXIT
pg_ctl -D "$PGDATA" -m fast -w stop
echo "roles:$roles"
