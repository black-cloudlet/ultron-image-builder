# CLAUDE.md — jetson-image-builder

Provisioning and image pipeline for NVIDIA Jetson AGX Orin edge nodes running RHEL image mode
(bootc) in a disconnected environment. The project is **Ultron**: images are
`ultron-bootc-<layer>`, the top one also `ultron-bootc`, the ISO `ultron-<tag>.iso`. Read this whole file before touching anything.

**Two repos.** This one holds the image pipeline (`base/`, `microshift/`, `services/`,
`.github/workflows/`). The flashing-station tooling (`mirror.sh`, `install-offline.sh`, the
station-side flashing docs) lives in `black-cloudlet/jetson-installer-config`: different job,
different machines. This file describes both because they must agree on the L4T line, but only
the image pipeline is editable from here.

## What this project is

Edge AI nodes (image recognition inference) on Jetson AGX Orin. Nodes run fully disconnected
during missions and join the organisation's **air-gapped network** only between missions for
maintenance, upgrades and deployments. Nothing on a device or the flashing station ever
reaches the internet.

- RHEL 9.8 image mode (bootc), aarch64
- **MicroShift 4.20** is the only variant. A k3s variant was built by nothing and removed; it
  is in git history
- On the cluster: cert-manager, External Secrets, KServe (Standard mode), a Triton
  `ClusterServingRuntime` and a per-device CA published to every namespace, from `services/`.
  Still to come: PostgreSQL, RabbitMQ, the first `InferenceService`
- Every container image physically bound into the OS image (zero network at first boot)
- A kiosk: a monitor on the Jetson's DisplayPort shows the frontend in Firefox, fullscreen. It
  must be on the Jetson itself (maintainer's requirement; a separate display box was offered and
  declined), and it stays Red Hat's documented setup, nothing custom (maintainer's call)

**Model serving is upstream KServe, not Red Hat's**: `microshift-ai-model-serving` is x86_64
only. KServe was removed once before (`bba9d10`, reason unrecorded).

### Hardware

| Part  | Role |
|-------|------|
| P3701 | System on Module — CPU/GPU/RAM (32 GB for the POC; larger SOM for production) |
| P3737 | Carrier board — I/O, networking, power |
| P3730 | The assembled Jetson AGX Orin Developer Kit (P3737 + P3701 + thermal solution) |

`flash.sh` targets are named after carrier + SOM, hence `p3737-0000-p3701-0000-*`.

### Three machines, three roles

```
┌──────────────────────────┐   ┌──────────────────────────────┐   ┌──────────────────────────┐
│ Online RHEL host         │   │ Flashing station (RHEL, x86) │   │ GitHub Actions (internet) │
│ subscription-registered  │   │ standalone, NO network        │   │ ubuntu-24.04-arm runners  │
│                          │   │                              │   │                          │
│ mirror.sh ──► USB key ───┼──►│ install-offline.sh           │   │ Containerfile ──► GHCR    │
│ (BaseOS+AppStream tars)  │   │ flash.sh …-qspi external     │   │ bootc-image-builder       │
└──────────────────────────┘   └──────────┬───────────────────┘   └──────────┬───────────────┘
                                          │ QSPI/UEFI only                    │ ISO / qcow2
                                          ▼                                   ▼
                               ┌──────────────────────────────────────────────────────────┐
                               │ Jetson AGX Orin: install from USB (ISO) onto the eMMC,   │
                               │ later `bootc switch/upgrade` from the air-gapped registry │
                               └──────────────────────────────────────────────────────────┘
```

## Decisions already made (do not reopen without a reason)

1. **Flashing station is RHEL, not Ubuntu.** Ubuntu + SDK Manager was evaluated and dropped.
   NVIDIA validates `flash.sh` only on Ubuntu; QSPI-only flashing works on RHEL and is
   confirmed on our hardware, but it is unsupported — say so in docs.
2. **RHEL 9.8 + JetPack 6.x is the only GA combination.** RHEL 10 is not viable (no NVIDIA
   RHEL 10 L4T repo; a kmod built for 5.14 will not load on 6.12). Do not propose it.
3. **QSPI-only flash, then RHEL bootc on the eMMC.** QSPI carries UEFI and boot firmware only;
   the anaconda ISO installs RHEL to `mmcblk0` (64 GB eMMC). Nothing from the BSP rootfs lands
   on the device. The working command:
   ```
   sudo ./flash.sh p3737-0000-p3701-0000-qspi external
   ```
   Not `jetson-agx-orin-devkit external` — that builds a recovery ramdisk and fails without a
   populated `rootfs/`. `external` is kept because it is what was confirmed; the UEFI boot order
   picks the boot device (ESC at the NVIDIA logo → Boot Maintenance Manager → Boot Options). If
   UEFI will not boot the eMMC, re-flash the QSPI with `internal` first.
   The eMMC is a real constraint: ~58 GiB usable, and poor endurance and latency under etcd's
   fsyncs and write-heavy PVCs. The upgrade path is an M.2 NVMe (`ignoredisk
   --only-use=nvme0n1`, larger root), worth doing before real apps and a model store land.
4. **Base image is Red Hat's JetPack-for-RHEL bootc image**, not `rhel-bootc` + NVIDIA RPMs:
   ```
   quay.io/redhat-user-workloads/jetpack-for-rhel-tenant/rhel-98-bootc:6.2.2_5.14.0-687.42.1_090326003719
   ```
   JetPack 6.2.2, kernel `5.14.0-687.42.1.el9_8`. Inspected 2026-09-03 (arm64 only, bootc
   1.16.4): `/etc/nv_tegra_release` is **R36 REVISION 5.0** (L4T r36.5.0); it carries the
   `nvidia-jetpack-for-rhel-9.8-*` packages, `nvidia-container-toolkit-base` (CDI, no
   `nvidia-container-cli`), `nvgpu.ko`, `nvidia-ctk.service` (writes `/etc/cdi/nvidia.yaml` at
   boot), `nvpmodel`, the console kargs, `podman`, `skopeo` and `subscription-manager`. It is
   built on `rhel9/rhel-bootc` 9.8 (labels), whose layers are already rpm-ostree-chunked (67
   layers); NVIDIA's part sits on top unchunked. Re-inspected 2026-10-06: it carries
   `/usr/libexec/bootc-base-imagectl` (no RPM owns it) with a `rechunk` verb, and
   `rpm-ostree-2026.1-6.el9_8`; no `chunkah`. So our
   layers add **no** NVIDIA packages, CDI unit, kargs or `nvgpu.ko` guard. Pin the full tag,
   never `latest`. Source: `gitlab.com/redhat/rhel/sst/orin-sidecar/rhel-jetpack-for-jetson-bootc`.
5. **The BSP must match the image's L4T line**: flash the QSPI from **R36.5.x** (the staged
   R36.5.2 is fine), never r36.4.x — mismatched firmware and modules hang at boot.
6. **Builds run in GitHub Actions on `ubuntu-24.04-arm`, inside a UBI 9 container.** The
   runner gives native aarch64 (qemu is not viable), the container gives RHEL's
   podman, and `subscription-manager register` gives entitlement. Images go to
   GHCR, then into the air-gapped registry by hand. Pattern from
   `redhat-et/edge-ai-image-pipelines` (Apache-2.0). The host's `/mnt` is mounted as
   `/scratch`, with `/var/lib/containers`, `/var/tmp` and the ISO output bound onto it — for
   space, and because on the container's overlayfs `/` podman loses the native overlay diff
   and every commit walks the rootfs (~20 of 24 build minutes). RHEL's `storage.conf` sets
   `metacopy=on`, which defeats it too, so the step strips it and fails unless `podman info`
   reports `Native Overlay Diff:true`.
7. **Five layers for microshift, one directory per Kubernetes variant.**
   - `base/Containerfile.base` republishes the pinned vendor image under our name, plus field
     tools (`tcpdump` and the like).
   - `base/Containerfile.podman` adds the physically-bound-images machinery and `jtop`.
     Published as `ultron-bootc-bound-images` from CI job `bound_images` (an underscore:
     `needs.bound-images` parses as a subtraction and resolves to nothing).
   - `kiosk/` adds GDM, GNOME Kiosk's script session, Firefox and the `kiosk` user. Shared,
     below the variant: nothing in it is about the cluster, so a service change never reinstalls
     it; a kiosk change does re-run MicroShift's install and image pulls (accepted: it changes
     rarely).
   - `microshift/` adds MicroShift, the device plugin and their images.
   - `services/` holds what runs on the cluster, one numbered kustomize root per component,
     with every image they name embedded.
   Service images sit **above** the variant layer so changing one does not re-run the
   MicroShift install and re-pull its nine images. Each layer is pushed as
   `ultron-bootc-<name>` and the next builds on its **digest**. CI is two reusable
   workflows (`build-image.yml`, `build-iso.yml`) plus `ultron.yml`, chaining base →
   bound-images → kiosk → microshift → services → ISO. The build context is the repo root. Every
   layer registers with subscription-manager, even the one that installs nothing: one code path.
8. **NVIDIA BSP download stays manual** (documented in `README.md`). Scripting it was fragile.

## What is done and working

### Flashing station (`jetson-installer-config`)

- `mirror.sh` — on an **online, registered RHEL host**: a UBI container with the host's
  entitlement bind-mounted read-only runs `dnf reposync --download-metadata --newest-only` for
  BaseOS and AppStream and tars them into `dist/`. Flags: `-r 9|10`, `-A arch`, `-o dist`,
  `-m mirror`, `-c podman|docker`, `-a` all versions, `-z` gzip (off: RPMs are already
  compressed). An `rpm -K --nosignature` pre-check catches RPMs truncated by a full disk.
- `install-offline.sh` — **as root on the station**: extracts to `/srv/repos/{baseos,appstream}`,
  writes `offline.repo` (`file://`, `gpgcheck=1`), disables the subscription-manager plugin,
  installs `dtc cpp binutils usbutils lz4` (`-P` skips). Repos only.
- `README.md` — BSP links, extract, recovery mode, `flash.sh`, then UEFI's display hand-off
  to Never (the kiosk monitor stays black otherwise).

Both are idempotent and have been run end to end: station provisioned, devkit QSPI flashed.

### Image + ISO pipeline

- `base/Containerfile.base` — the pinned vendor image, field tools and `bootc container lint`.
  Its smoke test checks the vendor image: `skopeo`, `podman`, and `lvm2` (root is on an LV and
  LVMS needs `vgs`; nothing here installs it).
  - Field tools (a node has no repo and a read-only `/usr`): `tcpdump`, `mtr`, `nmap-ncat`,
    `pciutils`, `strace`, `sysstat`, `tmux`, `usbutils`; `bind-utils`, `ethtool`, `lsof`,
    `NetworkManager-tui`, `psmisc` and `sos` come with the vendor image, listed so a bump cannot
    drop them. ~12 MiB. `sar` logs to `/var/log/sa` every 10 min for 28 days (RHEL's preset).
    Not added: `htop`/`iftop` (EPEL), `tshark`, `nvme-cli` (with the NVMe).
- `base/Containerfile.podman` — `FROM` that via `ARG BASE_IMAGE`:
  - `embed_image.sh`, `copy_embedded_images.sh` and `copy-embedded-images.service`, `COPY`d
    from `base/physically-bound-images/`.
  - `jetson-stats` (`jtop`, pinned `JTOP_VER`) via `pip3 install --prefix=/usr` (`/usr/local`
    is machine state on bootc) `--only-binary=:all:` (the sdist's `setup.py` would install the
    unit and `groupadd jtop` itself, as root, in the build). `python3-pip` comes from RHEL repos, so this layer needs
    entitlement. `jtop` is a client of `jtop.service` (`/run/jtop.sock`). The wheel ships
    the unit only as a template (`/usr/share/jetson_stats/`) saying `/usr/local/bin/jtop`, and
    root's first `jtop` copies it into `/etc/systemd/system` when none is there: on hardware
    that unit sat in `activating` forever. The build fixes the template's path and installs it
    as `/etc/systemd/system/jtop.service`, enabled: in `/etc` because that is the path jtop
    checks (a symlink there to `/usr/lib` is `bad` to systemd). The smoke test fails unless the
    unit's `ExecStart` binary is executable. Whether `jtop` reaches the driver is unverified.
  - `flightctl-agent` from `rhacm-${ACM_VER}-for-rhel-9-$(uname -m)-rpms`
    (`ACM_VER=2.15`, match the hub), no weak deps. Drop-ins key both
    the agent and `bootc-fetch-apply-updates.service` on `/etc/flightctl/config.yaml`: agent
    idle and bootc upgrading before enrollment, the reverse after. Idle is `inactive`, not
    failed (seen on hardware). Greenboot is on the node anyway (`microshift-greenboot`), and
    the package's required check waits 150 s for the agent to be active: unguarded, every
    upgrade failed it, rebooted twice and rolled back. The build inserts
    `[ -f /etc/flightctl/config.yaml ] || exit 0` as its second line (exactly one check
    script, or the build fails); the smoke test runs it and fails unless it passes at once.
  Its smoke test fails if this layer has an image cache: anything here is paid by every variant.
- `base/physically-bound-images/` — adapted from `redhat-et/edge-ai-image-pipelines`. Cache is
  `/usr/lib/containers-image-cache` with `mapping.txt` (reference → sha), copied into
  containers-storage once per boot by `copy-embedded-images.service` (a oneshot `Requires=`d by
  microshift.service, not an `ExecStartPre=`, so it runs once per boot). No
  `network-online.target`: the copy is local, and waiting for a carrier would stall every boot.
  - `embed_image.sh` splits `repo:tag@sha256:…` references, which skopeo rejects, and skips a
    reference already cached. Nothing dedupes across layers: re-embedding an image one layer
    down ships it twice.
  - Copies use `--multi-arch=system`: only aarch64 is stored. A reference pinned to a
    manifest-list digest still resolves, because containers-storage looks up by name first.
  - Hardlinking duplicate blobs was tried and removed: `/usr` is ostree, already
    content-addressed on the node.
  - `copy_embedded_images.sh` removes images a previous OS version put in containers-storage
    and this one no longer names, tracked in `/var/lib/physically-bound-images/applied.txt`.
    Otherwise the first thing to prune would be kubelet's image GC at 85% disk, deleting
    exactly the images there is no registry to re-pull. Prune runs before copy; an image still
    held by a container stays on the list for next boot; failures are logged, never fatal.
  - **Pinned in CRI-O** (`microshift/crio.conf.d/20-pinned-images.conf`): kubelet's image GC and
    disk-pressure reclaim skip embedded images (an unused Triton would otherwise be gone until
    the next boot); the prune still removes them, since podman ignores CRI-O pins. Registry
    prefixes for every layer (`docker.io`, `ghcr.io/external-secrets`, `nvcr.io`, `quay.io`,
    `registry.redhat.io`), `services/` included. GHCR by repository only: our OS images live
    there, and anything pulled from it would never be collected. **One list**: a second drop-in
    replaces it, so a new registry goes in this file. **Never pin a pulled image**: nothing
    would delete it. So no `registries.conf` mirror for a pinned registry, and air-gapped app
    layers embed from `<registry>/embedded/*`, pull from `<registry>/apps/*`. Both smoke tests
    check every `mapping.txt` reference against `crio config`. GC thresholds are untouched.
- `kiosk/Containerfile` — **its display fixes were found on hardware by hand (jetson-1,
  2026-11); the image with them is unbuilt.** Red Hat's
  documented kiosk, kept deliberately plain, plus fixes for gaps in the vendor image (below):
  `dnf install gdm gnome-kiosk-script-session firefox
  dejavu-sans-fonts` (DejaVu covers Hebrew), `systemctl enable gdm`, `set-default
  graphical.target`. **No autologin**: GDM's login screen asks for `kiosk`'s password (the
  maintainer's call). The password is **in the image**, not the kickstart (the maintainer's
  call, knowing every registry holding the image then holds the hash): the build gets `JETSON_KIOSK_PASSWORD_HASH` as a `podman build --secret`, rejects an
  empty, whitespace or non-crypt value as the layer's first step, and stores it
  `/usr/lib/jetson-kiosk/password-hash`, `0600`. A `systemd-sysusers.service` drop-in
  (`LoadCredential=passwd.hashed-password.kiosk:…`; RHEL's unit loads only root's) hands it to
  sysusers, which sets it when it **creates** `kiosk` (UID 1500: a regular user like any GDM
  login, above `cloudlet`; a shell, because GDM starts the session through it) and never touches
  an existing user. So the first boot sets it, a node `bootc switch`ed onto the image gets it
  too, a later hash in a new image reaches no installed node, and a `passwd kiosk` on a node is
  never undone. The credential is systemd ≥ 249 (RHEL 9 has 252); seen working on 255 only.
  `sshd_config.d/40-jetson-kiosk.conf` says `DenyUsers kiosk`: RHEL's sshd takes passwords, and
  the screen password must not open a shell over the network. **No way out** (asked for by the
  maintainer; all configuration): `/etc/pam.d/login` gets `pam_succeed_if.so user != kiosk` as
  its first `account` line, so the text consoles (Ctrl-Alt-Fn) and the serial `ttyTCU0` refuse
  `kiosk` while `cloudlet` still logs in there; GDM uses `gdm-password`, untouched. First,
  because a `sufficient` line in an included stack would end it early (RHEL's `system-auth`
  account has none today). `nologin` as the shell was not an option: GDM starts the session
  through it. `/usr/share/polkit-1/rules.d/10-jetson-kiosk.rules` answers NO to every polkit
  action for `kiosk` (an active local session may otherwise reboot, change system network
  settings, `pkexec`); `10-` so it is the first rule by name across `/etc` and `/usr/share`,
  which is the order polkit asks them in. `kiosk` is in its own group and `video` (the GPU
  nodes, below), so no `sudo`.
  Not done: a confined SELinux user (`user_u`, `user_exec_content` off) would also stop it
  running what it downloads, but whether a confined user can open the Tegra display and GPU
  nodes is unknown, and `kiosk` exists only from first boot; revisit after hardware. Code
  running as `kiosk` still has the node's network, and can fill `/var`. `tmpfiles.d` creates
  its home, links
  `~/.local/bin/gnome-kiosk-script` (what `gnome-kiosk-script` execs) to
  `/usr/libexec/jetson-kiosk/gnome-kiosk-script`, writes
  `/var/lib/AccountsService/users/kiosk` with `Session=gnome-kiosk-script`, and marks
  `cloudlet` `SystemAccount=true` so the login screen lists only `kiosk`: all `/var`, which the
  image does not deploy. Still one tap (or Enter) on `kiosk` before the password: GNOME Shell
  40's greeter never selects a lone user itself (`loginDialog.js`), and `disable-user-list`
  asks for a username instead; skipping it needs greeter code. **Branding**:
  `kiosk/login-logo.png` replaces Red Hat's logo through `/etc/dconf/db/gdm.d/10-jetson-kiosk-logo`
  and a build-time `dconf update` (Red Hat's is only a schema default, gdm's
  `org.gnome.login-screen.gschema.override`; drawn at the file's own pixel size), and
  `kiosk/avatar.png` is `kiosk`'s picture via `Icon=` in the AccountsService file; both land in
  `/usr/share/jetson-kiosk/`, PNG only. Both come from `cloudlet-logo-light-bg.svg` (not in
  the repo): the logo with the wordmark recoloured `#FFFFFF`/`#C9D1CF` for the greeter's dark
  grey (the original's near-black text vanished there), padding trimmed, 56 px tall. The avatar
  is the unit emblem (a 1920² PNG with transparent corners) at 236 px on a white 256×256
  square: full size, its black ring sat on GNOME's circle crop and met the dark grey.
  **Background** (the maintainer's request; the one package file this layer rewrites): GNOME 40
  has no setting for it, only the theme's `#lockDialogGroup { background-color: #282828 }`
  inside `/usr/share/gnome-shell/gnome-shell-theme.gresource`. A throwaway `shell-theme` stage
  (`FROM kiosk`, installs `glib2-devel` for `gresource`/`glib-compile-resources`) runs
  `kiosk/shell-theme.sh`: extracts every file, appends `kiosk/login-background.css` to
  `gnome-shell.css` (last, so it wins), recompiles uncompressed, and fails unless the stock CSS
  has `#lockDialogGroup`, the file list is unchanged and the CSS ends with ours; the final stage
  `COPY --from`s only the result. `rpm -V gnome-shell` flags the file. `kiosk/login-background.png`
  is the maintainer's 1920×1080 brand backdrop with its centre cloud and `CLOUDLET | MAMRAM`
  removed (masked against a 61 px median and filled harmonically, so the glows' bands survive):
  the user list sits in the centre and the logo at the bottom. `background-size: cover`. The build deletes every other session file: GDM pulls in GNOME Shell's
  (`gnome.desktop`, `gnome-wayland.desktop`), which the login screen's session menu would offer
  as a full desktop. RHEL 9's kiosk session is `gnome-kiosk-script`, not the newer
  `gnome-kiosk-script-wayland`: the first dispatch (run 40) failed on exactly that. The package
  ships it in both `wayland-sessions` and `xsessions` under that one name, which GDM treats as
  one session (Wayland preferred); the smoke test compares names, not files (run 41). Once logged in, the session stays until reboot: GNOME Kiosk has no
  screen lock, and idle lock was offered and declined (custom code). The script sources
  `/etc/jetson-kiosk.conf` and loops: wait
  for any DRM connector `connected` (sysfs, every 2 s; no monitor, no Firefox decoding video),
  wait until `KIOSK_URL` answers anything but a 5xx (`curl -k`, reachability only), run
  `firefox --kiosk` in the background and kill it after 10 s without a monitor, then restart
  after 1 s, or with back-off (2, 4 … 60 s) when Firefox died on its own within a minute. A
  `while` loop rather than the template's `exec "$0"`, so the back-off survives a restart.
  Rendering is the defaults: GPU where the drivers allow, unmetered against Triton.
  - **The vendor image has the display stack** (inspected 2026-10-21): `nvidia.ko`,
    `nvidia-modeset.ko`, `nvidia-drm.ko` under `updates/opensrc-disp/`, `nvidia-drm modeset=1
    fbdev=1`, NVIDIA's EGL vendor file, `libnvidia-egl-gbm`, `libnvidia-egl-wayland`,
    `gbm/nvidia-drm_gbm.so`, and an Xorg `nvidia_drv.so` (Xorg itself comes in with `gdm`; it
    ran on hardware). `load-nvidia-drm.service` is `WantedBy=graphical.target` and the vendor sets
    `multi-user.target`, so the display driver loads only because this layer switches the
    target. Video decode is CPU either way (no VA-API on Tegra).
  - **Display fixes, found on hardware** (jetson-1, 2026-11; each removed alone brought its
    failure back). Gaps in the vendor image, worth a Red Hat case, not features:
    - **Firmware, not the image:** UEFI's *SOC Display Hand-Off Mode* must be **Never** (ESC →
      Device Manager → NVIDIA Configuration → Boot Configuration; a UEFI variable in QSPI). The
      Jetson default, Auto, leaves UEFI's picture running when a monitor is connected at boot,
      and the image's driver cannot take it over: "Input Signal Not Found" after GRUB, with
      `NVRM_RPC_DCE: Failed RM ctrl call` for `0x731341` (DP AUX) and `0x731343` (link
      training). Plugged in after boot it worked. A step after every QSPI flash (installer
      `README.md` §5; the flash resets it). Not the cause:
      the display firmware, QSPI layout and DTBs are byte-identical in R36.5.0 and R36.5.2.
    - `libEGL_nvidia.so.0` is in `/usr/lib64/tegra-egl`, outside the loader path; the vendor
      ships `tegra-egl/ld.so.conf` but never links it. Without it glvnd hands out Mesa's EGL,
      mutter says `The GPU /dev/dri/card1 chosen as primary is not supported by EGL` and GDM
      falls back to X. Linked into `/etc/ld.so.conf.d`, `ldconfig` at build.
    - GDM's `61-gdm.rules` writes `WaylandEnable=false` for any NVIDIA driver without
      `nvidia-sleep.sh`, which Tegra has not: masked in `/etc/udev/rules.d`.
    - `gdm` and `kiosk` in `video` (sysusers `m`): `nvmap`, `nvhost-*` and `nvgpu/*` are
      `root:video 0660`, as on NVIDIA's own Ubuntu (`99-tegra-devices.rules`).
    - SELinux module `jetson-gpu` (`kiosk/jetson-gpu.cil`, `semodule -n -i` at build; a module
      is named after its file, and jetson-1's hand-made one is `jetson-root`): those nodes are
      `device_t` and the login screen (`xdm_t`) is denied them; labelled `dri_device_t`. The
      session runs unconfined.
    - A `gdm.service` drop-in `restorecon`s `/dev/nvidia-modeset` first: NVIDIA's udev rule
      `mknod`s it, so it is `device_t` every boot though the policy says
      `xserver_misc_device_t`.
    - `sleep`, `suspend`, `hibernate`, `hybrid-sleep` targets masked: GNOME's login screen may
      suspend on idle, and a suspended node stops MicroShift. Blanking is left at GNOME's
      default (the maintainer's call).
  - **Input**: `usbhid`, `hid-generic`, `evdev` built in; `hid-multitouch`, `wacom`, `hid-elan`
    as modules, so USB keyboards, mice and HID touch screens work through libinput; non-HID
    touch controllers (`CONFIG_INPUT_TOUCHSCREEN` off) do not. Layout `us` from the kickstart.
    No on-screen keyboard in the session (GNOME Kiosk and Firefox have none): a touch-only
    screen needs the frontend's own. Whether GDM's login screen offers one on touch is unverified.
  - `/etc/jetson-kiosk.conf`: `KIOSK_URL`, a **placeholder** (`http://jetson-1.cloudlet.local/`)
    until the frontend's Route host is known. It resolves only through the network's DNS since
    the `%post` `/etc/hosts` line went; the real host must resolve with the cable out. HTTPS
    needs the signing CA in `/etc/pki/ca-trust/source/anchors`: RHEL's Firefox reads the system
    trust via p11-kit.
  - `/etc/firefox/policies/policies.json`: no updates, telemetry, studies, safe-browsing or
    OpenH264 downloads; no disk cache; no crash-restore page; `WebsiteFilter` blocks
    `file:///*` (a file picker would otherwise browse the disk; uploads through
    `<input type=file>` still work, which is the frontend's business); no devtools,
    `about:config`, private windows; no troubleshoot mode, profile refresh, `about:support`,
    printing (its dialog has a file chooser) or extension installs. `about:preferences` has no
    route in kiosk mode (no menu, no shortcut; web content cannot navigate to it), so it is not
    filtered. JSON has no comments, so the why is in the Containerfile.
  - What the frontend must live with: **no H.264** (no decoder in RHEL's Firefox offline), no
    CDN or web fonts, and reconnecting its own streams.
  - **Tried and dropped as too complicated** (branch history): a custom `jetson-kiosk.service`
    on tty1 instead of GDM, with CPU/memory caps; a GPU variant with GNOME Kiosk as a bare
    Wayland compositor and a smoke test requiring NVIDIA's EGL/GBM (`a4607a1`). Go back to one
    only for a measured reason. The CPU-only variant (Xorg `modesetting`, no acceleration,
    custom service) is kept as branch `claude/kiosk-xorg-cpu` (`9ba1b12`); not needed since
    GDM runs Wayland on NVIDIA's EGL on hardware with the fixes above.
  - Smoke test: default target `graphical.target` and `display-manager.service` → gdm; then it
    reads the hash file the drop-in names, fails unless it is `0600`, runs `systemd-sysusers`
    with it as the credential and `systemd-tmpfiles --create` in the throwaway test container,
    as a boot would, and checks `kiosk` exists with that hash in `/etc/shadow`, the
    AccountsService session is the only session file the login screen offers, the logo
    `DCONF_PROFILE=gdm dconf read` returns, the `Icon=` and the last `url(file://…)` in the
    theme resource are PNGs in `/usr/share/jetson-kiosk` (a stale database reads empty; a
    reinstalled theme names none), the linked
    script is executable and parses,
    `gnome-kiosk-script` still execs `~/.local/bin/gnome-kiosk-script`, `sshd_config` still
    includes `sshd_config.d` (else `DenyUsers` is ignored silently), no terminal emulator or
    file manager got pulled in, `kiosk` has no group but its own and `video`, `gdm` is in
    `video`, the loader cache has the library NVIDIA's EGL vendor file names, `matchpathcon`
    gives `dri_device_t` for `nvmap`, `nvhost-*` and `nvgpu/*`, `/etc/pam.d/login`'s first
    `account` line refuses `kiosk`, `10-jetson-kiosk.rules` is the first polkit rule by name,
    and the policy parses.
    Locally: the hash step against good, missing, empty, plaintext and multi-line input; sysusers
    with the credential and tmpfiles against a scratch root (the hash reaches `shadow`; an
    existing `kiosk` keeps its password; escapes expand, link lands), and the
    script against a fake DRM sysfs, stub Firefoxes and a local server: no monitor → nothing;
    plug → Firefox in 1 s; unplug → SIGTERM 10 s later; replug → back; a Firefox that exits at
    once → restarts after 2, 4, 8, 16 s.
- `microshift/Containerfile` — MicroShift 4.20 from `rhocp-4.20-for-rhel-9-aarch64-rpms` +
  `fast-datapath-for-rhel-9-aarch64-rpms` (`dnsmasq firewalld jq microshift
  microshift-release-info openshift-clients`; `oc` is in `openshift-clients`), firewall rules (trusted: `10.42.0.0/16`,
  `10.43.0.0/16`, `169.254.169.1`; public: 22, 443, 6443), `microshift-make-rshared.service`,
  the node IP on `lo` (below), every MicroShift image embedded with a `microshift.service.d`
  drop-in ordering the copy first, and the NVIDIA device plugin:
  - `nvidia-ctk runtime configure --runtime=crio --set-as-default` →
    `/etc/crio/crio.conf.d/99-nvidia.toml`.
  - `microshift/manifests/` → `/usr/lib/microshift/manifests`: kustomization, a ConfigMap with
    **GPU time slicing** (4 replicas of `nvidia.com/gpu`), and a patch mounting it via
    `CONFIG_FILE`; only
    `nvidia-device-plugin.yml` is curl'd. One iGPU means one GPU pod without slicing. No memory
    isolation between replicas, so the count is a claim about the SOM's RAM; 1 disables it.
    `renameByDefault` stays off, so the resource is plain `nvidia.com/gpu`.
    `deviceIDStrategy: index`: the default `uuid` hands the runtime `tegra`, which its csv
    mode refuses, and no GPU container starts (seen on hardware). The smoke test fails if
    the container sets `DEVICE_ID_STRATEGY`, which would override it.
  - A second patch sets the container's `seLinuxOptions.type: spc_t`. As `container_t`,
    SELinux denies the connect to `kubelet.sock` and the plugin loops on `Could not register
    device plugin: context deadline exceeded` (seen on hardware). Capabilities stay dropped.
    No SCC: OpenShift's apiserver skips SCC admission in `kube-system` (run-level 0 by name),
    which is also why upstream's hostPath is admitted. Moving the plugin out needs one.
  - The smoke test checks how the render is **wired** (one container, `CONFIG_FILE` into a
    mounted ConfigMap with a replica count, `/var/lib/kubelet/device-plugins` mounted), never
    upstream field names: those change between tags and broke an earlier version of the check.
  - No `microshift-gitops` (removed). Images go into the main store, not an additional store:
    images pulled later would reuse its layers, and an upgrade that drops one breaks them
    (RHEL-75827, still open 2026-10; the `dir:` copy with `mapping.txt` is the workaround
    written on it). **No `dnf upgrade`**: it could pull a kernel the Tegra kmod was not built
    for. `--enablerepo`, not `dnf config-manager`. Units are `COPY <<'EOF'` heredocs; RHEL 9's
    podman parses them.
- `microshift/manifest-images.sh` — prints every image the given manifest roots name, rendered
  with `oc kustomize` (release-info lists only the control plane, and `images:` transformers
  defeat a grep). The build embeds what it prints; `services/` uses it too.
- `services/Containerfile` — six numbered roots under `/usr/lib/microshift/manifests.d/`, plus
  every image they name. MicroShift **sorts** the roots and applies each with the equivalent of
  `kubectl apply -k`, retrying a failing one **every 10 s for 10 minutes**
  (`pkg/kustomize/kustomize.go`) — that is the ordering and what covers a CRD not yet served.
  **Manifests live in `/usr/lib`, never `/etc`** (MicroShift's own split: `/etc` for what a
  management system puts on a node, `/usr/lib` for what the image embeds). `/etc` is node state
  merged on upgrade, so a manifest once edited on a node keeps that version past every later
  image, and can name an image no longer embedded. Order is unchanged: MicroShift reads
  `/usr/lib/…/manifests`, `/usr/lib/…/manifests.d/*`, then the `/etc` pair. The `/etc` pair
  stays the place for a deliberate per-node override. Red Hat's optional RPMs (`microshift-olm`
  and the like) put `00N-microshift-*` roots in the same `manifests.d`; none is installed. One
  would be embedded by `services/` and held to its smoke test's rules, which it likely fails
  (resource ratios). MicroShift's **config** has no `/usr` path (`/etc/microshift/config.yaml`
  and `config.d` only), so `config.d/` stays in `/etc`; `ostree admin config-diff` shows a node
  that drifted.
  - `010-cert-manager/` — upstream static manifest (`CERT_MANAGER_VER`, v1.21.2), patched for
    resources only. KServe's webhook certificate comes from it.
  - `015-device-ca/` — the node's own CA. Self-signed `Issuer` `device-ca-bootstrap` →
    `Certificate` `device-ca` (`isCA`, ECDSA P-256, 87600h, **`rotationPolicy: Never`**:
    renewal keeps the key so old leaves and stale bundles still verify; cert-manager's default
    became `Always` in v1.18) → `ClusterIssuer` `device-ca`. All in `cert-manager`, the
    controller's `--cluster-resource-namespace`. The key is generated on the node, lives in
    etcd, survives reboots and upgrades, and is never in the image: two nodes from one ISO have
    different CAs, with the same CN (no per-device hostname yet). Beside `010`: it needs only
    cert-manager's webhook, which `030` waits on anyway for KServe's Certificates.
  - `020-external-secrets/` — upstream manifest (`EXTERNAL_SECRETS_VER`, v1.2.0; image on
    `ghcr.io` from v1.1, `oci.external-secrets.io` before):
    - Each Deployment's patch deletes the `runAsUser: 1000` upstream pins (restricted-v2 assigns
      a UID from the namespace range and refuses a pinned one) and adds resources.
      `runAsNonRoot: true` stays.
    - Moved from `default` to namespace `external-secrets-operator` via `namespace.yaml` and
      a `namespace:` line. The transformer misses three namespaces inside container args
      (`--service-namespace`, `--secret-namespace`, `--dns-name=…<ns>.svc`), so those are JSON
      patches, each guarded by a `test` op. Getting one wrong leaves the webhook without a
      valid certificate, and no ExternalSecret can be created.
    - The strategic-merge patches still say `namespace: default`: patches run before the
      namespace transformer.
    - **Generic targets on** (`controller-args.yaml` appends `--unsafe-allow-generic-targets`,
      `generic-targets.yaml` a ClusterRole writing ConfigMaps, as the chart's
      `genericTargets.enabled`): an ExternalSecret may write a ConfigMap. Needs ESO ≥ v1.0
      (`target.manifest`); the flag without the role is an error in every namespace.
    - No external store yet, so what it reads from is unsettled.
  - `025-device-ca-bundle/` — ConfigMap `ca-bundle` (key `ca.crt`) in every namespace. **Two
    hops**, because ESO's Kubernetes provider reads a Secret whole and a `ClusterSecretStore` can
    be named from any namespace: one able to read `device-ca` would hand anyone with
    ExternalSecret rights `tls.key`.
    - `public-copy.yaml`: in `cert-manager`, SA + Role (`get`, `resourceNames: [device-ca]`) +
      namespaced `SecretStore` + ExternalSecret copying `tls.crt` (not `ca.crt`: that becomes an
      org root if one ever signs this CA) to Secret `device-ca-public`.
    - `distribute.yaml`: SA + Role (`get`, `resourceNames: [device-ca-public]`) +
      `ClusterSecretStore` (no `conditions`; harmless, it only reaches the public copy) +
      `ClusterExternalSecret` (`namespaceSelectors: [{}]`, every namespace incl. future ones,
      `target.manifest` ConfigMap).
    - Both stores reach the API at `kubernetes.default`, verified with `kube-root-ca.crt`. No
      rule for `selfsubjectrulesreviews` (store validation): `system:basic-user` grants it,
      and a Role could not (cluster-scoped). Validation accepts a `resourceNames` rule.
    - `025`, not beside `015`: its kinds are ESO's. MicroShift applies roots **one at a time**
      and gives up on one after the 10 minutes, never returning until it restarts, so before
      `020` it would stall every first boot 10 minutes and then never apply. **A root sorts
      after everything it needs.**
    - Rejected: **trust-manager** (the purpose-built tool) ships only as a Helm chart, so a new
      tool in the build and another image; ESO is already here.
  - `030-kserve/` — upstream `kserve.yaml` (`KSERVE_VER`, v0.20.0; v0.21.0 had no release
    assets and adds a DaemonSet with no nodeSelector). `kserve-cluster-resources.yaml` is not
    fetched: fourteen runtimes' images would be embedded. Only `kserve-controller-manager`
    runs; its manager is patched to `imagePullPolicy: IfNotPresent` (upstream says `Always`,
    which was ErrImagePull on hardware with the image embedded). Deleted, which also keeps their images out: `llmisvc-controller-manager` (LLM
    serving, pins `runAsUser: 1000`), both local-model-cache workloads (off; the agent mounts a
    hostPath), and the `ClusterStorageContainer` (only downloading URIs use it). Their CRDs and
    webhooks stay; each matches only its own kinds.
    `inferenceservice-config.yaml` rewrites three JSON keys whole: `deploy` → `Standard`,
    `ingress` → `disableIngressCreation: true`, and `storageInitializer` → qualified image,
    1:1 / 1:4, **no `uidModelcar`** (KServe sets it as `runAsUser` on the modelcar sidecar and
    `kserve-container`, and restricted-v2 refuses 1010; unset, the pod gets one UID, which the
    sidecar's `/proc/<pid>/root` needs). A modelcar image needs `sh`, `ln`, `sleep` and a
    non-empty `/models`. `namespace.yaml` keeps upstream's `control-plane` label, which the pod
    mutator skips, so no InferenceService may live in `kserve`. No Pod Security labels: one was
    tried and removed, since it only differs from restricted-v2 once a wider SCC is granted.
  - `040-triton-runtime/` — `triton-igpu`: `-py3-igpu` image (`25.02`, **unverified against
    JetPack 6.2.2**), one `nvidia.com/gpu`, no `runAsUser`, restricted security context
    spelled out, 8Gi 1:1, CPU 1 → 4, TensorRT and ONNX. Pod-wide settings such as
    `supplementalGroups` go on the InferenceService. Plans load only in this image's TensorRT:
    build them with its `trtexec` on an Orin, and rebuild when the tag moves.
  **Resources rule**, every root: memory request = limit (OOM-killed at its own ceiling, never
  evicted for outgrowing a request), CPU limit = 4 × request (burst room at start-up). Pods
  stay Burstable. Upstream sets almost none of this.
  **Images are derived from the render**: the version ARGs are the only pin. Seven today
  (`015`/`025` add none): cert-manager ×3, External Secrets, `kserve-controller`,
  `kube-rbac-proxy`, and `tritonserver:25.02-py3-igpu` (the largest). The scan reads only
  `image:` fields, so a model's `oci://` image, and images named inside
  `inferenceservice-config`, go in `SERVICE_IMAGES` when used.
  **Smoke test**: renders every root with `oc kustomize` and checks the workload set per root;
  External Secrets without `runAsUser`, with `runAsNonRoot`, in its own namespace and naming
  `default` nowhere outside its CRDs; `inferenceservice-config` values; every pod template and
  serving-runtime container admissible under restricted-v2; requests, limits and ratios; no
  container whose pull policy is, or defaults to, `Always`; every image qualified and embedded;
  every `mapping.txt` reference pinned by `crio config`; no `ClusterStorageContainer`; one
  KServe tag. It prints `du -sh` of the cache, which the eMMC pays for twice
  (`/usr` and containers-storage). Pods KServe builds at run time are in no render: their
  admission and GPU access are hardware questions.
- `config.toml` — project-wide bib config with a **custom kickstart** (bib then adds only
  `ostreecontainer`; `[customizations.user]`/`filesystem` cannot be combined with it):
  `text --non-interactive`, `timezone Asia/Jerusalem --utc`, static `192.168.1.10/24` gw
  `192.168.1.254` on `eth0`, `--nameserver=192.168.1.1` (must answer, or every lookup waits out
  the glibc timeout), `--no-activate` (anaconda otherwise brings up the first `network` device
  and waits for it; the install reads only the ISO, so no cable is needed),
  `--ipv4-dns-search=cloudlet.local` (there is no `--domain`; an unknown option fails the parse
  and stops the installer before its UI), `--hostname=jetson-1`,
  `ignoredisk --only-use=mmcblk0`, `clearpart --all`, `reqpart --add-boot`, VG `rhel` with a
  40 GiB xfs root, **no swap**, and **~16.5 GiB left free for LVMS** (fill the VG and the
  cluster has no dynamic PVs). Root locked; user `cloudlet` in `wheel` from
  `@JETSON_SSH_PUBKEY@`/`@JETSON_PASSWORD_HASH@`; `reboot --eject`. ISO label
  `ULTRON`. Address and hostname are baked in, so two devices from
  one ISO collide. No `%post`: the extra API SAN and the `/etc/hosts` entry were removed, so
  the laptop reaches 6443 through an SSH tunnel with the loopback kubeconfig.
- **Node IP on `lo`** (`microshift/stable-microshift.nmconnection`,
  `microshift/config.d/10-node-ip.yaml`) — Red Hat's fully-disconnected procedure. Without
  `nodeIP`, MicroShift uses the default-route address and `sysconfwatch` restarts it whenever
  that changes, which pulling the cable does. The keyfile puts `10.44.0.1/32` on `lo` with a
  placeholder nameserver `10.44.1.1` at `dns-priority=200`; it was generated once with
  `nmcli --offline` (fixed UUID) and is `COPY`d `0600` (NM ignores readable keyfiles).
  `ignore-carrier` was rejected: it keeps MicroShift tied to `eth0`. A node initialised on
  `192.168.1.10` needs `microshift-cleanup-data --ovn` or a re-image. A clock step over 10 s
  (first chrony sync) can still cost one restart.
- **Split DNS** — NM's `dns=dnsmasq` plus `server=/cluster.local/10.43.0.10` (CoreDNS) lets
  the node resolve full `<svc>.<ns>.svc.cluster.local` names. dnsmasq, not systemd-resolved
  (Tech Preview on RHEL 9). `/etc/resolv.conf` becomes `127.0.0.1`, so
  `config.d/20-kubelet-resolv-conf.yaml` points kubelet (and so CoreDNS's upstream) at
  `/run/NetworkManager/no-stub-resolv.conf`. Unverified on hardware.
- `.github/workflows/build-image.yml` — **reusable**: register, bind storage for native
  overlay, write the pull secret, build, run the smoke test inside the result, push
  `ghcr.io/<owner>/ultron-bootc-<name>`, output the digest-pinned ref, and report the
  layer size as a `::notice`. Tags: `<YYYYMMDD-sha8>` on every build; `latest` and `stable`
  only when `GITHUB_REF` is `refs/heads/main` (the caller's ref), so dispatching a branch to
  test it moves neither. No MicroShift-version tag: `USHIFT_VER` is set once, as the
  Containerfile's `ARG` default. The `also-as` name is validated before the build. `also-as` pushes
  the same tags under a second name: `services` is also `ghcr.io/<owner>/ultron-bootc`, the finished
  OS under the project's name. Its digest should equal the first (same compressed layers); a
  mismatch is a `::warning`, not a failure, since nothing builds on it. The ISO and the chain
  use `ultron-bootc-services`.
  `rechunk: true` (services only) runs `bootc-base-imagectl rechunk` between build and smoke
  test, inside the image it rewrites (that is where the tool and `rpm-ostree` are), with the
  builder's store and `storage.conf` mounted in; it wraps `rpm-ostree experimental compose
  build-chunked-oci --bootc --format-version=1`. Tags move onto the result, which must pass
  `bootc container lint`, so the push, `also-as` included, carries the rechunked image; layer
  count is a `::notice`, per-layer sizes go to the log. Why:
  a plain build stamps every layer with the build's mtimes, so an unchanged rebuild gets new
  digests and a node or mirror re-fetches everything. Rechunked, `services` shares no blobs
  with the layers below. Run 36 went green end to end, ISO included: ~6.5 min nested in the UBI
  container (683 packages, 46615 objects, 3.85 GB of RPM content), 65 layers, lint and smoke
  test pass on the output, 88 GB still free, 9506 MiB image. But one layer,
  `rpmostree-unpackaged-content and initramfs`, is **6.35 GB**: the whole image cache (5.7 GB,
  17 images) and every other file no RPM owns, rpmdb and `/etc` edits included. So only the
  ~3 GB of RPM content splits per package; the big layer most likely changes on every build.
  Still unverified: whether two builds of unchanged content share any digests.
  **What a node follows is not settled.** bib installs the services layer pinned by digest
  from GHCR, so `bootc upgrade` has nothing to re-resolve and could not reach it anyway.
  `ostreecontainer` has no `--target-imgref`. Pointing the origin at the air-gapped `stable`
  needs a one-time `bootc switch` or a retag before bib; the node also needs
  `/etc/ostree/auth.json`. Until then a node cannot upgrade. Check
  `bootc-fetch-apply-updates.timer`: it fails every day the registry is unreachable.
- `.github/workflows/build-iso.yml` — **reusable**: register, substitute the `@JETSON_*@`
  placeholders in bash with secrets in `env:` (a `&`, quote or newline would break `sed`),
  reject an empty or non-crypt password hash, validate the rendered kickstart with RHEL's
  `ksvalidator -v RHEL9` (bib does not, and a parse failure only shows on hardware), run
  `registry.redhat.io/rhel9/bootc-image-builder --type anaconda-iso`, then rewrite the ISO's
  GRUB menu timeout from 60 s to 5 s with `xorriso`/`mtools`: in `/EFI/BOOT/grub.cfg` and in
  the copy inside `images/efiboot.img`, which is the one UEFI GRUB reads
  (`-boot_image any replay` keeps the El Torito entry and volume ID). The rewrite drops the
  implanted md5, so "Test this media" cannot verify the stick; unused, not restored. Upload
  the `*.iso` alone (no checksum file) at zip `compression-level: 9`, the maintainer's call; it is
  mostly gzip'd layers and squashfs, so the saving is small and the upload slower.
- `.github/workflows/ultron.yml` — the only caller, on push to `main` under
  `base/**`, `kiosk/**`, `microshift/**`, `services/**`, `config.toml` or the workflows, and on
  `workflow_dispatch`. **Nothing runs on a pull request.**

**Secrets**: `RH_REGISTRY_USER`/`RH_REGISTRY_PASSWORD` (bib pull), `RHSM_USERNAME`/`RHSM_PASSWORD`
(every job registers, and unregisters in `if: always()`), `OPENSHIFT_PULL_SECRET` (build-time
image pulls, never in the image), `JETSON_SSH_PUBKEY`, `JETSON_PASSWORD_HASH`
(`openssl passwd -6`), `JETSON_KIOSK_PASSWORD_HASH` (`openssl passwd -6`, the kiosk login; in
the image, passed to every layer build and mounted only by `kiosk/`). Registration replaced an entitlement-cert tarball. Username/password is
maintainer preference; an org ID + activation key is narrower and needed for SSO/2FA accounts.
Credentials go through `env:`. With Simple Content Access off, register needs `--auto-attach`.
The subscription needs OpenShift and ACM entitlements, or `rhocp` and `rhacm` never appear. A self-hosted registered RHEL 9 aarch64 runner would remove registration entirely.

**bib**: `registry.redhat.io/rhel9/bootc-image-builder` is the supported path for RHEL
content; output is `output/bootiso/install.iso`. The installer boots the stock RHEL kernel, and
the eMMC appears only if it has `sdhci-tegra`. If the installer shows no `mmcblk0`, check that
first (`lsblk`, `modprobe sdhci-tegra` on Ctrl-Alt-F2), not the kickstart. Unverified on
hardware.

## Next step: validate on hardware, then the app services

1. Dispatch `ultron.yml`, `dd` the ISO, boot the devkit (QSPI from R36.5.x). Check
   `bootc status` (expect a digest-pinned GHCR origin, which cannot upgrade), `lsmod | grep
   nvgpu`, `nvidia-ctk cdi list` → `nvidia.com/gpu=all`, a GPU container, `systemctl
   is-enabled bootc-fetch-apply-updates.timer`, whether `jtop` works, and that
   `journalctl -b -u greenboot-healthcheck` ends green after a `bootc upgrade` (the
   rollback above). Separately, dispatch twice with no change and compare the `services`
   layer digests (`skopeo inspect`): the rechunk is only worth its runner time if most of
   them match.
2. MicroShift: `systemctl status microshift`, `oc get pods -A` all running with no registry,
   `vgs` shows free extents, a PVC binds on topolvm. `ip addr show lo` has `10.44.0.1/32` and
   `oc get node -o wide` shows it; pull the cable for a minute and `NRestarts` must not move.
   `getent hosts kubernetes.default.svc.cluster.local` → `10.43.0.1`, and a pod still
   resolves a `cloudlet.local` name. Then `oc` from the laptop. Pins: `crictl images -o json |
   jq '.images[] | {repoTags, repoDigests, pinned}'` shows `pinned: true` for every embedded
   image (digest-only names included), `crio config | grep -A12 pinned_images` shows our list
   and nothing from the MicroShift RPM was replaced, and an image a new OS drops is still
   removed by the prune.
3. Device plugin: the DaemonSet runs and allocatable `nvidia.com/gpu` equals the replica
   count. Run that many GPU pods at once and watch for OOM.
4. Services: pods Running in `cert-manager` (3), `external-secrets-operator` (3) and `kserve`
   (1), with no registry. A failing `runAsUser` patch shows in `oc describe rs`. Check resources
   survived (`oc get deploy -A -o jsonpath`). `journalctl -u microshift | grep -i kustomization`
   shows a root still retrying — watch `040`. Every services pod's `openshift.io/scc` annotation
   should be `restricted-v2`.
   Device CA: `oc get certificate,clusterissuer -A` Ready; `oc get secret -n cert-manager
   device-ca-public -o jsonpath='{.data}'` has `ca.crt` only; `oc get cm -A
   --field-selector metadata.name=ca-bundle` lists every namespace, and a new namespace
   gets one within a minute; `oc get clustersecretstore,secretstore -A` Valid (proves
   `system:basic-user` and `kube-root-ca.crt` hold on MicroShift); a leaf from `device-ca`
   verifies with `openssl verify -CAfile` against the ConfigMap. `oc auth can-i get
   secret/device-ca -n cert-manager --as=system:serviceaccount:cert-manager:device-ca-bundle-reader`
   → no.
5. Serve a model: first `pvc://` (model repository `oc cp`'d into a topolvm PVC), proving the
   Triton tag runs on r36.5 and an SCC-assigned UID can open the GPU (`id`, `ls -ln
   /dev/nvhost-ctrl-gpu /dev/nvmap`; if `root:video 0660`, add `supplementalGroups` on the
   InferenceService or CRI-O's `device_ownership_from_security_context`). Then `oci://` with an
   embedded modelcar image, proving the `uidModelcar` change.
6. Kiosk, with a monitor on DP **from power-on** and UEFI's display hand-off at Never:
   `lsmod | grep -E 'nvidia_drm|nvidia_modeset'` and `/dev/dri/card*`; `loginctl
   show-session <id> -p Type` says `wayland` for the login screen and the kiosk session, and
   `/run/gdm/custom.conf` does not exist; `lsof` shows `gnome-shell` (`gdm`) and the kiosk's
   processes holding `/dev/nvmap`; the login screen still appears with GNOME
   Shell's session files deleted, and its gear lists only the kiosk session; it lists only `kiosk`,
   with `avatar.png` as its picture, `login-logo.png` where Red Hat's logo was and
   `login-background.png` filling the screen (not tiled, not grey: St parsed the rule), the image's
   password logs in, `ssh kiosk@` is refused, Ctrl-Alt-F3 and the serial console
   refuse `kiosk` and take `cloudlet`, `nmcli con mod` and `systemctl reboot` as `kiosk` are
   denied, `journalctl -b | grep -i polkit` shows nothing from the kiosk session breaking,
   `/usr/lib/jetson-kiosk/password-hash` is `0600 root`; Firefox opens on the URL; replug
   the cable and the picture returns; the screen does not blank; a USB keyboard, mouse and touch
   screen all drive the page, and whether the login screen offers an on-screen keyboard on touch;
   Shift held while Firefox restarts opens no troubleshoot dialog, Ctrl-P prints nothing;
   `journalctl -b | grep -E 'avc: +denied'` clean (`ausearch` is not installed); `systemctl
   suspend` refused; `tegrastats` and
   Triton's p99 latency with the screen on and off. If the frontend plays H.264, it is a black
   box.
7. Later layers `FROM` the k8s image: a `bootc switch` unit for the air-gapped registry,
   greenboot health checks, a signature policy in `/etc/containers/policy.json`.

**Open decisions** (confirm with the maintainer first): who may get certificates from
`device-ca` (upstream aggregates `Certificate` create into every namespace's admin/edit, so an
`isCA` sub-CA too; approver-policy or `nameConstraints` would bound it), and whether
`ca-bundle` belongs in every namespace or only labelled ones; the Triton `-igpu` tag for
JetPack 6.2.2 and the 8Gi slice size; where InferenceServices live, and whether models get their
own layer above `services/`; what External Secrets reads from; NVMe before real apps land;
registration vs. a self-hosted runner; per-device address and hostname before a second node;
how `/etc/flightctl/config.yaml` reaches a node, and greenboot; `bootc switch` vs. retag for the
node's origin, and whether `stable` should wait for a hardware boot (today it moves on every green build of
`main`);
lowering kubelet's image GC thresholds below the eviction line (only matters once images are
pulled); whether the `services/` resource sizes survive hardware (the ratios are enforced, the
sizes are guesses); the kiosk's `KIOSK_URL`, what the screen costs Triton once measured, and
the frontend's video codec, preview size and on-screen keyboard.

## How to work in this repo

**Style — this matters as much as correctness.**

- Lean and minimal. No features nobody asked for: no EPEL, no extra entitlement plumbing, no
  SHA256 verification (tried, removed), no rootfs download. Mention omissions in the reply.
- One script, one job. Flashing, mirroring, offline install and image building stay separate.
- No stray side effects: no empty directories, nothing installed on the build host, nothing
  outside the declared output dir.
- Validate inputs before expensive work. `set -euo pipefail` everywhere.
- Keep `gpgcheck=1` offline. Use `reposync --download-metadata`, not `createrepo_c`, so signed
  modular metadata survives.
- Bash: `getopts` with short flags and a `usage()` showing defaults. `bash -n` + a real run over
  test frameworks.
- Explanations in replies should be deep and line-by-line, not headline summaries.

**Things that bit us — do not repeat.**

- Greenboot runs every required check on every new deployment, and an RPM can bring one
  (`flightctl-agent` did). A check that cannot pass on an unenrolled or disconnected node rolls
  each upgrade back after the boot counter runs out. List `rpm -ql | grep greenboot/check`
  for every package a layer adds.

- bib's `[customizations.installer.bootloader.grub2] menu-timeout` parses but does nothing for
  `anaconda-iso`: osbuild/images honours it for bootc ISOs only from v80, and bib vendors
  v0.251. The GRUB menu sat at 60 s on hardware. A bib key is proven only by the built ISO.
- RHEL ships the C preprocessor as `cpp`; `flash.sh` dies with `FileNotFoundError: cpp`
  without it.
- `apt-get --download-only install` skips installed packages; a Debian bundle needs a clean
  container with separate download and index stages (legacy, from the Ubuntu evaluation).
- `rockylinux:9`, not UBI, for any RPM-bundling builder; UBI lacks packages.
- A monitor plugged in after boot hides the display hand-off failure: test with DP connected
  from power-on. `libEGL warning: DRI3 error` in the journal means Mesa's EGL answered, not
  NVIDIA's. Restarting GDM is not a test of the display; a reboot is.
- Every base-image bump can break the GPU (the kmod is tied to one kernel). A container smoke
  test proves nothing about the GPU; boot hardware before promoting a tag.
- `nvidia-ctk runtime configure --config=…/99-nvidia.conf` writes `99-nvidia.toml` and exits 0.
  CRI-O reads either; only a check spelling the name notices. Ask for `.toml`.
- A kickstart option anaconda does not know (`--domain` was one) stops the installer at the
  systemd log with no visible error, and bib builds the ISO anyway. `build-iso.yml` runs
  `ksvalidator -v RHEL9` on the rendered `contents`; locally, pip `pykickstart` does the same.
- A bare `test` exits 1 silently. Every check names what it looked for and lists the directory.
- podman in a `container:` job silently loses the native overlay diff (overlayfs storage, or
  `metacopy=on`). Keep the `/scratch` bind, the `metacopy` strip and the check.
- A Deployment patch matching nothing fails kustomize — the safety net under `services/`. An
  `images:` entry matching nothing does not, nor does a field a patch no longer needs to
  delete; those need a check on the render.
- An apostrophe inside an `awk` program ends the shell quoting and surfaces as a syntax error
  at `$0`. No contractions in awk comments.
- Smoke tests parse renders with `oc patch --local -f - --type=merge -p '{}' -o json` and query
  them with `jq`, not awk over YAML (which broke on list shapes). They do not re-check what
  already fails the build or a lower layer's test — except `systemctl enable`, which only warns
  on a bad `[Install]`, and agreement between separately copied files (keyfile address vs.
  `nodeIP`).
- `imagePullPolicy: Always` pulls even with the image in containers-storage, so on a node with
  no registry an embedded image still ends in ImagePullBackOff. Unset, it defaults to `Always`
  for `:latest` or no tag. Upstream KServe's manager ships with it; check each new upstream.
- `podman untag IMAGE` with no name removes **every** name from the image. Retagging and then
  `untag`ging the temporary name alone stripped the real tags too (run 33); name both.
- jq's `a // b` treats `false` as missing. Where an explicit `false` must win over a fallback,
  test for `null`.
- ESO's `target.manifest` (ConfigMap output) exists from v1.0 only, needs
  `--unsafe-allow-generic-targets` and a ConfigMap-writing role; an older CRD does not know the
  field, so depending on the client's field validation it is refused or dropped, and a Secret
  written instead. v1.3.0 has no `external-secrets.yaml` release asset;
  `releases/latest` is a Helm chart tag.
- A render-time check cannot see what a webhook injects. For KServe's `uidModelcar` the only
  handle is the ConfigMap key.

**Git / delivery.** Develop on the session's branch, commit with a message that says *why*,
push, and open a PR only when asked. Always state which files changed. Nothing runs CI on a PR,
so a branch is validated by dispatching `ultron.yml` against it; a claim that
something is tested should say whether that means locally or dispatched.

## Quick reference

```bash
# Online RHEL host — build the repo bundle (incremental)
./mirror.sh -o /run/media/$USER/USBKEY/dist

# Air-gapped station — provision (as root, from the bundle dir)
sudo ./install-offline.sh

# Air-gapped station — flash QSPI (devkit in recovery: hold Force Recovery, tap Reset, release)
lsusb | grep 0955
cd /opt/nvidia/Linux_for_Tegra && sudo ./flash.sh p3737-0000-p3701-0000-qspi external

# Local image build on a subscribed RHEL 9 aarch64 box, from the repo root. Each layer FROM the
# one before it; the workflow passes BASE_IMAGE as a digest.
sudo podman build -f base/Containerfile.base     -t localhost/ultron-bootc-base:dev .
sudo podman build -f base/Containerfile.podman   -t localhost/ultron-bootc-bound-images:dev \
    --build-arg BASE_IMAGE=localhost/ultron-bootc-base:dev .
openssl passwd -6 > /tmp/kiosk-hash   # the kiosk login's password
sudo podman build -f kiosk/Containerfile         -t localhost/ultron-bootc-kiosk:dev \
    --secret id=kiosk_password_hash,src=/tmp/kiosk-hash \
    --build-arg BASE_IMAGE=localhost/ultron-bootc-bound-images:dev .
sudo podman build -f microshift/Containerfile    -t localhost/ultron-bootc-microshift:dev \
    --secret id=pullsecret,src=$HOME/pull-secret.json \
    --build-arg BASE_IMAGE=localhost/ultron-bootc-kiosk:dev .
sudo podman build -f services/Containerfile      -t localhost/ultron-bootc-services:dev \
    --secret id=pullsecret,src=$HOME/pull-secret.json \
    --build-arg BASE_IMAGE=localhost/ultron-bootc-microshift:dev .
# Smoke tests are fed on stdin, the same way the workflow runs them
podman run --rm -i localhost/ultron-bootc-services:dev bash -s < services/smoke-test.sh

# ISO from the top of the chain
sed -e "s|@JETSON_SSH_PUBKEY@|$(cat ~/.ssh/id_ed25519.pub)|" \
    -e "s|@JETSON_PASSWORD_HASH@|$(openssl passwd -6)|" \
    config.toml > /tmp/config.toml
sudo podman run --rm --privileged --pull=newer --security-opt label=type:unconfined_t \
  -v /tmp/config.toml:/config.toml:ro -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  registry.redhat.io/rhel9/bootc-image-builder:latest \
  --type anaconda-iso --config /config.toml localhost/ultron-bootc-services:dev
# -> output/bootiso/install.iso

# On the device
cat /etc/nv_tegra_release      # R36 REVISION 5.0
lsmod | grep nvgpu
systemctl status nvidia-ctk && nvidia-ctk cdi list   # expect nvidia.com/gpu=all
bootc status
```
