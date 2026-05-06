#!/usr/bin/env bash
# ============================================================
# arch-blackarch-img-wrapper.sh — Build Arch/BlackArch .img
# Usage:
#   sudo ./arch-blackarch-img-wrapper.sh
#
# Optional env:
#   SIZE_GB=25 IMG=./arch.img CHROOT=/arch MIRROR=https://geo.mirror.pkgbuild.com
# ============================================================

set -euo pipefail

# ─── Config ─────────────────────────────────────────────────
IMG="${IMG:-./arch.img}"
CHROOT="${CHROOT:-/arch}"
SIZE_GB="${SIZE_GB:-20}"
MIRROR="${MIRROR:-https://geo.mirror.pkgbuild.com}"
LOOPDEV=""

TMP_DIR="/tmp/arch-build-$$"

# ─── Colors ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

info(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }
section(){ echo -e "\n${BOLD}${BLUE}══ $* ══${NC}"; }

# ─── Check deps ─────────────────────────────────────────────
need() {
  command -v "$1" >/dev/null 2>&1 || {
    error "Missing dependency: $1"
    exit 1
  }
}

need losetup
need mkfs.ext4
need mount
need umount
need pacstrap
need fallocate
need df

# ─── Cleanup trap ───────────────────────────────────────────
cleanup() {
  local code=$?

  if mountpoint -q "$CHROOT" 2>/dev/null; then
    sudo umount -l "$CHROOT" >/dev/null 2>&1 || true
  fi

  if [ -n "${LOOPDEV:-}" ] && losetup "$LOOPDEV" &>/dev/null; then
    sudo losetup -d "$LOOPDEV" >/dev/null 2>&1 || true
  fi

  rm -rf "$TMP_DIR" 2>/dev/null || true

  if [ $code -ne 0 ]; then
    warn "Failure detected, removing image..."
    rm -f "$IMG" 2>/dev/null || true
  fi
}

trap cleanup EXIT
mkdir -p "$TMP_DIR"

# ─── Step 1: Create image ───────────────────────────────────
section "Step 1: Create ${SIZE_GB}GB image"

if [ -f "$IMG" ]; then
  warn "Image exists: $IMG"
  read -r -p "Overwrite? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 0
  rm -f "$IMG"
fi

fallocate -l "${SIZE_GB}G" "$IMG" || {
  warn "fallocate failed, fallback dd"
  dd if=/dev/zero of="$IMG" bs=1G count="$SIZE_GB" status=progress
}

mkfs.ext4 -F -L arch-root "$IMG" >/dev/null
info "Filesystem created"

# ─── Step 2: loop mount ────────────────────────────────────
section "Step 2: loop attach"

LOOPDEV=$(sudo losetup --find --show "$IMG")
info "Loop: $LOOPDEV"

sudo mkdir -p "$CHROOT"
sudo mount "$LOOPDEV" "$CHROOT"

# ─── Step 3: pacstrap base system ──────────────────────────
section "Step 3: Install Arch base system"

info "Installing base system..."

sudo pacstrap -K "$CHROOT" \
  base base-devel linux linux-firmware \
  vim sudo networkmanager

# ─── Step 4: fstab ──────────────────────────────────────────
section "Step 4: Generate fstab"

genfstab -U "$CHROOT" | sudo tee "$CHROOT/etc/fstab" >/dev/null

# ─── Step 5: basic config ───────────────────────────────────
section "Step 5: Basic configuration"

sudo arch-chroot "$CHROOT" /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/Asia/Singapore /etc/localtime
hwclock --systohc

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen

echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "archbox" > /etc/hostname

systemctl enable NetworkManager
EOF

# ─── Step 6: BlackArch bootstrap (optional but recommended) ─
section "Step 6: BlackArch setup"

sudo arch-chroot "$CHROOT" /bin/bash <<'EOF'
set -e

echo "[*] Installing BlackArch keyring + repo bootstrap..."

curl -O https://blackarch.org/strap.sh
chmod +x strap.sh
./strap.sh

rm -f strap.sh

pacman -Syu --noconfirm
pacman -S --noconfirm blackarch-keyring
EOF

# ─── Step 7: report ─────────────────────────────────────────
section "Step 7: Done"

df -h "$CHROOT" | sed -n '1,2p'

echo
echo -e "${BOLD}${GREEN}═══════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}   ✅ Arch image ready         ${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════${NC}"
echo
echo "Image   : $IMG"
echo "Mount   : $CHROOT"
echo "Loop    : $LOOPDEV"
echo
echo "Run:"
echo "  sudo mount -o loop $IMG $CHROOT"
echo "  sudo arch-chroot $CHROOT"
echo

# ─── Step 8: cleanup mount (optional auto exit style) ───────
section "Step 8: cleanup"

sudo umount -l "$CHROOT" || true
sudo losetup -d "$LOOPDEV" || true
LOOPDEV=""
info "Done"
