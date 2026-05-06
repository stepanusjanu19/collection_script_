#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Gentoo chroot helper — ported from blackarch-enter.sh
# Usage: sudo ./gentoo-enter.sh {enter|cleanup|status|build}
# Requires: gentoo.img (buat dulu dengan build-gentoo-img.sh)
# ============================================================

CHROOT="/gentoo"
IMG_PATH="${GENTOO_IMG:-./gentoo.img}"

# ─── Helpers ────────────────────────────────────────────────
mount_exists() { mountpoint -q "$1"; }
safe_mkdir()   { [ -d "$1" ] || sudo mkdir -p "$1"; }

# ─── Cleanup (reverse order) ────────────────────────────────
cleanup_mounts() {
  echo -e "\n🧹 Cleaning up Gentoo chroot mounts..."

  for mp in \
    "$CHROOT/etc/resolv.conf" \
    "$CHROOT/var/cache/distfiles" \
    "$CHROOT/var/cache/binpkgs" \
    "$CHROOT/run" \
    "$CHROOT/dev/pts" \
    "$CHROOT/dev" \
    "$CHROOT/sys" \
    "$CHROOT/proc"; do
    if mount_exists "$mp" 2>/dev/null; then
      echo "🔻 Unmounting $mp"
      sudo umount -l "$mp" >/dev/null 2>&1 || true
    fi
  done

  if mount_exists "$CHROOT" 2>/dev/null; then
    echo "🔻 Unmounting $CHROOT root"
    sudo umount -l "$CHROOT" >/dev/null 2>&1 || true
  fi

  if losetup -a | grep -q "gentoo.img"; then
    echo "🔻 Detaching loop device(s)"
    sudo losetup -D >/dev/null 2>&1 || true
  fi

  echo "✨ Cleanup complete"
}

# ─── Diagnostics ────────────────────────────────────────────
diagnose() {
  echo; echo "=== CHROOT MOUNTS ==="
  mount | grep "$CHROOT" || echo "(no mounts under $CHROOT)"
  echo; echo "=== /proc check ==="
  ls "$CHROOT/proc/sys/kernel/random" 2>/dev/null || echo "(not present)"
  echo; echo "=== /dev listing (first 20) ==="
  ls -l "$CHROOT/dev" 2>/dev/null | head -20 || true
  echo; echo "=== resolv.conf ==="
  [ -f "$CHROOT/etc/resolv.conf" ] && sudo cat "$CHROOT/etc/resolv.conf" || echo "(none)"
  echo; echo "=== Portage check ==="
  [ -d "$CHROOT/etc/portage" ] && echo "✅ /etc/portage exists" || echo "⚠ /etc/portage missing"
  echo "======================"
}

# ─── rbind helper ───────────────────────────────────────────
mount_rbind_dir() {
  local src="$1" dest="$2"
  safe_mkdir "$dest"
  if ! mount_exists "$dest"; then
    sudo mount --rbind "$src" "$dest"
    sudo mount --make-rslave "$dest" 2>/dev/null || true
    echo "📌 rbind $src -> $dest"
  else
    echo "✔ Already rbound: $dest"
  fi
}

# ─── Setup mounts ───────────────────────────────────────────
setup() {
  echo "📦 Preparing Gentoo chroot at $CHROOT..."

  safe_mkdir "$CHROOT/etc"
  safe_mkdir "$CHROOT/dev/pts"
  safe_mkdir "$CHROOT/dev/shm"
  safe_mkdir "$CHROOT/run"
  safe_mkdir "$CHROOT/var/cache/distfiles"
  safe_mkdir "$CHROOT/var/cache/binpkgs"

  # 1) proc (real procfs — wajib untuk emerge)
  if mount_exists "$CHROOT/proc"; then
    sudo umount -l "$CHROOT/proc" >/dev/null 2>&1 || true
  fi
  sudo mount -t proc proc "$CHROOT/proc"
  echo "📌 Mounted proc -> $CHROOT/proc"

  # 2) sys, dev, run
  mount_rbind_dir /sys "$CHROOT/sys"
  mount_rbind_dir /dev "$CHROOT/dev"

  if ! mount_exists "$CHROOT/dev/pts"; then
    sudo mount -t devpts devpts "$CHROOT/dev/pts" -o gid=5,mode=620 || true
    echo "📌 Mounted devpts -> $CHROOT/dev/pts"
  fi

  # /dev/shm permission fix (penting untuk Gentoo builds)
  sudo chmod 1777 "$CHROOT/dev/shm" 2>/dev/null || true

  mount_rbind_dir /run "$CHROOT/run"

  # 3) /dev/fd symlink
  if [ ! -e "$CHROOT/dev/fd" ]; then
    sudo ln -sf /proc/self/fd "$CHROOT/dev/fd" || true
    echo "🔧 Symlink $CHROOT/dev/fd -> /proc/self/fd"
  fi

  # 4) Bind Portage download cache (host -> chroot, hemat bandwidth)
  sudo mkdir -p /var/cache/distfiles /var/cache/binpkgs
  if ! mount_exists "$CHROOT/var/cache/distfiles"; then
    sudo mount --bind /var/cache/distfiles "$CHROOT/var/cache/distfiles" 2>/dev/null || true
    echo "📌 Bound distfiles cache"
  fi
  if ! mount_exists "$CHROOT/var/cache/binpkgs"; then
    sudo mount --bind /var/cache/binpkgs "$CHROOT/var/cache/binpkgs" 2>/dev/null || true
    echo "📌 Bound binpkgs cache"
  fi

  # 5) resolv.conf — handle symlink (systemd-resolved, resolvconf, direct)
  HOST_RESOLV=$(readlink -f /etc/resolv.conf 2>/dev/null || true)
  sudo rm -f "$CHROOT/etc/resolv.conf" 2>/dev/null || true
  if [ -n "$HOST_RESOLV" ] && [ -f "$HOST_RESOLV" ]; then
    sudo cp "$HOST_RESOLV" "$CHROOT/etc/resolv.conf"
    echo "📡 Copied resolver: $HOST_RESOLV -> $CHROOT/etc/resolv.conf"
  else
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" \
      | sudo tee "$CHROOT/etc/resolv.conf" >/dev/null
    echo "📡 Injected fallback DNS"
  fi

  # 6) Inject Gentoo-specific environment ke dalam chroot
  sudo tee "$CHROOT/etc/environment" >/dev/null <<'EOF'
MAKEOPTS="-j$(nproc)"
FEATURES="parallel-fetch"
GENTOO_MIRRORS="https://distfiles.gentoo.org"
EOF
  echo "⚙ Injected Gentoo environment vars"

  echo; diagnose
}

# ─── Attach image ────────────────────────────────────────────
attach_img() {
  if [ ! -f "$IMG_PATH" ]; then
    echo "❌ Gentoo image tidak ditemukan: $IMG_PATH"
    echo "   Jalankan dulu: sudo ./build-gentoo-img.sh"
    exit 1
  fi

  if mount_exists "$CHROOT"; then
    echo "✔ $CHROOT sudah ter-mount"
    return
  fi

  LOOPDEV=$(losetup -j "$IMG_PATH" | cut -d: -f1)
  if [ -z "$LOOPDEV" ]; then
    LOOPDEV=$(sudo losetup --find --show "$IMG_PATH")
    echo "📎 Attached $IMG_PATH -> $LOOPDEV"
  else
    echo "🔎 Existing loop device: $LOOPDEV"
  fi

  sudo mount "$LOOPDEV" "$CHROOT"
  echo "📌 Mounted $LOOPDEV -> $CHROOT"
}

# ─── Post-enter first-run helper ────────────────────────────
first_run_hint() {
  cat <<'HINT'

╔══════════════════════════════════════════════════════╗
║         GENTOO CHROOT — FIRST RUN CHECKLIST          ║
╠══════════════════════════════════════════════════════╣
║  Sync portage tree:                                  ║
║    emerge-webrsync                                   ║
║    emerge --sync                                     ║
║                                                      ║
║  Set profile:                                        ║
║    eselect profile list                              ║
║    eselect profile set <nomor>                       ║
║                                                      ║
║  Update world:                                       ║
║    emerge --ask --verbose --update --deep \          ║
║           --newuse @world                            ║
║                                                      ║
║  Install security tools:                             ║
║    emerge nmap wireshark metasploit                  ║
╚══════════════════════════════════════════════════════╝

HINT
}

# ─── Enter chroot ────────────────────────────────────────────
enter() {
  attach_img
  setup
  first_run_hint
  echo "🚀 Entering Gentoo chroot. Ketik 'exit' untuk keluar."
  sudo env \
    TERM="${TERM:-xterm-256color}" \
    HOME=/root \
    SHELL=/bin/bash \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    chroot "$CHROOT" /bin/bash --login
  echo -e "\n👋 Keluar dari chroot, cleanup..."
  cleanup_mounts
  sudo losetup -D
}

# ─── CLI dispatch ────────────────────────────────────────────
case "${1:-}" in
  enter)   enter ;;
  cleanup) cleanup_mounts ;;
  status)  attach_img && diagnose ;;
  build)
    echo "▶ Jalankan build-gentoo-img.sh untuk membuat image..."
    bash ./build-gentoo-img.sh
    ;;
  *)
    echo "Usage: $0 {enter|cleanup|status|build}"
    exit 1
    ;;
esac
