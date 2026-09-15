#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT=${SCRIPT:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/experimental-wsl-btrfs-root.sh"}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export WSL_BTRFS_BOOTSTRAP_DIR="$TMP/bootstrap"
export WSL_BTRFS_IMAGE_PATH="$TMP/bootstrap/root.btrfs.img"
export WSL_BTRFS_STAGE_PATH="$TMP/bootstrap/newroot"
export WSL_BTRFS_WRAPPER_PATH="$TMP/libexec/wsl-btrfs-root-init"
export WSL_BTRFS_BOOTSTRAP_BUSYBOX=/usr/bin/busybox
export WSL_BTRFS_INIT_PATH="$TMP/sbin/init"
export WSL_BTRFS_INIT_BACKUP="$TMP/bootstrap/init.backup"
export WSL_BTRFS_INSTALL_INFO="$TMP/bootstrap/install-info"
unset WSL_BTRFS_MOUNT_OPTS WSL_BTRFS_ROOT_SIZE WSL_BTRFS_BUSYBOX

# shellcheck source=/dev/null
source "$SCRIPT"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

assert_file_contains() {
  grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_file_not_contains() {
  if grep -Fq -- "$2" "$1"; then
    fail "$1 unexpectedly contains: $2"
  fi
}

printf '1..13\n'

parse_cli install
assert_eq "$CMD" install
assert_eq "$CMD_ARG" 256G
assert_eq "$FORCE" 0
parse_cli install --force 512G
assert_eq "$CMD_ARG" 512G
assert_eq "$FORCE" 1
if parse_cli install 128G extra; then
  fail 'invalid install arguments were accepted'
fi
printf 'ok 1 - setup argument parsing\n'

assert_eq "$MOUNT_OPTS" 'subvol=@,compress=zstd:1,noatime'
[[ "$MOUNT_OPTS" != *sync* ]] || fail 'default mount options unexpectedly enable sync I/O'
printf 'ok 2 - mount option defaults\n'

verify_busybox_runtime /usr/bin/busybox
printf 'ok 3 - BusyBox required applets/options\n'

WSL_BTRFS_BUSYBOX="$TMP/does-not-exist"
if find_static_busybox >/dev/null 2>&1; then
  fail 'missing explicitly selected BusyBox was accepted'
fi
unset WSL_BTRFS_BUSYBOX
printf 'ok 4 - missing BusyBox is rejected\n'

mkdir -p "$(dirname "$INIT_PATH")" "$(dirname "$WRAPPER_PATH")" "$BOOTSTRAP_DIR"
printf '#!/bin/sh\n' >"$WRAPPER_PATH"
chmod +x "$WRAPPER_PATH"
: >"$IMAGE_PATH"
printf 'state=installed\n' >"$INSTALL_INFO"
ln -s "$WRAPPER_PATH" "$INIT_PATH"
is_fully_installed || fail 'complete install state was not detected'
set +e
prepare_existing_install 0 >/dev/null
rc=$?
set -e
assert_eq "$rc" 10
printf 'ok 5 - installed state is idempotent\n'

rm -f "$INIT_PATH" "$WRAPPER_PATH" "$IMAGE_PATH" "$INSTALL_INFO"
: >"$IMAGE_PATH"
printf '#!/bin/sh\n' >"$WRAPPER_PATH"
printf 'state=prepared\n' >"$INSTALL_INFO"
INSTALL_IMAGE_CREATED=1
INSTALL_WRAPPER_CREATED=1
INSTALL_INFO_CREATED=1
INSTALL_INIT_REPLACED=0
INSTALL_STAGE_MOUNTED=0
INSTALL_LOOPDEV=''
cleanup_install 1
[[ ! -e "$IMAGE_PATH" ]] || fail 'partial image was not cleaned'
[[ ! -e "$WRAPPER_PATH" ]] || fail 'partial wrapper was not cleaned'
[[ ! -e "$INSTALL_INFO" ]] || fail 'partial install-info was not cleaned'
INSTALL_IMAGE_CREATED=0
INSTALL_WRAPPER_CREATED=0
INSTALL_INFO_CREATED=0
printf 'ok 6 - failed-install cleanup removes only created artifacts\n'

mkdir -p "$(dirname "$WRAPPER_PATH")" "$BOOTSTRAP_DIR/bin"
BUSYBOX_PATH=/usr/bin/busybox
write_boot_wrapper /usr/lib/systemd/systemd /usr/sbin/modprobe
/usr/bin/busybox sh -n "$WRAPPER_PATH"
assert_file_contains "$WRAPPER_PATH" 'exec /sbin/init "$@"'
assert_file_contains "$WRAPPER_PATH" 'exec "$ORIGINAL_INIT" "$@"'
printf 'ok 7 - generated init wrapper preserves init arguments\n'

assert_file_contains "$WRAPPER_PATH" 'for tree in /proc /sys /dev /run; do'
assert_file_contains "$WRAPPER_PATH" 'bb mount -o rbind "$src" "$dst"'
assert_file_contains "$WRAPPER_PATH" 'bb mount --make-rslave "$dst"'
assert_file_contains "$WRAPPER_PATH" 'bb mount -o rbind /mnt "$dst"'
assert_file_contains "$WRAPPER_PATH" 'bb mount --make-slave "$dst"'
assert_file_not_contains "$WRAPPER_PATH" 'bb mount --make-rslave "$NEWROOT/mnt"'
assert_file_not_contains "$WRAPPER_PATH" 'rbind_tree /mnt/wsl'
assert_file_not_contains "$WRAPPER_PATH" 'rbind_tree /mnt/wslg'
assert_file_not_contains "$WRAPPER_PATH" '/mnt/[a-zA-Z]'
printf 'ok 8 - /mnt is carried as a propagated tree, not a drive list\n'

assert_file_contains "$WRAPPER_PATH" 'rbind_tree_if_exists /usr/lib/wsl'
assert_file_contains "$WRAPPER_PATH" '[ -e "$1" ] || return 0'
assert_file_contains "$WRAPPER_PATH" "RUNTIME_MODULE_ROOT='/run/booted-system/kernel-modules'"
assert_file_contains "$WRAPPER_PATH" 'if [ -d "$runtime_modules" ]; then'
assert_file_contains "$WRAPPER_PATH" 'rbind_source_tree "$RUNTIME_MODULE_ROOT/lib/modules" /usr/lib/modules'
printf 'ok 9 - optional WSL runtime and kernel-module paths are feature-detected\n'

(
  root_fstype() { printf 'btrfs\n'; }
  require_root() { :; }
  is_wsl2() { return 0; }
  output=$(install_root 256G)
  [[ "$output" == *'already Btrfs'* ]] || exit 1
) || fail 'install on an already-active Btrfs root was not a safe no-op'
printf 'ok 10 - active Btrfs root is a safe no-op\n'

rm -f "$INIT_PATH" "$WRAPPER_PATH" "$IMAGE_PATH" "$INSTALL_INFO"
mkdir -p "$(dirname "$INIT_PATH")" "$(dirname "$WRAPPER_PATH")" "$BOOTSTRAP_DIR"
printf '#!/bin/sh\n' >"$WRAPPER_PATH"
chmod +x "$WRAPPER_PATH"
: >"$IMAGE_PATH"
ln -s "$WRAPPER_PATH" "$INIT_PATH"
if (prepare_existing_install 1 >/dev/null 2>&1); then
  fail '--force discarded an image while init still pointed at the wrapper'
fi
[[ -e "$IMAGE_PATH" ]] || fail '--force removed the protected image'
printf 'ok 11 - --force refuses a still-active init wrapper\n'

rm -f "$INIT_PATH" "$WRAPPER_PATH" "$IMAGE_PATH" "$INSTALL_INFO"
printf partial >"$IMAGE_PATH"
printf wrapper >"$WRAPPER_PATH"
printf prepared >"$INSTALL_INFO"
prepare_existing_install 1 >/dev/null
[[ ! -e "$IMAGE_PATH" && ! -e "$WRAPPER_PATH" && ! -e "$INSTALL_INFO" ]] \
  || fail '--force did not remove the known incomplete artifacts'
printf 'ok 12 - --force cleans only a detected incomplete setup\n'

rm -f "$INIT_PATH" "$INIT_BACKUP"
printf original >"$INIT_PATH"
chmod +x "$INIT_PATH"
backup_original_init
printf wrapper >"$INIT_PATH"
restore_original_init
assert_eq "$(cat "$INIT_PATH")" original
printf 'ok 13 - original init backup can be restored\n'
