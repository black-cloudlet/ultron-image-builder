#!/bin/bash
# Checks run inside the republished vendor image. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < base/smoke-test.base.sh
#
# Mostly the vendor image: a base bump that breaks these breaks the GPU everywhere.
set -euo pipefail

bootc --version
cat /etc/nv_tegra_release
# Must match the QSPI's R36.5.x BSP, or the node hangs at boot.
grep -qE '^# R36 \(release\), REVISION: 5\.' /etc/nv_tegra_release \
	|| { echo "/etc/nv_tegra_release is not R36 REVISION 5.x: the QSPI BSP no longer matches"; exit 1; }
rpm -q "nvidia-jetpack-for-rhel-$(cat /etc/dnf/vars/releasever)-kmod" nvidia-container-toolkit-base
ls /usr/lib/modules/*/extra/drivers/gpu/nvgpu/nvgpu.ko

# Without our toolkit the vendor's CDI unit skips silently.
cond=$(sed -n 's/^ConditionPathExists=//p' /usr/lib/systemd/system/nvidia-ctk.service)
[ -x "$cond" ] || { echo "nvidia-ctk.service runs only if '$cond' exists, and it does not"; exit 1; }
wants=/etc/systemd/system/multi-user.target.wants
for u in nvidia-ctk.service nvidia-cdi-refresh.path nvidia-cdi-refresh.service; do
	[ -e "$wants/$u" ] || { echo "$u is not enabled; $wants has:"; ls "$wants"; exit 1; }
done

# skopeo is used by embed_image.sh at build time and by copy_embedded_images.sh
# at boot; podman by the latter, to drop a superseded image set. Both come from
# the vendor image rather than being installed.
command -v skopeo
command -v podman

# Root is on an LV in both kickstarts, and MicroShift's LVMS shells out to vgs,
# only warning when it is missing. Nothing here installs lvm2; the microshift
# RPM does not even require it.
rpm -q lvm2
for cmd in lvm vgs; do
	command -v "$cmd" || { echo "missing: $cmd, from lvm2"; exit 1; }
done

echo "== jetson-stats =="
if ! command -v jtop; then
	echo "jtop is not on PATH ($PATH); where pip put jetson-stats:"
	pip3 show -f jetson-stats 2>&1 | sed 's/^/   /'
	exit 1
fi

# jtop installs its own unit, unchanged from the template, when it finds none at
# this path. The template's binary path was wrong once, and the unit then
# restarted forever.
unit=/etc/systemd/system/jtop.service
if [[ ! -f $unit || -L $unit ]]; then
	echo "not a regular file: $unit"
	ls -la /etc/systemd/system | grep -i jtop | sed 's/^/   /'
	exit 1
fi
exe=$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$unit")
if [[ ! -x $exe ]]; then
	echo "$unit runs '$exe', which is not executable:"
	grep -n ExecStart "$unit" | sed 's/^/   /'
	exit 1
fi
if [[ ! -L $wants/jtop.service ]]; then
	echo "not enabled: jtop.service"
	ls -la "$wants" | sed 's/^/   /'
	exit 1
fi

# The service creates its settings folder under /usr, read-only on a node. Ask
# jtop where it is, create /var as a boot would, and expect it to resolve there.
systemd-tmpfiles --create /usr/lib/tmpfiles.d/jtop.conf
cfg=$(python3 -c 'from jtop.core.config import get_config_service as g; print(g())')
if [[ $(realpath -m "$cfg") != /var/lib/jtop || ! -d $cfg ]]; then
	echo "jtop settings folder $cfg does not resolve to /var/lib/jtop:"
	ls -ld "$cfg" /var/lib/jtop 2>&1 | sed 's/^/   /'
	exit 1
fi

echo "all checks passed"
