#!/usr/bin/env bash
set -Eeuo pipefail

# Experimental: make the effective WSL distribution root filesystem Btrfs
# while keeping WSL's ext4.vhdx as the bootstrap/backing store.
#
# WSL still starts on ext4. The ext4-side /sbin/init is replaced by a small
# wrapper whose interpreter is a copied static BusyBox. That wrapper mounts the
# image, mirrors WSL-owned runtime mount trees into the Btrfs root, pivot_root(2)s,
# and then execs the distro's normal /sbin/init from Btrfs.
#
# Export anything important before using this:
#   PowerShell> wsl --export <DistroName> backup.tar

BOOTSTRAP_DIR=${WSL_BTRFS_BOOTSTRAP_DIR:-/var/lib/wsl-btrfs-bootstrap}
IMAGE_PATH=${WSL_BTRFS_IMAGE_PATH:-$BOOTSTRAP_DIR/root.btrfs.img}
STAGE_PATH=${WSL_BTRFS_STAGE_PATH:-$BOOTSTRAP_DIR/newroot}
WRAPPER_PATH=${WSL_BTRFS_WRAPPER_PATH:-/usr/local/libexec/wsl-btrfs-root-init}
BUSYBOX_PATH=${WSL_BTRFS_BOOTSTRAP_BUSYBOX:-$BOOTSTRAP_DIR/bin/busybox}
INIT_PATH=${WSL_BTRFS_INIT_PATH:-/sbin/init}
INIT_BACKUP=${WSL_BTRFS_INIT_BACKUP:-$BOOTSTRAP_DIR/init.before-wsl-btrfs-root}
INSTALL_INFO=${WSL_BTRFS_INSTALL_INFO:-$BOOTSTRAP_DIR/install-info}
DEFAULT_SIZE=${WSL_BTRFS_ROOT_SIZE:-256G}
MOUNT_OPTS=${WSL_BTRFS_MOUNT_OPTS:-subvol=@,compress=zstd:1,noatime}
LABEL=${WSL_BTRFS_LABEL:-wsl-btrfs-root}

CMD=''
CMD_ARG=''
FORCE=0
INSTALL_LOOPDEV=''
INSTALL_STAGE_MOUNTED=0
INSTALL_IMAGE_CREATED=0
INSTALL_WRAPPER_CREATED=0
INSTALL_INFO_CREATED=0
INSTALL_INIT_REPLACED=0

log()  { printf '[wsl-btrfs-root] %s\n' "$*"; }
warn() { printf '[wsl-btrfs-root] WARNING: %s\n' "$*" >&2; }
die()  { printf '[wsl-btrfs-root] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  sudo $0 install [--force] [SIZE]
  sudo $0 resize SIZE
       $0 status

Examples:
  sudo $0 install          # 256G sparse Btrfs image
  sudo $0 install 512G
  sudo $0 install --force  # discard only a detected incomplete image/setup
  sudo $0 resize 768G      # growth only, after booting into Btrfs
  $0 status

After 'install', run this from PowerShell and reopen the distro:
  wsl --shutdown
EOF
}

parse_cli() {
  local cmd=${1:-} size=''
  CMD=''
  CMD_ARG=''
  FORCE=0

  case "$cmd" in
    install)
      shift
      while (( $# )); do
        case "$1" in
          --force) FORCE=1 ;;
          -h|--help) CMD=help; return 0 ;;
          --) shift; break ;;
          -*) return 2 ;;
          *)
            [[ -z "$size" ]] || return 2
            size=$1
            ;;
        esac
        shift
      done
      (( $# == 0 )) || return 2
      CMD=install
      CMD_ARG=${size:-$DEFAULT_SIZE}
      ;;
    resize)
      shift
      [[ $# -eq 1 && "$1" != -* ]] || return 2
      CMD=resize
      CMD_ARG=$1
      ;;
    status)
      shift
      [[ $# -eq 0 ]] || return 2
      CMD=status
      ;;
    -h|--help|help|'')
      CMD=help
      ;;
    *)
      return 2
      ;;
  esac
}

is_wsl2() {
  grep -qiE 'microsoft.*wsl2|microsoft-standard-WSL2' /proc/sys/kernel/osrelease 2>/dev/null \
    || [[ -n "${WSL_INTEROP:-}" && -n "${WSL_DISTRO_NAME:-}" ]]
}

root_fstype() {
  findmnt -n -o FSTYPE / 2>/dev/null || stat -f -c %T /
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'run this command with sudo/root'
}

is_static_binary() {
  local binary=$1 output
  [[ -x "$binary" ]] || return 1
  command -v ldd >/dev/null 2>&1 || return 1
  output=$(LC_ALL=C ldd "$binary" 2>&1 || true)
  [[ "$output" == *'not a dynamic executable'* || "$output" == *'statically linked'* ]]
}

find_static_busybox() {
  local candidate
  if [[ -n "${WSL_BTRFS_BUSYBOX:-}" ]]; then
    is_static_binary "$WSL_BTRFS_BUSYBOX" || return 1
    printf '%s\n' "$WSL_BTRFS_BUSYBOX"
    return 0
  fi

  for candidate in /bin/busybox /usr/bin/busybox; do
    if is_static_binary "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

busybox_has_applet() {
  local busybox=$1 applet=$2 applets
  applets=$("$busybox" --list 2>/dev/null) || return 1
  grep -Fxq "$applet" <<<"$applets"
}

busybox_mount_supports() {
  local busybox=$1 pattern=$2 help
  help=$(LC_ALL=C "$busybox" mount --help 2>&1 || true)
  grep -Eq "$pattern" <<<"$help"
}

busybox_accepts_mount_longopt() {
  local busybox=$1 option=$2 output
  output=$(LC_ALL=C "$busybox" mount "$option" /__wsl_btrfs_nonexistent_mountpoint__ 2>&1 || true)
  [[ "$output" != *'unrecognized option'* && "$output" != *'invalid option'* ]]
}

verify_busybox_runtime() {
  local busybox=$1 applet
  for applet in sh mount umount losetup pivot_root mkdir chmod grep uname touch readlink rm ln; do
    busybox_has_applet "$busybox" "$applet" \
      || die "static BusyBox is missing required applet: $applet"
  done

  busybox_mount_supports "$busybox" '(\[r\]bind|rbind)' \
    || die 'static BusyBox mount lacks recursive bind support'
  busybox_mount_supports "$busybox" '(\[r\]slave|rslave)' \
    || die 'static BusyBox mount lacks recursive slave propagation support'
  busybox_accepts_mount_longopt "$busybox" --make-rslave \
    || die 'static BusyBox mount lacks --make-rslave'
  busybox_accepts_mount_longopt "$busybox" --make-slave \
    || die 'static BusyBox mount lacks --make-slave'
  busybox_accepts_mount_longopt "$busybox" --make-private \
    || die 'static BusyBox mount lacks --make-private'

  local losetup_help
  losetup_help=$(LC_ALL=C "$busybox" losetup --help 2>&1 || true)
  grep -Eq '(^|[[:space:]])-f([,[:space:]]|$)' <<<"$losetup_help" \
    || die 'static BusyBox losetup lacks -f'
  grep -Eq '(^|[[:space:]])-d([,[:space:]]|$)' <<<"$losetup_help" \
    || die 'static BusyBox losetup lacks -d'
}

busybox_modprobe_has_dir() {
  local busybox=$1 help
  busybox_has_applet "$busybox" modprobe || return 1
  help=$(LC_ALL=C "$busybox" modprobe --help 2>&1 || true)
  grep -Eq '(^|[[:space:]])-d[[:space:]]+DIR|filesystem root' <<<"$help"
}

install_packages() {
  local missing=0 cmd
  for cmd in rsync mkfs.btrfs btrfs losetup mount findmnt numfmt du df truncate awk sed modprobe; do
    command -v "$cmd" >/dev/null 2>&1 || missing=1
  done
  find_static_busybox >/dev/null 2>&1 || missing=1
  (( missing == 0 )) && return 0

  command -v apt-get >/dev/null 2>&1 \
    || die 'Ubuntu/Debian setup requires apt-get plus rsync, btrfs-progs, util-linux and busybox-static'

  log 'Installing bootstrap/setup dependencies (rsync, btrfs-progs, util-linux, kmod, busybox-static)...'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y rsync btrfs-progs util-linux kmod busybox-static

  for cmd in rsync mkfs.btrfs btrfs losetup mount findmnt modprobe; do
    command -v "$cmd" >/dev/null 2>&1 || die "required setup command is still missing: $cmd"
  done
  find_static_busybox >/dev/null 2>&1 \
    || die 'busybox-static was installed but no statically linked BusyBox was found in /bin or /usr/bin'
}

install_bootstrap_busybox() {
  local source_busybox
  source_busybox=$(find_static_busybox) || die 'no statically linked BusyBox found; install busybox-static or set WSL_BTRFS_BUSYBOX'
  verify_busybox_runtime "$source_busybox"

  install -d -m 0700 "$BOOTSTRAP_DIR/bin"
  if [[ "$source_busybox" != "$BUSYBOX_PATH" ]]; then
    install -m 0755 "$source_busybox" "$BUSYBOX_PATH"
  fi
  is_static_binary "$BUSYBOX_PATH" || die "bootstrap BusyBox is not static: $BUSYBOX_PATH"
  verify_busybox_runtime "$BUSYBOX_PATH"
}

set_wsl_systemd_true() {
  local file=/etc/wsl.conf tmp
  tmp=$(mktemp)
  [[ -e "$file" ]] || : >"$file"
  [[ -e "$file.pre-wsl-btrfs-root" ]] || cp -a "$file" "$file.pre-wsl-btrfs-root"

  awk '
    BEGIN { inboot=0; seenboot=0; seensystemd=0 }
    /^[[:space:]]*\[/ {
      if (inboot && !seensystemd) print "systemd=true"
      inboot=0
      if ($0 ~ /^[[:space:]]*\[boot\][[:space:]]*$/) {
        inboot=1; seenboot=1; seensystemd=0
      }
      print
      next
    }
    {
      if (inboot && $0 ~ /^[[:space:]]*systemd[[:space:]]*=/) {
        if (!seensystemd) print "systemd=true"
        seensystemd=1
        next
      }
      print
    }
    END {
      if (inboot && !seensystemd) print "systemd=true"
      if (!seenboot) {
        print ""
        print "[boot]"
        print "systemd=true"
      }
    }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

human_bytes() {
  numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"
}

size_bytes() {
  numfmt --from=iec "$1" 2>/dev/null
}

check_capacity() {
  local size=$1 used avail image_bytes overhead recommended
  used=$(du -sx -B1 --one-file-system / 2>/dev/null | awk '{print $1}') \
    || die 'could not measure current root filesystem usage'
  avail=$(df -B1 --output=avail / | tail -n1 | tr -d ' ') \
    || die 'could not measure free space on the ext4 root'
  image_bytes=$(size_bytes "$size") || die "invalid image size: $size"

  overhead=$(( used / 10 ))
  (( overhead >= 2147483648 )) || overhead=2147483648
  recommended=$(( used + overhead ))

  log "Current root data: $(human_bytes "$used")"
  log "Host ext4 free space: $(human_bytes "$avail")"
  log "Btrfs image logical size: $(human_bytes "$image_bytes") (sparse)"

  (( image_bytes >= recommended )) \
    || die "image size is too small; use at least about $(human_bytes "$recommended") for the current root"

  # The sparse image only consumes blocks that Btrfs writes, and compression can
  # reduce that amount. We still refuse when ext4 cannot hold roughly one more
  # current-root copy because predicting compression/metadata growth is unsafe.
  (( avail >= used )) \
    || die "ext4 free space ($(human_bytes "$avail")) is below current root usage ($(human_bytes "$used")); migration is likely to run out of space"

  if (( avail < recommended )); then
    warn "free space is below the conservative migration target ($(human_bytes "$recommended")); compression may make it fit, but keep a backup"
  fi
}

is_init_wrapper_installed() {
  [[ -L "$INIT_PATH" ]] || return 1
  [[ $(readlink "$INIT_PATH" 2>/dev/null || true) == "$WRAPPER_PATH" ]]
}

is_fully_installed() {
  [[ -f "$IMAGE_PATH" && -x "$WRAPPER_PATH" && -x "$BUSYBOX_PATH" && -f "$INSTALL_INFO" ]] \
    && grep -qx 'state=installed' "$INSTALL_INFO" \
    && is_init_wrapper_installed
}

prepare_existing_install() {
  local force=$1 attached=''

  if is_fully_installed; then
    log 'Btrfs-root setup is already installed; leaving it unchanged.'
    return 10
  fi

  if [[ ! -e "$IMAGE_PATH" && ! -L "$IMAGE_PATH" \
     && ! -e "$WRAPPER_PATH" && ! -L "$WRAPPER_PATH" \
     && ! -e "$INSTALL_INFO" && ! -L "$INSTALL_INFO" ]]; then
    return 0
  fi

  (( force == 1 )) \
    || die 'an incomplete/previous setup exists; inspect it first or rerun install with --force'

  is_init_wrapper_installed \
    && die '--force refuses to discard the image while /sbin/init still points at the Btrfs wrapper'

  if mountpoint -q "$STAGE_PATH" 2>/dev/null; then
    die "--force refuses to remove an image while $STAGE_PATH is mounted"
  fi

  if [[ -e "$IMAGE_PATH" || -L "$IMAGE_PATH" ]]; then
    [[ ! -L "$IMAGE_PATH" ]] || die "refusing to remove symlink image path: $IMAGE_PATH"
    attached=$(losetup -j "$IMAGE_PATH" 2>/dev/null || true)
    [[ -z "$attached" ]] \
      || die '--force refuses to remove an image that is attached to a loop device'
    [[ -f "$IMAGE_PATH" ]] || die "refusing to remove non-regular image path: $IMAGE_PATH"
    rm -f -- "$IMAGE_PATH"
  fi

  if [[ -e "$WRAPPER_PATH" || -L "$WRAPPER_PATH" ]]; then
    [[ ! -L "$WRAPPER_PATH" ]] || die "refusing to remove symlink wrapper path: $WRAPPER_PATH"
    [[ -f "$WRAPPER_PATH" ]] || die "refusing to remove non-regular wrapper path: $WRAPPER_PATH"
    rm -f -- "$WRAPPER_PATH"
  fi
  [[ ! -L "$INSTALL_INFO" ]] || die "refusing to remove symlink install-info path: $INSTALL_INFO"
  [[ ! -e "$INSTALL_INFO" || -f "$INSTALL_INFO" ]] \
    || die "refusing to remove non-regular install-info path: $INSTALL_INFO"
  rm -f -- "$INSTALL_INFO"
  rmdir "$STAGE_PATH" 2>/dev/null || true
  log 'Removed only the detected incomplete setup artifacts; starting a clean install.'
}

backup_original_init() {
  if [[ ! -e "$INIT_BACKUP" && ! -L "$INIT_BACKUP" ]]; then
    cp -a --no-dereference "$INIT_PATH" "$INIT_BACKUP"
  fi
}

restore_original_init() {
  [[ -e "$INIT_BACKUP" || -L "$INIT_BACKUP" ]] || return 1
  local tmp="${INIT_PATH}.wsl-btrfs-restore.$$"
  rm -f -- "$tmp"
  cp -a --no-dereference "$INIT_BACKUP" "$tmp"
  mv -Tf -- "$tmp" "$INIT_PATH"
}

cleanup_install() {
  local rc=${1:-1} safe_to_remove=1
  set +e

  if (( INSTALL_INIT_REPLACED == 1 && rc != 0 )); then
    if restore_original_init; then
      INSTALL_INIT_REPLACED=0
    else
      safe_to_remove=0
      warn 'failed to restore the original /sbin/init; preserving the image/wrapper for manual recovery'
    fi
  fi

  if (( INSTALL_STAGE_MOUNTED == 1 )); then
    umount "$STAGE_PATH" 2>/dev/null || umount -l "$STAGE_PATH" 2>/dev/null || true
    INSTALL_STAGE_MOUNTED=0
  fi
  if [[ -n "$INSTALL_LOOPDEV" ]]; then
    losetup -d "$INSTALL_LOOPDEV" 2>/dev/null || true
    INSTALL_LOOPDEV=''
  fi

  if (( rc != 0 && safe_to_remove == 1 && INSTALL_INFO_CREATED == 1 )); then
    rm -f -- "$INSTALL_INFO"
  fi
  if (( rc != 0 && safe_to_remove == 1 && INSTALL_WRAPPER_CREATED == 1 && INSTALL_INIT_REPLACED == 0 )); then
    rm -f -- "$WRAPPER_PATH"
  fi
  if (( rc != 0 && safe_to_remove == 1 && INSTALL_IMAGE_CREATED == 1 )); then
    rm -f -- "$IMAGE_PATH"
  fi
  rmdir "$STAGE_PATH" 2>/dev/null || true
}

write_boot_wrapper() {
  local original_init=$1 distro_modprobe=${2:-} bb_has_modprobe=0 bb_modprobe_has_dir=0 tmp
  busybox_has_applet "$BUSYBOX_PATH" modprobe && bb_has_modprobe=1
  busybox_modprobe_has_dir "$BUSYBOX_PATH" && bb_modprobe_has_dir=1

  install -d -m 0755 "$(dirname "$WRAPPER_PATH")"
  tmp="${WRAPPER_PATH}.tmp.$$"

  cat >"$tmp" <<EOF
#!$BUSYBOX_PATH sh
set -eu

BB='$BUSYBOX_PATH'
IMAGE_PATH='$IMAGE_PATH'
NEWROOT='$STAGE_PATH'
MOUNT_OPTS='$MOUNT_OPTS'
ORIGINAL_INIT='$original_init'
DISTRO_MODPROBE='$distro_modprobe'
BB_HAS_MODPROBE='$bb_has_modprobe'
BB_MODPROBE_HAS_DIR='$bb_modprobe_has_dir'
RUNTIME_MODULE_ROOT='/run/booted-system/kernel-modules'
LOOPDEV=''
NEWROOT_MOUNTED=0

bb() {
  "\$BB" "\$@"
}

klog() {
  printf '%s\\n' "wsl-btrfs-root: \$*" >/dev/kmsg 2>/dev/null || true
}

fallback() {
  reason=\$1
  shift
  trap - EXIT HUP INT TERM
  set +e
  klog "Btrfs root activation failed; booting the original ext4 root: \$reason"
  if [ "\$NEWROOT_MOUNTED" -eq 1 ]; then
    bb umount -l "\$NEWROOT" >/dev/null 2>&1 || true
    NEWROOT_MOUNTED=0
  fi
  if [ -n "\$LOOPDEV" ]; then
    bb losetup -d "\$LOOPDEV" >/dev/null 2>&1 || true
    LOOPDEV=''
  fi
  exec "\$ORIGINAL_INIT" "\$@"
}

trap 'rc=\$?; trap - EXIT; fallback "unexpected bootstrap exit (rc=\$rc)" "\$@"' EXIT
trap 'exit 1' HUP INT TERM

rbind_source_tree() {
  src=\$1
  target=\$2
  dst="\$NEWROOT\$target"
  bb mkdir -p "\$dst" || return 1
  bb mount -o rbind "\$src" "\$dst" || return 1
  # Keep receiving WSL/host mount events (for example later DrvFs mounts), but
  # never propagate distro/systemd mounts back into the old ext4 tree.
  bb mount --make-rslave "\$dst" || return 1
}

rbind_tree() {
  rbind_source_tree "\$1" "\$1"
}

rbind_mnt_tree() {
  dst="\$NEWROOT/mnt"
  bb mkdir -p "\$dst" || return 1
  bb mount -o rbind /mnt "\$dst" || return 1
  # WSL deliberately keeps /mnt/wsl shared across distributions. Only make
  # the cloned /mnt mount itself a slave: this receives later DrvFs mounts
  # from WSL while preserving propagation flags on nested WSL-owned mounts.
  bb mount --make-slave "\$dst" || return 1
}

rbind_tree_if_exists() {
  [ -e "\$1" ] || return 0
  rbind_tree "\$1"
}

carry_kernel_modules() {
  kernel=\$(bb uname -r) || return 1
  normal_modules="/usr/lib/modules/\$kernel"
  runtime_modules="\$RUNTIME_MODULE_ROOT/lib/modules/\$kernel"

  if [ -d "\$normal_modules" ]; then
    rbind_tree /usr/lib/modules
  elif [ -d "\$runtime_modules" ]; then
    # Some WSL/system layouts expose the booted kernel tree only under /run.
    # Bind it into the conventional location for the new root without creating
    # a persistent symlink in the migrated filesystem.
    rbind_source_tree "\$RUNTIME_MODULE_ROOT/lib/modules" /usr/lib/modules
  elif [ -e /usr/lib/modules ]; then
    rbind_tree /usr/lib/modules
  fi
}

btrfs_available() {
  bb grep -qw btrfs /proc/filesystems 2>/dev/null
}

load_btrfs_module() {
  btrfs_available && return 0

  if [ "\$BB_HAS_MODPROBE" -eq 1 ]; then
    bb modprobe btrfs >/dev/null 2>&1 || true
    btrfs_available && return 0
  fi

  if [ -n "\$DISTRO_MODPROBE" ] && [ -x "\$DISTRO_MODPROBE" ]; then
    "\$DISTRO_MODPROBE" btrfs >/dev/null 2>&1 || true
    btrfs_available && return 0
  fi

  kernel=\$(bb uname -r) || return 1
  runtime_modules="\$RUNTIME_MODULE_ROOT/lib/modules/\$kernel"
  if [ -d "\$runtime_modules" ]; then
    if [ "\$BB_HAS_MODPROBE" -eq 1 ] && [ "\$BB_MODPROBE_HAS_DIR" -eq 1 ]; then
      bb modprobe -d "\$RUNTIME_MODULE_ROOT" btrfs >/dev/null 2>&1 || true
      btrfs_available && return 0
    fi
    if [ -n "\$DISTRO_MODPROBE" ] && [ -x "\$DISTRO_MODPROBE" ]; then
      "\$DISTRO_MODPROBE" -d "\$RUNTIME_MODULE_ROOT" -S "\$kernel" btrfs >/dev/null 2>&1 \
        || "\$DISTRO_MODPROBE" -d "\$RUNTIME_MODULE_ROOT" btrfs >/dev/null 2>&1 \
        || true
      btrfs_available && return 0
    fi
  fi

  return 1
}

[ -f "\$IMAGE_PATH" ] || fallback "missing \$IMAGE_PATH" "\$@"
load_btrfs_module || fallback 'Btrfs is not available and module loading failed' "\$@"

bb mkdir -p "\$NEWROOT" || fallback 'failed to create new root mountpoint' "\$@"
LOOPDEV=\$(bb losetup -f) || fallback 'failed to allocate loop device' "\$@"
bb losetup "\$LOOPDEV" "\$IMAGE_PATH" \
  || fallback 'failed to attach Btrfs image to loop device' "\$@"
bb mount -t btrfs -o "\$MOUNT_OPTS" "\$LOOPDEV" "\$NEWROOT" \
  || fallback 'failed to mount Btrfs root' "\$@"
NEWROOT_MOUNTED=1

# These are runtime trees owned by WSL/kernel userspace, not distro rootfs data.
# For proc/sys/dev/run, recursively becoming a slave receives later WSL mounts
# while preventing systemd teardown from propagating back into the bootstrap.
for tree in /proc /sys /dev /run; do
  rbind_tree "\$tree" || fallback "failed to carry \$tree" "\$@"
done

# /mnt is different: nested /mnt/wsl is intentionally shared across distros.
# Preserve nested propagation state while making only the cloned /mnt a slave.
rbind_mnt_tree || fallback 'failed to carry /mnt' "\$@"
rbind_tree_if_exists /usr/lib/wsl \
  || fallback 'failed to carry /usr/lib/wsl' "\$@"
carry_kernel_modules \
  || fallback 'failed to carry WSL kernel modules' "\$@"

# Microsoft's /init is needed for interop, DrvFs helpers and Windows process
# launching. It is a file mount on normal WSL setups, so bind it separately.
if [ -e /init ]; then
  bb touch "\$NEWROOT/init" || fallback 'failed to prepare /init target' "\$@"
  bb mount -o bind /init "\$NEWROOT/init" \
    || fallback 'failed to bind /init' "\$@"
else
  fallback '/init is missing' "\$@"
fi

bb mkdir -p "\$NEWROOT/.wsl-bootstrap" \
  || fallback 'failed to create pivot_root old-root directory' "\$@"
bb chmod 0700 "\$NEWROOT/.wsl-bootstrap" \
  || fallback 'failed to protect pivot_root old-root directory' "\$@"

# pivot_root rejects a shared parent. Make only the two root mounts private;
# doing this recursively would sever WSL's propagation relationship under /mnt.
bb mount --make-private / \
  || fallback 'failed to make the old root private' "\$@"
bb mount --make-private "\$NEWROOT" \
  || fallback 'failed to make the new root private' "\$@"

cd "\$NEWROOT" || fallback 'failed to enter new root' "\$@"
bb pivot_root . .wsl-bootstrap \
  || { cd /; fallback 'pivot_root failed' "\$@"; }
cd /

# From here on, no BusyBox applet is used. The BusyBox process is only the
# bootstrap shell and disappears when exec replaces it with the distro init.
trap - EXIT HUP INT TERM
klog 'Btrfs root active; execing distro init'
exec /sbin/init "\$@"

# If the Btrfs copy somehow lost its init, prefer a recoverable ext4 boot over
# leaving WSL dead. exec only returns when it fails.
exec "/.wsl-bootstrap\$ORIGINAL_INIT" "\$@"
EOF

  chmod 0755 "$tmp"
  mv -Tf -- "$tmp" "$WRAPPER_PATH"
}

install_root() {
  require_root
  is_wsl2 || die 'this script is intended for WSL2'

  local fs size=${1:-$DEFAULT_SIZE} original_init distro_modprobe=''
  fs=$(root_fstype)
  if [[ "$fs" == btrfs ]]; then
    log 'root is already Btrfs; install is not needed and no changes were made.'
    return 0
  fi
  [[ "$fs" == ext4 ]] || warn "current root filesystem is $fs, not ext4"

  prepare_existing_install "$FORCE" || {
    local state=$?
    (( state == 10 )) && return 0
    return "$state"
  }

  original_init=$(readlink -f "$INIT_PATH" 2>/dev/null || true)
  [[ -n "$original_init" && -x "$original_init" ]] \
    || die "could not resolve an executable init from $INIT_PATH"
  [[ $(basename "$original_init") == systemd ]] \
    || warn "$INIT_PATH resolves to $original_init (systemd was expected but is not required)"

  install_packages
  set_wsl_systemd_true
  check_capacity "$size"

  install -d -m 0700 "$BOOTSTRAP_DIR"
  install_bootstrap_busybox
  command -v modprobe >/dev/null 2>&1 && distro_modprobe=$(command -v modprobe)
  backup_original_init

  mkdir -p "$STAGE_PATH"
  truncate -s "$size" "$IMAGE_PATH"
  chmod 0600 "$IMAGE_PATH"
  INSTALL_IMAGE_CREATED=1

  trap 'rc=$?; cleanup_install "$rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  INSTALL_LOOPDEV=$(losetup --find --show --nooverlap "$IMAGE_PATH")
  log "Formatting $INSTALL_LOOPDEV as Btrfs..."
  mkfs.btrfs -f -L "$LABEL" "$INSTALL_LOOPDEV"

  mount -t btrfs "$INSTALL_LOOPDEV" "$STAGE_PATH"
  INSTALL_STAGE_MOUNTED=1
  btrfs subvolume create "$STAGE_PATH/@"
  umount "$STAGE_PATH"
  INSTALL_STAGE_MOUNTED=0

  mount -t btrfs -o "$MOUNT_OPTS" "$INSTALL_LOOPDEV" "$STAGE_PATH"
  INSTALL_STAGE_MOUNTED=1

  log 'Copying the existing WSL root into Btrfs...'
  rsync -aHAXx --numeric-ids --info=progress2 \
    --exclude="$BOOTSTRAP_DIR/***" \
    --exclude='/proc/***' \
    --exclude='/sys/***' \
    --exclude='/dev/***' \
    --exclude='/run/***' \
    --exclude='/mnt/***' \
    --exclude='/tmp/***' \
    --exclude='/lost+found' \
    / "$STAGE_PATH/"

  mkdir -p "$STAGE_PATH"/{proc,sys,dev,run,mnt,tmp}
  [[ ! -e /usr/lib/wsl ]] || mkdir -p "$STAGE_PATH/usr/lib/wsl"
  [[ ! -e /usr/lib/modules ]] || mkdir -p "$STAGE_PATH/usr/lib/modules"
  chmod 1777 "$STAGE_PATH/tmp"

  umount "$STAGE_PATH"
  INSTALL_STAGE_MOUNTED=0
  losetup -d "$INSTALL_LOOPDEV"
  INSTALL_LOOPDEV=''

  # The copy above intentionally happens before replacing ext4 /sbin/init, so
  # Btrfs retains the distro's genuine init. The ext4 side only gets the wrapper.
  write_boot_wrapper "$original_init" "$distro_modprobe"
  INSTALL_WRAPPER_CREATED=1

  cat >"$INSTALL_INFO" <<EOF
state=prepared
installed_at=$(date -Is)
image=$IMAGE_PATH
size=$size
mount_opts=$MOUNT_OPTS
original_init=$original_init
busybox=$BUSYBOX_PATH
EOF
  INSTALL_INFO_CREATED=1

  local init_tmp="${INIT_PATH}.wsl-btrfs.$$"
  rm -f -- "$init_tmp"
  ln -s "$WRAPPER_PATH" "$init_tmp"
  mv -Tf -- "$init_tmp" "$INIT_PATH"
  INSTALL_INIT_REPLACED=1

  sed -i 's/^state=prepared$/state=installed/' "$INSTALL_INFO"
  sync

  INSTALL_IMAGE_CREATED=0
  INSTALL_WRAPPER_CREATED=0
  INSTALL_INFO_CREATED=0
  INSTALL_INIT_REPLACED=0
  trap - EXIT INT TERM

  log 'Installed.'
  log 'Now leave WSL and run:  wsl --shutdown'
  log 'Then reopen this distro and run this script with: status'
  warn 'This is experimental. Keep the WSL export until the new root has been exercised.'
}

backing_image_path() {
  if [[ "$(root_fstype)" == btrfs && -f "/.wsl-bootstrap$IMAGE_PATH" ]]; then
    printf '%s\n' "/.wsl-bootstrap$IMAGE_PATH"
  else
    printf '%s\n' "$IMAGE_PATH"
  fi
}

resize_root() {
  require_root
  local size=${1:-} image loopdev current_bytes requested_bytes
  [[ -n "$size" ]] || die 'resize requires a size, e.g. 512G'
  [[ "$(root_fstype)" == btrfs ]] || die 'resize is intended to be run after Btrfs is the active root'

  image=$(backing_image_path)
  [[ -f "$image" ]] || die "backing image not found: $image"
  current_bytes=$(stat -c %s "$image")
  requested_bytes=$(size_bytes "$size") || die "invalid image size: $size"
  (( requested_bytes >= current_bytes )) \
    || die 'shrinking the backing image is intentionally unsupported because truncating it can destroy Btrfs'
  if (( requested_bytes == current_bytes )); then
    log "Backing image is already $size; nothing to do."
    return 0
  fi

  truncate -s "$size" "$image"
  loopdev=$(findmnt -n -o SOURCE / | sed 's/\[.*$//')
  [[ "$loopdev" == /dev/loop* ]] || die "root source is not a loop device: $loopdev"
  losetup -c "$loopdev"
  btrfs filesystem resize max /
  log "Resized Btrfs root backing image to $size"
}

status_root() {
  is_wsl2 || warn 'WSL2 was not positively detected'
  local fs src kernel module_runtime
  fs=$(root_fstype)
  src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
  kernel=$(uname -r 2>/dev/null || true)
  module_runtime="/run/booted-system/kernel-modules/lib/modules/$kernel"

  printf 'root filesystem : %s\n' "$fs"
  printf 'root source     : %s\n' "${src:-unknown}"
  printf '/init           : %s\n' "$([[ -x /init ]] && echo OK || echo MISSING)"
  printf '/run/WSL        : %s\n' "$([[ -d /run/WSL ]] && echo OK || echo MISSING)"
  printf '/mnt            : %s\n' "$(mountpoint -q /mnt 2>/dev/null && echo mounted || echo tree-present)"
  printf '/mnt/wsl        : %s\n' "$(mountpoint -q /mnt/wsl 2>/dev/null && echo mounted || echo not-mounted)"
  printf '/usr/lib/wsl    : %s\n' "$([[ -e /usr/lib/wsl ]] && echo present || echo missing)"
  printf 'runtime modules : %s\n' "$([[ -d "$module_runtime" ]] && echo "$module_runtime" || echo not-present)"
  printf 'systemd         : %s\n' "$(systemctl is-system-running 2>/dev/null || echo unavailable)"
  printf 'Windows interop : %s\n' "$(command -v powershell.exe >/dev/null 2>&1 && echo OK || echo not-found)"
  printf 'code            : %s\n' "$(command -v code >/dev/null 2>&1 && echo found || echo not-found)"
  if [[ "$fs" == btrfs ]]; then
    printf 'bootstrap ext4  : %s\n' "$([[ -d /.wsl-bootstrap ]] && echo '/.wsl-bootstrap' || echo hidden/missing)"
    printf 'bootstrap BB    : %s\n' "$([[ -x "/.wsl-bootstrap$BUSYBOX_PATH" ]] && echo static-copy-present || echo missing)"
    btrfs filesystem usage / 2>/dev/null | sed 's/^/  /' || true
  fi
}

main() {
  if ! parse_cli "$@"; then
    usage >&2
    return 2
  fi

  case "$CMD" in
    install) install_root "$CMD_ARG" ;;
    resize) resize_root "$CMD_ARG" ;;
    status) status_root ;;
    help) usage ;;
    *) usage >&2; return 2 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
