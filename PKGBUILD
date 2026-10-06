# Maintainer: Anderson S. <4625164+snooptheone@users.noreply.github.com>
# Repackages the official rustdesk-unattended-wayland .deb (DRM/KMS capture, rustdesk/rustdesk#15420)
# for Arch. The upstream CI only ships this build as a .deb; nothing here is Debian specific.
pkgname=rustdesk-unattended-wayland-bin
pkgver=1.5.0
pkgrel=1
pkgdesc='RustDesk with DRM/KMS direct capture on Wayland (no portal consent prompt), repackaged from the official deb'
arch=('x86_64')
url='https://github.com/rustdesk/rustdesk'
license=('AGPL-3.0-only')
depends=('gtk3' 'xdotool' 'libxcb' 'libxfixes' 'alsa-lib' 'libva' 'libdrm' 'libglvnd'
         'gst-plugins-base' 'gst-plugin-pipewire' 'curl' 'systemd-libs')
optdepends=('libayatana-appindicator: tray icon')
provides=('rustdesk')
conflicts=('rustdesk' 'rustdesk-bin')
options=('!strip' '!debug')
install=rustdesk.install
_deb="rustdesk-unattended-wayland-${pkgver}-${CARCH}.deb"
source_x86_64=("${_deb}::${url}/releases/download/${pkgver}/${_deb}")
noextract=("${_deb}")
sha256sums_x86_64=('9eed5e9f4b47af8ed41585c399cb2c0d2870e801c99645330dea1063ad844e09')

package() {
  bsdtar -xOf "${srcdir}/${_deb}" data.tar.xz | bsdtar -xf - -C "${pkgdir}"

  install -d "${pkgdir}/usr/bin"
  ln -s /usr/share/rustdesk/rustdesk "${pkgdir}/usr/bin/rustdesk"

  # what the deb postinst does: service goes to /usr/lib/systemd/system, pkill needs an absolute path
  install -Dm644 "${pkgdir}/usr/share/rustdesk/files/systemd/rustdesk.service" \
    "${pkgdir}/usr/lib/systemd/system/rustdesk.service"
  sed -i 's|pkill|/usr/bin/pkill|g' "${pkgdir}/usr/lib/systemd/system/rustdesk.service"
}
