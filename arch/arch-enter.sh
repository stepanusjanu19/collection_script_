#!/usr/bin/env bash
set -euo pipefail

# BlackArch chroot helper — fixed and robust
# Usage: sudo ./blackarch-enter.sh {enter|cleanup|status}
CHROOT="/blackarch"

# ---------- helpers ----------
mount_exists(){ mountpoint -q "$1"; }
safe_mkdir(){ [ -d "$1" ] || sudo mkdir -p "$1"; }

# cleanup in reverse order to avoid busy resources
cleanup_mounts() {
  echo -e "\n🧹 Cleaning up mounts (lazy unmount)..."
  for mp in \
    "$CHROOT/etc/resolv.conf" \
    "$CHROOT/var/cache/pacman/pkg" \
    "$CHROOT/run" \
    "$CHROOT/dev/pts" \
    "$CHROOT/dev" \
    "$CHROOT/sys" \
    "$CHROOT/proc"; do
    if mount_exists "$mp"; then
      echo "🔻 Unmounting $mp"
      sudo umount -l "$mp" >/dev/null 2>&1 || true
    fi
  done

  if losetup -a | grep -q "/blackarch.img"; then
     echo "🔻 Detaching loop device(s)"
     sudo losetup -D >/dev/null 2>&1 || true
  fi

  echo "✨ Cleanup complete"
}

# print quick diagnostics
diagnose() {
  echo; echo "=== CHROOT MOUNTS ==="
  mount | grep "$CHROOT" || echo "(no mounts under $CHROOT)"
  echo; echo "=== CHROOT /proc/sys/kernel/random ==="
  ls -l "$CHROOT/proc/sys/kernel/random" 2>/dev/null || echo "(not present)"
  echo; echo "=== CHROOT /dev listing (first 20) ==="
  ls -l "$CHROOT/dev" 2>/dev/null | sed -n '1,20p' || true
  echo; echo "=== CHROOT /etc/resolv.conf ==="
  [ -f "$CHROOT/etc/resolv.conf" ] && sudo cat "$CHROOT/etc/resolv.conf" || echo "(no file)"
  echo "======================" ; echo
}

# mount helpers
mount_bind_file() {
  local src="$1" dest="$2"
  safe_mkdir "$(dirname "$dest")"
  sudo rm -f "$dest" >/dev/null 2>&1 || true
  if ! mount_exists "$dest"; then
    sudo mount --bind "$src" "$dest"
    echo "📌 Bound $src -> $dest"
  else
    echo "✔ Already bound: $dest"
  fi
}

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

# prepare chroot environment
setup() {
  echo "📦 Preparing $CHROOT ..."

  # ensure required directories exist
  safe_mkdir "$CHROOT"
  safe_mkdir "$CHROOT/etc"
  safe_mkdir "$CHROOT/dev/pts"
  safe_mkdir "$CHROOT/dev/shm"
  safe_mkdir "$CHROOT/var/cache/pacman/pkg"
  safe_mkdir "$CHROOT/run"

  # 1) Ensure /proc inside chroot is a real procfs (unmount any stale then mount type proc)
  if mount_exists "$CHROOT/proc"; then
    echo "Note: $CHROOT/proc already mounted — remounting as real procfs..."
    sudo umount -l "$CHROOT/proc" >/dev/null 2>&1 || true
  fi
  sudo mount -t proc proc "$CHROOT/proc"
  echo "📌 Mounted proc (type proc) -> $CHROOT/proc"

  # 2) rbind /sys, /dev, /run
  mount_rbind_dir /sys "$CHROOT/sys"
  mount_rbind_dir /dev "$CHROOT/dev"
  # ensure devpts
  if ! mount_exists "$CHROOT/dev/pts"; then
    sudo mount -t devpts devpts "$CHROOT/dev/pts" -o gid=5,mode=620 || true
    echo "📌 Mounted devpts -> $CHROOT/dev/pts"
  else
    echo "✔ $CHROOT/dev/pts already mounted"
  fi
  mount_rbind_dir /run "$CHROOT/run"

  # 3) ensure /dev/fd inside chroot points to /proc/self/fd
  if [ ! -e "$CHROOT/dev/fd" ]; then
    sudo mkdir -p "$CHROOT/dev"
    sudo ln -sf /proc/self/fd "$CHROOT/dev/fd" || true
    echo "🔧 Created symlink $CHROOT/dev/fd -> /proc/self/fd"
  else
    echo "✔ $CHROOT/dev/fd exists"
  fi

  # 4) bind pacman cache (host) into chroot to help pacman with space / cache
  safe_mkdir /var/cache/pacman/pkg
  if ! mount_exists "$CHROOT/var/cache/pacman/pkg"; then
    sudo mount --bind /var/cache/pacman/pkg "$CHROOT/var/cache/pacman/pkg" 2>/dev/null || true
    echo "📌 Bound /var/cache/pacman/pkg -> $CHROOT/var/cache/pacman/pkg"
  else
    echo "✔ $CHROOT/var/cache/pacman/pkg already bound"
  fi

  # 5) bind a *real* host resolv.conf target into chroot (handle symlinks)
  #    Use readlink -f to resolve symlink target; if none, create a fallback on host and bind that.
  HOST_RESOLV=$(readlink -f /etc/resolv.conf 2>/dev/null || true)
  if [ -n "$HOST_RESOLV" ] && [ -f "$HOST_RESOLV" ]; then
    # ensure chroot etc parent exists, remove old dest if any
    safe_mkdir "$CHROOT/etc"
    sudo rm -f "$CHROOT/etc/resolv.conf" >/dev/null 2>&1 || true
    sudo cp "$HOST_RESOLV" "$CHROOT/etc/resolv.conf"
    echo "📡 Bound host resolver ($HOST_RESOLV) -> $CHROOT/etc/resolv.conf"
  else
    echo "⚠ Host /etc/resolv.conf target missing or not a file. Creating fallback on host and binding."
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" | sudo tee /etc/resolv.conf >/dev/null
    sudo rm -f "$CHROOT/etc/resolv.conf" >/dev/null 2>&1 || true
    sudo cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"
    echo "📡 Bound fallback /etc/resolv.conf -> $CHROOT/etc/resolv.conf"
  fi

  echo; diagnose
}

# attach & mount BlackArch disk image
attach_img() {
  # configurable path to your BlackArch image
  IMG_PATH="${BLACKARCH_IMG:-./blackarch.img}"

  # ensure the image exists
  if [ ! -f "$IMG_PATH" ]; then
    echo "❌ BlackArch image not found at $IMG_PATH"
    exit 1
  fi

  # check if already mounted
  if mount_exists "$CHROOT"; then
    echo "✔ $CHROOT already mounted"
    return
  fi

  # check if image is already attached to a loop device
  LOOPDEV=$(losetup -j "$IMG_PATH" | cut -d: -f1)
  if [ -n "$LOOPDEV" ]; then
    echo "🔎 Found existing loop device: $LOOPDEV"
  else
    # attach the image to the next free loop device
    LOOPDEV=$(sudo losetup --find --show "$IMG_PATH")
    echo "📎 Attached $IMG_PATH -> $LOOPDEV"
  fi

  # mount the loop device to CHROOT
  sudo mount "$LOOPDEV" "$CHROOT"
  echo "📌 Mounted $LOOPDEV -> $CHROOT"
}
#attach_img() {
#  if ! mount_exists "$CHROOT"; then
#    echo "🔗 Attaching loop device to blackarch.img..."
#    LOOPDEV=$(losetup --find --show /blackarch.img)
#    echo "📎 Using loop device: $LOOPDEV"
#    sudo mount "$LOOPDEV" "$CHROOT"
#    echo "📌 Mounted $LOOPDEV -> $CHROOT"
#  else
#    echo "✔ $CHROOT already mounted"
#  fi
#}


# enter interactive chroot shell (cleanup will run after exit)
enter() {
  attach_img
  setup
  echo "🚀 Entering chroot (interactive shell). Use 'exit' to leave."
  sudo env TERM="${TERM:-xterm-256color}" chroot "$CHROOT" /bin/bash --login
  echo -e "\n👋 Exited chroot, cleaning up mounts..."
  cleanup_mounts
  sudo losetup -D   # detach all loop devices
}

# simple cleanup-only mode
cleanup_only() {
  cleanup_mounts
}

case "${1:-}" in
  enter)  enter ;;
  cleanup) cleanup_only ;;
  status) diagnose ;;
  *) echo "Usage: $0 {enter|cleanup|status}"; exit 1 ;;
esac

