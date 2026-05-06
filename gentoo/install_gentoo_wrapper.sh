#!/usr/bin/env bash
# ============================================================
# gentoo-img-wrapper.sh — Build Gentoo stage3 into .img (loop)
# Usage:
#   sudo ./gentoo-img-wrapper.sh
#
# Optional env:
#   SIZE_GB=30 PROFILE=systemd IMG=./gentoo.img CHROOT=/gentoo MIRROR=https://distfiles.gentoo.org
# ============================================================

set -euo pipefail

# ─── Config (override via env) ───────────────────────────────
IMG="${IMG:-./gentoo.img}"
CHROOT="${CHROOT:-/gentoo}"
SIZE_GB="${SIZE_GB:-20}"
ARCH="${ARCH:-amd64}"
PROFILE="${PROFILE:-openrc}"      # openrc / systemd
MIRROR="${MIRROR:-https://distfiles.gentoo.org}"

AUTOBUILDS_BASE="$MIRROR/releases/$ARCH/autobuilds"
MANIFEST_FILE="latest-stage3-${ARCH}-${PROFILE}.txt"
TMP_DIR="/tmp/gentoo-build-$$"

# ─── Colors ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${BLUE}══ $* ══${NC}"; }

# ─── Check dependencies ─────────────────────────────────────
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    error "Command not found: $1"
    exit 1
  }
}

need_cmd curl
need_cmd awk
need_cmd grep
need_cmd tar
need_cmd mkfs.ext4
need_cmd losetup
need_cmd sha256sum
need_cmd mount
need_cmd umount
need_cmd fallocate
need_cmd df

# ─── Cleanup trap ───────────────────────────────────────────
LOOPDEV=""

cleanup() {
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    error "Script gagal (exit code: $exit_code). Cleanup..."
  fi

  if mountpoint -q "$CHROOT" 2>/dev/null; then
    sudo umount -l "$CHROOT" >/dev/null 2>&1 || true
  fi

  if [ -n "${LOOPDEV:-}" ] && losetup "$LOOPDEV" &>/dev/null; then
    sudo losetup -d "$LOOPDEV" >/dev/null 2>&1 || true
  fi

  rm -rf "$TMP_DIR" 2>/dev/null || true

  if [ $exit_code -ne 0 ]; then
    warn "Menghapus image yang gagal: $IMG"
    rm -f "$IMG" 2>/dev/null || true
  fi
}

trap cleanup EXIT

mkdir -p "$TMP_DIR"

# ─── Step 1: Create image ───────────────────────────────────
section "Step 1: Membuat raw image ${SIZE_GB}GB"

if [ -f "$IMG" ]; then
  warn "Image sudah ada: $IMG"
  read -r -p "Timpa image ini? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { info "Dibatalkan."; exit 0; }
  rm -f "$IMG"
fi

info "Allocating ${SIZE_GB}GB (fallocate)..."
fallocate -l "${SIZE_GB}G" "$IMG" || {
  warn "fallocate gagal, fallback ke dd..."
  dd if=/dev/zero of="$IMG" bs=1G count="$SIZE_GB" status=progress
}

info "Format ext4..."
mkfs.ext4 -F -L "gentoo-root" -m 2 "$IMG" >/dev/null

# ─── Step 2: Attach loop & mount ────────────────────────────
section "Step 2: Attach & mount image"

LOOPDEV=$(sudo losetup --find --show "$IMG")
info "Loop device: $LOOPDEV"

sudo mkdir -p "$CHROOT"
sudo mount "$LOOPDEV" "$CHROOT"

info "Mounted: $LOOPDEV -> $CHROOT"

# ─── Step 3: Resolve latest stage3 ──────────────────────────
section "Step 3: Resolve stage3 terbaru"

MANIFEST_URL="$AUTOBUILDS_BASE/$MANIFEST_FILE"
info "Manifest: $MANIFEST_URL"

MANIFEST_CONTENT=$(curl --fail --silent --location \
  --retry 3 --retry-delay 2 \
  "$MANIFEST_URL") || {
  error "Gagal download manifest."
  exit 1
}

# Ambil line pertama yang mengandung .tar.xz
STAGE3_RELPATH=$(echo "$MANIFEST_CONTENT" \
  | grep -v '^#' \
  | awk '{print $1}' \
  | grep '\.tar\.xz$' \
  | head -n 1)

if [ -z "$STAGE3_RELPATH" ]; then
  error "Gagal parse manifest."
  error "Isi manifest (first 30 lines):"
  echo "$MANIFEST_CONTENT" | head -n 30
  exit 1
fi

STAGE3_URL="$AUTOBUILDS_BASE/$STAGE3_RELPATH"
STAGE3_BASENAME=$(basename "$STAGE3_RELPATH")
DIGEST_URL="${STAGE3_URL}.DIGESTS"
#DIGEST_URL="${STAGE3_URL}.sha256"


info "Stage3 tarball : $STAGE3_BASENAME"
info "Full URL       : $STAGE3_URL"

# ─── Step 4: Download stage3 ────────────────────────────────
section "Step 4: Download stage3"

STAGE3_LOCAL="$TMP_DIR/$STAGE3_BASENAME"
DIGEST_LOCAL="$TMP_DIR/${STAGE3_BASENAME}.sha256"

info "Downloading stage3..."
curl --fail --location \
  --retry 3 --retry-delay 5 \
  --progress-bar \
  -o "$STAGE3_LOCAL" \
  "$STAGE3_URL" || {
  error "Download stage3 gagal."
  exit 1
}

info "Downloading checksum..."
curl --fail --silent --location \
  --retry 3 \
  -o "$DIGEST_LOCAL" \
  "$DIGEST_URL" || {
  warn "Checksum tidak tersedia, skip verify."
  DIGEST_LOCAL=""
}

# ─── Step 5: Verify checksum ────────────────────────────────
section "Step 5: Verify checksum"

if [ -n "${DIGEST_LOCAL:-}" ] && [ -f "$DIGEST_LOCAL" ]; then
    EXPECTED_HASH=$(awk '
        /SHA256 HASH/ {found=1; next}
        found && $1 ~ /^[a-f0-9]{64}$/ {print $1; exit}
    ' "$DIGEST_LOCAL")

    ACTUAL_HASH=$(sha256sum "$STAGE3_LOCAL" | awk '{print $1}')

    if [ -z "$EXPECTED_HASH" ]; then
        warn "Tidak menemukan SHA256 di DIGESTS, skip verify."
    else
        if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
        error "Checksum mismatch!"
        error "Expected: $EXPECTED_HASH"
        error "Actual  : $ACTUAL_HASH"
        exit 1
        fi
        info "Checksum OK: $ACTUAL_HASH"
    fi
  # EXPECTED_HASH=$(awk '{print $1}' "$DIGEST_LOCAL" | head -n 1)
  # ACTUAL_HASH=$(sha256sum "$STAGE3_LOCAL" | awk '{print $1}')

  # if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
  #   error "Checksum mismatch!"
  #   error "Expected: $EXPECTED_HASH"
  #   error "Actual  : $ACTUAL_HASH"
  #   exit 1
  # fi

  # info "Checksum OK: $ACTUAL_HASH"
else
  warn "Skip checksum verification."
fi

info "Stage3 size: $(du -sh "$STAGE3_LOCAL" | awk '{print $1}')"

# ─── Step 6: Extract stage3 into image ──────────────────────
section "Step 6: Extract stage3 ke image"

info "Extracting stage3 ke $CHROOT ..."
sudo tar xpf "$STAGE3_LOCAL" \
  --xattrs-include='*.*' \
  --numeric-owner \
  -C "$CHROOT"

info "Extract selesai."

# ─── Step 7: Basic Gentoo config ────────────────────────────
section "Step 7: Konfigurasi dasar"

sudo mkdir -p "$CHROOT/etc/portage"

sudo tee "$CHROOT/etc/portage/make.conf" >/dev/null <<EOF
# Generated by gentoo-img-wrapper.sh

COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"

MAKEOPTS="-j\$(nproc)"

GENTOO_MIRRORS="$MIRROR"
ACCEPT_LICENSE="*"
EOF

info "make.conf created."

# ─── Step 8: Final report ───────────────────────────────────
section "Step 8: Report"

df -h "$CHROOT" | sed -n '1,2p'

echo
echo -e "${BOLD}${GREEN}════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}   ✅ gentoo.img berhasil dibuat         ${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════${NC}"
echo
echo "Image   : $IMG"
echo "Mount   : $CHROOT"
echo "Stage3  : $STAGE3_BASENAME"
echo "Profile : $PROFILE"
echo
echo "Next step:"
echo "  sudo mount -o loop $IMG $CHROOT"
echo "  sudo chroot $CHROOT /bin/bash"
echo

# ─── Step 9: Clean unmount ──────────────────────────────────
section "Step 9: Unmount & detach loop"

sudo umount -l "$CHROOT"
sudo losetup -d "$LOOPDEV"
LOOPDEV=""

info "Unmount sukses. Done."
