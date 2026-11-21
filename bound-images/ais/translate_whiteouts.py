#!/usr/bin/python3 -I
"""Rewrite an overlay image store's deletion markers into ostree's form.

Usage: translate_whiteouts.py STORE

STORE is a containers-storage graph root (overlay driver) on a plain
filesystem, not on overlayfs, so its markers are real and visible.

Why: an overlay store keeps a deletion (a whiteout) and a replaced (opaque)
directory in one of two forms, both of which a `podman build` takes for its own:
  - kernel form: a 0:0 character device NAME, and the trusted.overlay.opaque
    xattr. The build's overlay hides them and its diff writes them into the OS
    image's layer as OCI deletions (`.wh.NAME`, `.wh..wh..opq`).
  - fuse-overlayfs form, written when a mount program is set, as
    build_proof_store.sh does: empty files `.wh.NAME` and `.wh..wh..opq`. In
    the OS image's layer tar those names are themselves OCI deletions.
Either way the node unpacks a store with no record of what was deleted.
ostree has a form that survives: an empty regular file `.ostree-wh.NAME`,
which ostree turns into a 0:0 device NAME when it writes the tree out.

So, in every layer's diff directory:
  1. every opaque directory becomes explicit markers, one per name the layers
     below hold in that directory (recursing where both sides hold a
     directory, since opacity hides the lower one's contents too), and loses
     its xattr or `.wh..wh..opq` file: ostree has no opaque form;
  2. every whiteout NAME, device or `.wh.NAME` file, becomes an empty file
     `.ostree-wh.NAME`.
A marker for a name nothing below holds is harmless, so the lower names are
the union over all lower layers, without stacking them.

Then it checks that no 0:0 device and no opaque xattr is left, and prints
what it wrote.
"""
import os
import stat
import sys

PREFIX = ".ostree-wh."
OCI = ".wh."
OCI_OPAQUE = ".wh..wh..opq"
OPAQUE = ("trusted.overlay.opaque", "user.overlay.opaque")


def whiteout_of(root, name):
    """The name a whiteout entry deletes, or None if it is not one."""
    st = os.lstat(os.path.join(root, name))
    if stat.S_ISCHR(st.st_mode) and st.st_rdev == 0:
        return name
    if stat.S_ISREG(st.st_mode) and name.startswith(OCI) and name != OCI_OPAQUE:
        return name[len(OCI):]
    return None


def is_opaque(path):
    if os.path.lexists(os.path.join(path, OCI_OPAQUE)):
        return True
    for attr in OPAQUE:
        try:
            if os.getxattr(path, attr, follow_symlinks=False) == b"y":
                return True
        except OSError:
            pass
    return False


def lower_diffs(overlay, layer):
    """The diff directories below a layer, from its `lower` file."""
    try:
        with open(os.path.join(overlay, layer, "lower")) as f:
            links = f.read().strip()
    except FileNotFoundError:
        return []  # a base layer
    diffs = []
    for link in links.split(":"):
        target = os.path.realpath(os.path.join(overlay, link))
        if not os.path.isdir(target):
            sys.exit(f"{layer}: lower {link} resolves to {target}, not a directory")
        diffs.append(target)
    return diffs


def names_below(lowers, rel):
    names = set()
    for lower in lowers:
        try:
            entries = os.listdir(os.path.join(lower, rel))
        except (FileNotFoundError, NotADirectoryError):
            continue
        for name in entries:
            if name == OCI_OPAQUE:
                continue
            for prefix in (PREFIX, OCI):
                if name.startswith(prefix):
                    name = name[len(prefix):]
                    break
            names.add(name)
    return names


def dir_below(lowers, rel):
    return any(os.path.isdir(os.path.join(l, rel)) and
               not os.path.islink(os.path.join(l, rel)) for l in lowers)


def touch(path, written):
    if not os.path.lexists(path):
        open(path, "x").close()
        os.chmod(path, 0o644)
        written.append(path)


def hide_below(diff, lowers, rel, written):
    """Make diff/rel hide what lowers hold at rel, without an opaque xattr."""
    for name in sorted(names_below(lowers, rel)):
        sub = os.path.join(rel, name)
        upper = os.path.join(diff, sub)
        if os.path.lexists(upper):
            st = os.lstat(upper)
            if stat.S_ISDIR(st.st_mode) and dir_below(lowers, sub):
                hide_below(diff, lowers, sub, written)
            continue
        # A `.wh.NAME` already there becomes this same marker in step 2.
        touch(os.path.join(diff, rel, PREFIX + name), written)


def walk(diff):
    for root, dirs, files in os.walk(diff):
        yield root, dirs + files


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.split("\n\n")[1])
    overlay = os.path.join(sys.argv[1], "overlay")
    if not os.path.isdir(overlay):
        sys.exit(f"not an overlay store: {overlay} is missing")
    layers = sorted(d for d in os.listdir(overlay)
                    if d != "l" and os.path.isdir(os.path.join(overlay, d, "diff")))
    if not layers:
        sys.exit(f"no layers under {overlay}")

    written = []
    # 1. Opaque directories, before the devices: their markers must not
    #    count a device of the same layer as a name below.
    for layer in layers:
        diff = os.path.join(overlay, layer, "diff")
        lowers = lower_diffs(overlay, layer)
        for root, _ in list(walk(diff)):
            if is_opaque(root):
                hide_below(diff, lowers, os.path.relpath(root, diff), written)
                if os.path.lexists(os.path.join(root, OCI_OPAQUE)):
                    os.unlink(os.path.join(root, OCI_OPAQUE))
                for attr in OPAQUE:
                    try:
                        os.removexattr(root, attr, follow_symlinks=False)
                    except OSError:
                        pass
    # 2. Whiteout devices.
    for layer in layers:
        diff = os.path.join(overlay, layer, "diff")
        for root, names in list(walk(diff)):
            for name in names:
                deleted = whiteout_of(root, name)
                if deleted is not None:
                    os.unlink(os.path.join(root, name))
                    touch(os.path.join(root, PREFIX + deleted), written)

    left = []
    for layer in layers:
        diff = os.path.join(overlay, layer, "diff")
        for root, names in walk(diff):
            if is_opaque(root):
                left.append(f"opaque: {root}")
            for name in names:
                if whiteout_of(root, name) is not None:
                    left.append(f"whiteout: {os.path.join(root, name)}")
    if left:
        print("\n".join(left))
        sys.exit("markers left untranslated")

    for path in written:
        print(os.path.relpath(path, overlay))
    print(f"{len(written)} markers in {len(layers)} layers", file=sys.stderr)


if __name__ == "__main__":
    main()
