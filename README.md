# rustdesk-unattended-wayland-bin

Arch Linux package for the **RustDesk "unattended Wayland" build**, which captures the screen straight from the kernel's DRM/KMS scanout instead of going through `xdg-desktop-portal`. No consent dialog on every connection, and it works at the login screen.

This is **not a fork** and contains no code of its own. It repackages the official `rustdesk-unattended-wayland-<version>-x86_64.deb` that the RustDesk project publishes on its GitHub Releases, so that Arch users can install it with `pacman`. The upstream CI only ships this variant as a `.deb`.

> Not affiliated with or endorsed by the RustDesk project. For anything about RustDesk itself, please use [rustdesk/rustdesk](https://github.com/rustdesk/rustdesk).

## Why this exists

The DRM capture backend ([rustdesk/rustdesk#15420](https://github.com/rustdesk/rustdesk/pull/15420)) is an opt-in `drm` Cargo feature. It is not part of the default RustDesk build, and `build.py --drm` refuses to run on the pacman packaging path, so the stock `rustdesk` and `rustdesk-bin` AUR packages do not contain it. Nothing in the binary is Debian specific, so the official `.deb` works on Arch once its files are installed in the right places.

## What the package does

Repackages the official deb with a pinned sha256. See [PKGBUILD](PKGBUILD) and [rustdesk.install](rustdesk.install) for exactly what it installs and what happens on install and upgrade.

## The display wake is off by default

The upstream `drm-wake` feature is compiled into this build and is **on** unless a runtime option turns it off ([rustdesk/rustdesk#15420](https://github.com/rustdesk/rustdesk/pull/15420): the key `enable-drm-display-wake` is read as true when absent). When a connected display has no CRTC, the root service wakes it by injecting synthetic input through a `RustDesk DRM display wake` uinput device, once per `--server` handshake. The root service also restarts the unprivileged `--server` every hour ([rustdesk/rustdesk#14935](https://github.com/rustdesk/rustdesk/pull/14935) proposed removing that and was closed unmerged), so on a machine where the compositor switches outputs off on idle, the screens are woken once an hour with nobody present.

On one NVIDIA + KWin (Wayland) machine with a DisplayPort monitor that drops its link in standby, that hourly wake made the monitor disconnect and reconnect, KWin failed to apply its output configuration and the outputs froze (`Applying output configuration failed!`, NVIDIA Xid 16). With `enable-drm-display-wake = 'N'`, three consecutive `--server` restarts (two forced, one at the natural hour, screens off each time) created no wake device, started no KSplash and left the outputs untouched. That is a small sample from one machine, not a guarantee.

So the package sets `enable-drm-display-wake = 'N'` in the root service's config, `/root/.config/rustdesk/RustDesk2.toml` under `[options]`, on install and upgrade, **only when the key is absent**. Capture of an output that is switched off then falls back to PipeWire, as upstream documents. To turn the wake back on:

```bash
sudo rustdesk --option enable-drm-display-wake Y
```

To go back to the package default (`N`) after changing it:

```bash
sudo rustdesk --option enable-drm-display-wake N
```

An explicit `Y` or `N` is never overwritten by later upgrades. To read the current value: `sudo rustdesk --option enable-drm-display-wake` (no value prints it), or `sudo grep -n enable-drm-display-wake /root/.config/rustdesk/RustDesk2.toml`.

Do not just delete the line to "reset" it: with the key absent RustDesk treats the wake as **on** (upstream's default) until the package sets it again. If you did delete it, either run the command above or reinstall (`sudo pacman -S rustdesk-unattended-wayland-bin`), which runs the install script again and restores `N` because the key is absent.

## Install from the pacman repository (updates with `pacman -Syu`)

The package is published in a signed pacman repository, `[rustdesk-drm]`, kept in the [`repo` release](https://github.com/snooptheone/rustdesk-unattended-wayland-bin/releases/tag/repo) of this repository. Packages and database are signed with a dedicated key:

```
B433 5AFC 8B78 A3DD 3A17  52F5 1055 D807 33B8 C800
```

1. Download the key and **check that the fingerprint printed matches the one above** before trusting it:

```bash
curl -fsSLO https://github.com/snooptheone/rustdesk-unattended-wayland-bin/releases/download/repo/rustdesk-drm.gpg
```
```bash
gpg --show-keys --fingerprint rustdesk-drm.gpg
```

2. Trust it in pacman's keyring:

```bash
sudo pacman-key --add rustdesk-drm.gpg
```
```bash
sudo pacman-key --lsign-key B4335AFC8B78A3DD3A1752F51055D80733B8C800
```

3. Add the repository at the end of `/etc/pacman.conf`:

```ini
[rustdesk-drm]
SigLevel = Required DatabaseRequired
Server = https://github.com/snooptheone/rustdesk-unattended-wayland-bin/releases/download/repo
```

4. Install:

```bash
sudo pacman -Syu rustdesk-unattended-wayland-bin
```

pacman will offer to remove `rustdesk` / `rustdesk-bin` if you have them. Installing enables and restarts the `rustdesk` service, so an open remote session drops for a few seconds. Your RustDesk ID, password and settings live in `~/.config/rustdesk` and `/root/.config/rustdesk` and are not touched.

The key expires on 2028-10-05; a new one will be announced here before that. This README is the only place the fingerprint is published, so there is no second channel to cross-check it against yet.

## Install by building it yourself

```bash
git clone https://github.com/snooptheone/rustdesk-unattended-wayland-bin.git
cd rustdesk-unattended-wayland-bin
makepkg -si
```

Or download a `.pkg.tar.zst` from the [Releases](https://github.com/snooptheone/rustdesk-unattended-wayland-bin/releases) page and run `sudo pacman -U` on it (those single-version packages are not signed).

## If pacman says `rustdesk-link.desktop exists in filesystem`

```text
error: failed to commit transaction (conflicting files)
rustdesk-unattended-wayland-bin: /usr/share/applications/rustdesk-link.desktop exists in filesystem
```

pacman refuses to overwrite a file that no package owns. The official RustDesk package copies that file in by hand from its install script, so anyone who ever installed it keeps a stray copy, even after switching packages. It only registers the `rustdesk://` link handler, and this package ships its own copy. Let pacman replace just that one path:

```bash
sudo pacman -Syu --overwrite /usr/share/applications/rustdesk-link.desktop rustdesk-unattended-wayland-bin
```

With `pacman -U`, add the same `--overwrite` option. Nothing is changed when pacman reports this error, so it is safe to run again.

## Check that DRM capture is really used

There is no menu option for it: the backend is picked automatically (DRM, then PipeWire, then X11) and only on Wayland. After a remote connection, the root service log shows the capture path:

```bash
sudo grep -i -E "drm: (first frame|capture)" /root/.local/share/logs/RustDesk/service/rustdesk_rCURRENT.log | tail
```

You want something like `drm: first frame for crtc N in ... (dma-buf path)`. The unprivileged `--server` log is in `~/.local/share/logs/RustDesk/server/`. If DRM is unavailable the log says why and RustDesk falls back to PipeWire.

## Things you should know

- The service runs **as root**. That is how the DRM backend gets the privilege it needs to read another client's scanout. Upstream documents the threat model in `docs/DRM_CAPTURE_SECURITY.md` in the RustDesk repository; read it before deciding whether this fits your machine.
- It needs an active CRTC. If the compositor has switched the output off, there is nothing to capture and RustDesk falls back to PipeWire.
- Because the display wake is off by default (see above), an output the compositor has switched off is not woken for a remote connection; the connection falls back to PipeWire instead.
- X11 sessions are unaffected: the DRM path is skipped.
- Pinned to the official `1.5.0` release. To follow a new release, bump `pkgver` and the sha256 in the `PKGBUILD`, and make sure the matching `rustdesk-unattended-wayland-*.deb` exists on that release first.

## Tested

CachyOS, Wayland, RustDesk 1.5.0. The service log reports `drm: first frame ... (dma-buf path)` on a real remote connection, with no portal prompt and no PipeWire fallback. Other GPUs and compositors were not tested here; see the upstream pull request for the hardware its author covered.

## License

The packaging files in this repository (`PKGBUILD`, `rustdesk.install`, `.SRCINFO`, this README) are released under the [BSD Zero Clause License](LICENSE). RustDesk itself, and the `.deb` this package installs, remain under their own license (AGPL-3.0); this repository does not relicense them.

## Credits

This repository is only packaging glue. All the real work belongs to others:

- **[RustDesk](https://github.com/rustdesk/rustdesk)** and its contributors, for RustDesk itself (AGPL-3.0) and for the official `.deb` this package repackages. The layout of the systemd unit handling follows their own `res/pacman_install` and `res/PKGBUILD`.
- **[@fxd0h](https://github.com/fxd0h)**, author of the DRM/KMS capture backend ([#15420](https://github.com/rustdesk/rustdesk/pull/15420)), and the maintainers who reviewed and merged it.
- **[libdrmtap](https://github.com/rustdesk-org/libdrmtap)** (`rustdesk-org` fork), the library the backend loads at runtime, which ships inside the `.deb`.
- **The AUR `rustdesk-bin` maintainers** (KUHTOXO, Zoddo, and its contributors), whose `PKGBUILD` and `.install` were the starting point for the Arch packaging, and the **AUR `rustdesk` maintainers** (severach and contributors), whose dependency list I compared against.
- **QiE2035's AUR [`rustdesk-unattended-wayland`](https://aur.archlinux.org/packages/rustdesk-unattended-wayland)**, which got to repackaging this same `.deb` first. This repository differs mainly by pinning the stable release and its checksum instead of the moving `nightly` tag.

## A thank you to the RustDesk team

Thank you to everyone behind RustDesk. Building and maintaining a free, open source remote desktop tool, and then taking on something as demanding as unattended Wayland capture with careful review and a real security model, is a lot of work that many of us rely on every day. If RustDesk is useful to you too, please consider supporting the project: star the repository, report issues, contribute code or translations, or sponsor it through the links on [rustdesk.com](https://rustdesk.com) and the [RustDesk GitHub page](https://github.com/rustdesk).
