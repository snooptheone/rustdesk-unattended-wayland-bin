# rustdesk-unattended-wayland-bin

Arch Linux package for the **RustDesk "unattended Wayland" build**, which captures the screen straight from the kernel's DRM/KMS scanout instead of going through `xdg-desktop-portal`. No consent dialog on every connection, and it works at the login screen.

This is **not a fork** and contains no code of its own. It repackages the official `rustdesk-unattended-wayland-<version>-x86_64.deb` that the RustDesk project publishes on its GitHub Releases, so that Arch users can install it with `pacman`. The upstream CI only ships this variant as a `.deb`.

> Not affiliated with or endorsed by the RustDesk project. For anything about RustDesk itself, please use [rustdesk/rustdesk](https://github.com/rustdesk/rustdesk).

## Why this exists

The DRM capture backend ([rustdesk/rustdesk#15420](https://github.com/rustdesk/rustdesk/pull/15420)) is an opt-in `drm` Cargo feature. It is not part of the default RustDesk build, and `build.py --drm` refuses to run on the pacman packaging path, so the stock `rustdesk` and `rustdesk-bin` AUR packages do not contain it. Nothing in the binary is Debian specific, so the official `.deb` works on Arch once its files are installed in the right places.

## What the package does

- Downloads the official release `.deb` and checks its **pinned sha256** (it matches the digest GitHub shows for the release asset).
- Installs the app in `/usr/share/rustdesk` and `libdrmtap.so.0.x.y` in `/usr/lib/rustdesk`, exactly as upstream lays them out.
- Installs the systemd unit in `/usr/lib/systemd/system` (with `pkill` as an absolute path, as the upstream `postinst` does) and symlinks `/usr/bin/rustdesk`.
- `provides=rustdesk`, `conflicts=rustdesk rustdesk-bin`.
- On install and upgrade it enables and restarts the `rustdesk` service, so a stale daemon never keeps running the previous binary.

## Install

```bash
git clone https://github.com/snooptheone/rustdesk-unattended-wayland-bin.git
cd rustdesk-unattended-wayland-bin
makepkg -si
```

pacman will offer to remove `rustdesk` / `rustdesk-bin` if you have them. Your RustDesk ID, password and settings live in `~/.config/rustdesk` and `/root/.config/rustdesk` and are not touched.

A prebuilt `.pkg.tar.zst` may also be attached to the Releases page of this repository.

## Check that DRM capture is really used

There is no menu option for it: the backend is picked automatically (DRM, then PipeWire, then X11) and only on Wayland. After a remote connection, the root service log shows the capture path:

```bash
sudo grep -i -E "drm: (first frame|capture)" /root/.local/share/logs/RustDesk/service/rustdesk_rCURRENT.log | tail
```

You want something like `drm: first frame for crtc N in ... (dma-buf path)`. The unprivileged `--server` log is in `~/.local/share/logs/RustDesk/server/`. If DRM is unavailable the log says why and RustDesk falls back to PipeWire.

## Things you should know

- The service runs **as root**. That is how the DRM backend gets the privilege it needs to read another client's scanout. Upstream documents the threat model in `docs/DRM_CAPTURE_SECURITY.md` in the RustDesk repository; read it before deciding whether this fits your machine.
- It needs an active CRTC. If the compositor has switched the output off, there is nothing to capture and RustDesk falls back to PipeWire.
- X11 sessions are unaffected: the DRM path is skipped.
- Pinned to the official `1.5.0` release. To follow a new release, bump `pkgver` and the sha256 in the `PKGBUILD`, and make sure the matching `rustdesk-unattended-wayland-*.deb` exists on that release first.

## Tested

CachyOS, Wayland, RustDesk 1.5.0. The service log reports `drm: first frame ... (dma-buf path)` on a real remote connection, with no portal prompt and no PipeWire fallback. Other GPUs and compositors were not tested here; see the upstream pull request for the hardware its author covered.

## Credits

This repository is only packaging glue. All the real work belongs to others:

- **[RustDesk](https://github.com/rustdesk/rustdesk)** and its contributors, for RustDesk itself (AGPL-3.0) and for the official `.deb` this package repackages. The layout of the systemd unit handling follows their own `res/pacman_install` and `res/PKGBUILD`.
- **[@fxd0h](https://github.com/fxd0h)**, author of the DRM/KMS capture backend ([#15420](https://github.com/rustdesk/rustdesk/pull/15420)), and the maintainers who reviewed and merged it.
- **[libdrmtap](https://github.com/rustdesk-org/libdrmtap)** (`rustdesk-org` fork), the library the backend loads at runtime, which ships inside the `.deb`.
- **The AUR `rustdesk-bin` maintainers** (KUHTOXO, Zoddo, and its contributors), whose `PKGBUILD` and `.install` were the starting point for the Arch packaging, and the **AUR `rustdesk` maintainers** (severach and contributors), whose dependency list I compared against.
- **QiE2035's AUR [`rustdesk-unattended-wayland`](https://aur.archlinux.org/packages/rustdesk-unattended-wayland)**, which got to repackaging this same `.deb` first. This repository differs mainly by pinning the stable release and its checksum instead of the moving `nightly` tag.

## A thank you to the RustDesk team

Thank you to everyone behind RustDesk. Building and maintaining a free, open source remote desktop tool, and then taking on something as demanding as unattended Wayland capture with careful review and a real security model, is a lot of work that many of us rely on every day. If RustDesk is useful to you too, please consider supporting the project: star the repository, report issues, contribute code or translations, or sponsor it through the links on [rustdesk.com](https://rustdesk.com) and the [RustDesk GitHub page](https://github.com/rustdesk).
