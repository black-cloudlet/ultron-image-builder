#!/bin/bash
# Checks run inside the bound-images layer before it is pushed. Fed on
# stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < bound-images/smoke-test.sh
#
# Only what the build cannot fail on by itself: the COPYs in the Containerfile
# already fail the build if their file is missing.
set -euo pipefail

echo "== physically bound images =="
# `systemctl enable` on a unit whose [Install] section is missing or misspelt
# only warns and exits 0, so the build does not notice.
wants=/etc/systemd/system/multi-user.target.wants
if [[ ! -L $wants/copy-embedded-images.service ]]; then
	echo "not enabled: copy-embedded-images.service"
	ls -la "$wants" | sed 's/^/   /'
	exit 1
fi

# The machinery only — a cache here is an image every variant would pay for.
if [[ -e /usr/lib/containers-image-cache ]]; then
	echo "unexpected image cache in the bound-images layer:"
	ls -la /usr/lib/containers-image-cache | sed 's/^/   /'
	exit 1
fi

echo "== edge manager agent =="
rpm -qa 'flightctl*' | sort
if [[ ! -L $wants/flightctl-agent.service ]]; then
	echo "not enabled: flightctl-agent.service"
	ls -la "$wants" | sed 's/^/   /'
	exit 1
fi

# A drop-in for a missing unit is silently ignored.
for unit in flightctl-agent.service bootc-fetch-apply-updates.service; do
	if [[ ! -f /usr/lib/systemd/system/$unit ]]; then
		echo "drop-in target missing: /usr/lib/systemd/system/$unit"
		ls /usr/lib/systemd/system | grep -E 'flightctl|bootc' | sed 's/^/   /'
		exit 1
	fi
done

# Unenrolled, the agent is idle by design, and a failing required greenboot
# check rolls every upgrade back. Without the guard the check waits 150 s.
check=$(rpm -ql flightctl-agent | grep /greenboot/check/)
if ! timeout 10 bash "$check" >/dev/null 2>&1; then
	echo "$check fails on an unenrolled node; its head:"
	head -5 "$check" | sed 's/^/   /'
	exit 1
fi

echo "all checks passed"
