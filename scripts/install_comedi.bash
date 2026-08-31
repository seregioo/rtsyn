#!/usr/bin/env bash
set -euo pipefail

echo "Comedi installation helper"
echo
echo "Select your OS:"
echo "1) Arch"
echo "2) Debian/Ubuntu"
echo "3) Fedora"
echo "4) Quit"
read -r -p "Choice [1-4]: " choice

case "$choice" in
1)
    sudo pacman -S --needed base-devel git linux-headers kmod libusb
    mkdir -p "$HOME/pkg/comedi"
    cd "$HOME/pkg/comedi"
    cat <<'EOF' >PKGBUILD
pkgname=comedi
pkgver=0.8.0_git
pkgrel=1
pkgdesc="Control and Measurement Device Interface (COMEDI)"
arch=('x86_64')
license=('GPL')
depends=('glibc' 'libusb')
makedepends=('git' 'linux-headers' 'autoconf' 'automake' 'libtool')
options=('!lto')
provides=('comedi' 'comedilib')
conflicts=('comedi' 'comedilib')

source=(
  'comedi::git+https://github.com/Linux-Comedi/comedi.git'
  'comedilib::git+https://github.com/Linux-Comedi/comedilib.git'
)
sha256sums=('SKIP' 'SKIP')

build() {
  # Kernel + drivers
  cd "$srcdir/comedi"
  ./autogen.sh
  ./configure --prefix=/usr --sbindir=/usr/bin
  make

  # Userspace library
  cd "$srcdir/comedilib"
  ./autogen.sh
  ./configure --prefix=/usr --sbindir=/usr/bin
  make
}

package() {
  cd "$srcdir/comedi"
  make DESTDIR="$pkgdir" install
  # Move kernel modules to /usr/lib/modules to avoid /lib symlink conflicts on Arch
  if [ -d "$pkgdir/lib/modules" ]; then
    mkdir -p "$pkgdir/usr/lib"
    if [ -d "$pkgdir/usr/lib/modules" ]; then
      cp -a "$pkgdir/lib/modules/." "$pkgdir/usr/lib/modules/"
      rm -rf "$pkgdir/lib/modules"
    else
      mv "$pkgdir/lib/modules" "$pkgdir/usr/lib/modules"
    fi
  fi
  # Avoid packaging host-owned paths/symlinks and kernel metadata files
  rm -rf "$pkgdir/lib"
  if [ -d "$pkgdir/usr/sbin" ]; then
    mkdir -p "$pkgdir/usr/bin"
    cp -a "$pkgdir/usr/sbin/." "$pkgdir/usr/bin/" || true
    rm -rf "$pkgdir/usr/sbin"
  fi
  find "$pkgdir/usr/lib/modules" -maxdepth 2 -type f -name 'modules.*' -delete 2>/dev/null || true

  cd "$srcdir/comedilib"
  # comedilib git tree can miss prebuilt HTML docs; ignore doc install errors
  make -i DESTDIR="$pkgdir" install
}
EOF

    rm -f comedi-*.pkg.tar.* comedi-debug-*.pkg.tar.*
    makepkg -si --noconfirm --cleanbuild
    sudo depmod -a
    sudo modprobe comedi
    cd ..
    rm -rf "$HOME/pkg"
    ;;
2)
    echo "Debian/Ubuntu install method:"
    echo "Installing DKMS from source (kernel driver)"
    sudo apt update
    sudo apt install -y \
        autoconf automake build-essential dkms git libtool \
        "linux-headers-$(uname -r)"
    if [ ! -d "$HOME/pkg/comedi" ]; then
        mkdir -p "$HOME/pkg"
        git clone https://github.com/Linux-Comedi/comedi.git "$HOME/pkg/comedi"
    fi
    cd "$HOME/pkg/comedi"
    ./autogen.sh
    ./configure

    # Generate the release archive expected by DKMS.  Adding the source
    # directory directly is unreliable with some DKMS versions and does not
    # build/install the modules by itself.
    make dist
    comedi_version=$(sed -n 's/^PACKAGE_VERSION=//p' dkms.conf)
    if [ -z "$comedi_version" ]; then
        echo "Could not determine the Comedi version from dkms.conf." >&2
        exit 1
    fi
    sudo tar -C /usr/src -xaf "comedi-${comedi_version}.tar.gz"
    if [ ! -d "/var/lib/dkms/comedi/${comedi_version}" ]; then
        sudo dkms add "comedi/${comedi_version}"
    else
        echo "Comedi ${comedi_version} is already registered with DKMS."
    fi
    sudo dkms autoinstall
    sudo depmod -a
    sudo apt install -y libcomedi-dev
    sudo modprobe comedi
    ;;
3)
    sudo dnf install -y comedilib comedi
    sudo modprobe comedi
    ;;
4)
    echo "Aborted."
    exit 0
    ;;
*)
    echo "Invalid choice."
    exit 1
    ;;
esac

echo
echo "COMEDI core loaded. You may need to load your board driver, for example:"
echo "  sudo modprobe ni_usb6501"
echo "  sudo modprobe ni_pcimio"

rtsyn_access_user=$(id -un)
if [ "$rtsyn_access_user" = "root" ] && [ -n "${SUDO_USER:-}" ]; then
    rtsyn_access_user=$SUDO_USER
fi

echo
echo "Configuring unprivileged COMEDI access for user: $rtsyn_access_user"
sudo groupadd --force comedi
sudo usermod --append --groups comedi "$rtsyn_access_user"
printf '%s\n' 'SUBSYSTEM=="comedi", KERNEL=="comedi[0-9]*", GROUP="comedi", MODE="0660"' \
    | sudo tee /etc/udev/rules.d/99-rtsyn-comedi.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=comedi --action=add

echo
echo "COMEDI permissions configured."
echo "You will need to log out and log back in before the new 'comedi' group membership takes effect."
echo "After logging back in, verify access with:"
echo "  id"
echo "  ls -l /dev/comedi*"
