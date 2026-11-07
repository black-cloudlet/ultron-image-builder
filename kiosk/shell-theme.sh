#!/bin/bash
# Rebuilds GNOME Shell's theme resource with a CSS file appended to
# gnome-shell.css. GNOME 40 has no setting for the login screen's background:
# it is the theme's #lockDialogGroup rule. Runs in a throwaway build stage,
# since gresource and glib-compile-resources come only with glib2-devel.
#   shell-theme.sh <css to append> <output .gresource>
set -euo pipefail

fail() { echo "$*" >&2; exit 1; }

[[ $# -eq 2 && -f $1 ]] || fail "usage: $0 <css to append> <output .gresource>"
css=$1 out=$2
res=/usr/share/gnome-shell/gnome-shell-theme.gresource
prefix=/org/gnome/shell/theme
work=$(mktemp -d)

gresource list "$res" > "$work/list"
grep -qx "$prefix/gnome-shell.css" "$work/list" || {
	echo "$res has no $prefix/gnome-shell.css:" >&2
	cat "$work/list" >&2
	exit 1
}

# Every file back at its path, uncompressed: the smoke test greps the result.
{
	echo '<?xml version="1.0" encoding="UTF-8"?>'
	echo "<gresources><gresource prefix=\"$prefix\">"
	while read -r path; do
		[[ $path == "$prefix"/* ]] || fail "$res holds $path, outside $prefix"
		rel=${path#"$prefix"/}
		mkdir -p "$work/src/$(dirname "$rel")"
		gresource extract "$res" "$path" > "$work/src/$rel"
		echo "<file>$rel</file>"
	done < "$work/list"
	echo '</gresource></gresources>'
} > "$work/theme.xml"

# A theme that drops the selector would ignore the rule silently.
grep -q '#lockDialogGroup' "$work/src/gnome-shell.css" \
	|| fail "$prefix/gnome-shell.css has no #lockDialogGroup rule: the login screen background moved"
{ echo; cat "$css"; } >> "$work/src/gnome-shell.css"
glib-compile-resources --sourcedir="$work/src" --target="$out" "$work/theme.xml"

[[ $(gresource list "$out") == "$(cat "$work/list")" ]] \
	|| fail "$out does not hold the same files as $res"
[[ $(gresource extract "$out" "$prefix/gnome-shell.css" | tail -n "$(wc -l < "$css")") == "$(cat "$css")" ]] \
	|| fail "$out's gnome-shell.css does not end with $css"
rm -rf "$work"
