#!/bin/bash
# Checks run inside the kiosk layer before it is pushed. Fed on stdin:
#   podman run --rm -i "$IMAGE:$TAG" bash -s < kiosk/smoke-test.sh
#
# Proves the pieces agree with each other. Whether a picture leaves the DP port
# is a hardware question.
set -euo pipefail

fail() { echo "$*"; exit 1; }

echo "== boots to GDM =="
# `systemctl enable` only warns on a bad [Install], so the build does not notice.
[[ $(readlink /etc/systemd/system/default.target) == */graphical.target ]] \
	|| fail "default.target is $(readlink /etc/systemd/system/default.target), not graphical.target"
[[ $(readlink /etc/systemd/system/display-manager.service) == */gdm.service ]] \
	|| fail "display-manager.service is not gdm.service"

echo "== kiosk user, password and session =="
# As a boot would: an unexpanded escape, a missing owner or a lost password
# shows now.
user=kiosk
dropin=/usr/lib/systemd/system/systemd-sysusers.service.d/50-jetson-kiosk.conf
hash=$(sed -n "s/^LoadCredential=passwd.hashed-password.$user://p" "$dropin")
[[ -f $hash ]] || fail "$dropin loads '$hash', which is not a file"
[[ $(stat -c %a "$hash") == 600 ]] \
	|| fail "$hash is mode $(stat -c %a "$hash"), not 600: any local user could read the hash"
creds=$(mktemp -d)
cp "$hash" "$creds/passwd.hashed-password.$user"
CREDENTIALS_DIRECTORY=$creds systemd-sysusers
systemd-tmpfiles --create /usr/lib/tmpfiles.d/jetson-kiosk.conf
id "$user" || fail "sysusers did not create $user"
[[ $(getent shadow "$user" | cut -d: -f2) == "$(cat "$hash")" ]] \
	|| fail "sysusers created $user without the password from $hash"

# The login screen offers every session file; anything but kiosk's is a desktop.
# One name is one session: RHEL ships the kiosk one for Wayland and for X11.
session=$(sed -n 's/^Session=//p' "/var/lib/AccountsService/users/$user")
offered=$({ find /usr/share/wayland-sessions /usr/share/xsessions -name '*.desktop' -printf '%f\n' 2>/dev/null || true; } | LC_ALL=C sort -u)
[[ $offered == "$session.desktop" ]] || {
	echo "the login screen offers [${offered//$'\n'/ }], not only $session.desktop (the AccountsService session):"
	ls -la /usr/share/wayland-sessions /usr/share/xsessions 2>&1 || true
	exit 1
}

script=/var/home/$user/.local/bin/gnome-kiosk-script
[[ -x $script ]] || fail "$script is not executable"
bash -n "$script"
grep -q '.local/bin/gnome-kiosk-script' "$(command -v gnome-kiosk-script)" \
	|| fail "gnome-kiosk-script no longer runs ~/.local/bin/gnome-kiosk-script"
for cmd in firefox curl; do
	command -v "$cmd" || fail "not on PATH: $cmd"
done

echo "== login screen logo, background and kiosk picture =="
# dconf read shows no schema default, so a stale database, or a profile that no
# longer reads it, reads empty here and leaves Red Hat's logo up. A missing or
# undecodable file shows nothing; RHEL's gdk-pixbuf has no WebP loader, so PNG.
logo=$(DCONF_PROFILE=gdm dconf read /org/gnome/login-screen/logo)
logo=${logo//\'/}
avatar=$(sed -n 's/^Icon=//p' "/var/lib/AccountsService/users/$user")
# shell-theme.sh compiles the theme uncompressed, so the rule is plain text in
# it; a later package that reinstalled the theme would drop it.
theme=/usr/share/gnome-shell/gnome-shell-theme.gresource
background=$(grep -ao 'url(file:///[^)]*)' "$theme" | sed 's/^url(file:\/\/\(.*\))$/\1/' | tail -1 || true)
for img in "$logo" "$avatar" "$background"; do
	[[ $img == /usr/share/jetson-kiosk/* ]] || {
		echo "the greeter's logo is '$logo', its background '$background' (from $theme) and $user's picture '$avatar'; expected all in /usr/share/jetson-kiosk:"
		ls -la /usr/share/jetson-kiosk /etc/dconf/db 2>&1 || true
		exit 1
	}
	[[ -f $img ]] || fail "$img, named by the login screen, is not in the image"
	[[ $(head -c 8 "$img" | od -An -tx1 | tr -d ' \n') == 89504e470d0a1a0a ]] \
		|| fail "$img is not a PNG"
done

echo "== the login screen and session can reach NVIDIA's GPU =="
id -Gn gdm | grep -qw video || fail "gdm is in groups '$(id -Gn gdm)', not video: the login screen cannot open nvmap"
# glvnd loads the vendor library by soname: not in the loader cache, EGL is
# Mesa's and mutter refuses the GPU.
vendor=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
lib=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ICD"]["library_path"])' "$vendor")
ldconfig -p | grep -q "^[[:space:]]*$lib .*=> /" || {
	echo "$vendor names $lib, which the loader cache does not have:"
	ldconfig -p | grep -i nvidia || true
	ls -l /etc/ld.so.conf.d/
	exit 1
}

# device_t otherwise, and the login screen is denied the nodes. A missing node
# is fine: the lookup is by path and type.
for node in /dev/nvmap /dev/nvhost-ctrl-gpu /dev/nvgpu/igpu0/ctrl; do
	ctx=$(matchpathcon -m c "$node" | awk '{print $2}')
	[[ $ctx == *:dri_device_t:* ]] || {
		echo "$node would be labelled '$ctx', not dri_device_t; installed modules:"
		semodule -l | grep -i jetson || true
		exit 1
	}
done

echo "== the GPU stays powered =="
# Another rule, or an nvpmodel mode, writing railgate_enable would undo ours
# depending on the order they run in.
ours=/usr/lib/udev/rules.d/99-jetson-gpu-railgate.rules
others=$(grep -rls railgate_enable /usr/lib/udev/rules.d /etc/udev/rules.d \
	$(find /etc /usr/lib /usr/share -maxdepth 3 -name 'nvpmodel*.conf' 2>/dev/null) \
	| grep -vx "$ours" || true)
[[ -z $others ]] || fail "railgate_enable is also written by: ${others//$'\n'/ }"

echo "== no way out of the session =="
# A terminal or file manager is one handler away.
for app in gnome-terminal ptyxis kgx xterm konsole foot nautilus; do
	! command -v "$app" >/dev/null || fail "$app is installed: a way out of the kiosk"
done
# video opens the GPU nodes, nothing else; any other group is a way out.
[[ $(id -Gn "$user") == "$user video" ]] \
	|| fail "$user is in groups '$(id -Gn "$user")', not only its own and video"
first=$(grep -m1 '^account' /etc/pam.d/login)
[[ $first == *pam_succeed_if.so*"user != $user"* ]] \
	|| fail "/etc/pam.d/login does not refuse $user first; its first account line: $first"
# polkit asks rules in name order, across both directories.
rules=$({ find /etc/polkit-1/rules.d /usr/share/polkit-1/rules.d -name '*.rules' -printf '%f\n' 2>/dev/null || true; } | LC_ALL=C sort)
[[ $(head -1 <<<"$rules") == 10-jetson-kiosk.rules ]] || {
	echo "10-jetson-kiosk.rules is not the first polkit rule:"
	echo "$rules"
	exit 1
}

echo "== the kiosk password does not open ssh =="
# A drop-in sshd never includes is ignored silently.
grep -qx 'Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config || {
	echo "/etc/ssh/sshd_config does not include sshd_config.d, so DenyUsers $user is ignored:"
	grep -n '^Include' /etc/ssh/sshd_config || true
	exit 1
}

echo "== firefox policies =="
# A policies.json that does not parse is ignored whole, silently.
python3 -m json.tool /etc/firefox/policies/policies.json >/dev/null \
	|| fail "/etc/firefox/policies/policies.json does not parse"

echo "all checks passed"
