#!/bin/bash
# Checks run inside the republished vendor image. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < base/smoke-test.base.sh
#
# The layer adds only field tools, so this is really about the vendor image: a
# base bump that breaks one of these breaks the GPU on every variant.
set -euo pipefail

bootc --version
cat /etc/nv_tegra_release
# Must match the QSPI's R36.5.x BSP, or the node hangs at boot.
grep -qE '^# R36 \(release\), REVISION: 5\.' /etc/nv_tegra_release \
	|| { echo "/etc/nv_tegra_release is not R36 REVISION 5.x: the QSPI BSP no longer matches"; exit 1; }
rpm -q nvidia-jetpack-for-rhel-9.8-kmod nvidia-container-toolkit-base
ls /usr/lib/modules/*/extra/drivers/gpu/nvgpu/nvgpu.ko

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

echo "all checks passed"
