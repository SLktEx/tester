#!/bin/bash
# Offline recursive snapshots. Derived from the recorded native Lab trial.
# No delete/format operation; old roots and incomplete work remain recoverable.
set -euo pipefail
export LC_ALL=C
action=${1:?snapshot or restore}; label=${2:?}; instance=${3:?}
[[ $action == snapshot || $action == restore ]]
[[ $label =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]
[[ $instance =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]]
echo "Target: instance $instance; offline $action bundle $label; risk: root rollback; old root retained"
[[ ${4:-} == --apply ]] || { echo 'DRY RUN'; exit 0; }
die() { echo "REFUSED: $*; keep activation disabled and inspect retained work" >&2; exit 2; }
[[ $EUID == 0 && ${WSL_DISTRO_NAME:-} =~ ^ArchBtrfs-[A-Za-z0-9-]+$ ]]
[[ $(findmnt -nro FSTYPE /) == ext4 ]] || die 'Debian rescue required'
d=/var/lib/archbtrfs
[[ $(cat "$d/instance") == "$instance" && $(cat "$d/name") == "$WSL_DISTRO_NAME" && -f $d/vhdx-mode ]]
[[ ! -e $(cat "$d/marker") ]] || die 'disable activation before recovery'
exec 9>"$d/setup.lock"; flock -n 9 || die 'another guest operation holds lock'
[[ -z $(losetup -j "$d/arch.img") && -z $(findmnt -rn -t btrfs) ]] || die 'filesystem must be offline'
uuid=$(cat "$d/uuid")
device=$(bash "$d/Find-ArchVhdxDevice.sh" "$uuid")
top=$(mktemp -d /run/archbtrfs-bundle.XXXXXX)
cleanup() { local rc=$?; trap - EXIT; if mountpoint -q "$top"; then umount "$top" || exit 3; fi; rmdir "$top"; exit "$rc"; }
trap cleanup EXIT
mount -t btrfs -o subvolid=5 "$device" "$top"
[[ $(findmnt -nro UUID -T "$top") == "$uuid" ]]
[[ -d $top/@snapshots && ! -L $top/@snapshots ]]
bundle=$top/@snapshots/bundle-$label
partial=$top/@snapshots/partial-$label
pending=$top/@restore-$label
previous=$top/@before-restore-$label
journal=$d/restore-$label.ids
subid() { [[ -d $1 && ! -L $1 && $(stat -c %i "$1") == 256 ]] || return 2; btrfs inspect-internal rootid "$1"; }
subuuid() { btrfs subvolume show "$1" | awk '$1=="UUID:" {print $2}'; }
parentuuid() { btrfs subvolume show "$1" | awk '$1=="Parent" && $2=="UUID:" {print $3}'; }
safe_relative() {
    [[ $1 != /* && $1 != *'/../'* && $1 != '../'* && $1 != */.. && $1 != .. && $1 != *'/./'* && $1 != './'* && $1 != */. && $1 != *'//'* && -n $1 ]]
}
declare -a records=()
validate_bundle() {
    [[ -d $bundle && ! -L $bundle && -f $bundle/manifest && ! -L $bundle/manifest && -f $bundle/complete ]] || die 'incomplete bundle'
    mapfile -d '' -t records < "$bundle/manifest"
    (( ${#records[@]} >= 3 && ${#records[@]} % 3 == 0 )) || die 'invalid manifest'
    declare -A seen=()
    local n index rel expected
    for ((n=0;n<${#records[@]};n+=3)); do
        index=${records[n]}; rel=${records[n+1]}; expected=${records[n+2]}
        [[ $index == "$((n/3))" ]] || die 'invalid index'
        safe_relative "$rel" || die 'unsafe relative path'
        [[ -z ${seen["$rel"]:-} ]] || die 'duplicate path'
        seen["$rel"]=1
        if ((n==0)); then [[ $rel == . ]] || die 'missing root'; else [[ $rel != . ]] || die 'duplicate root'; fi
        subid "$bundle/$index" >/dev/null
        [[ $(subuuid "$bundle/$index") == "$expected" && $(btrfs property get "$bundle/$index" ro) == ro=true ]] || die 'snapshot identity or RO mismatch'
    done
    [[ $(cat "$bundle/0/etc/archbtrfs-instance") == "$instance" ]]
}
validate_clone() {
    local root=$1 n rel index path
    [[ $(cat "$root/etc/archbtrfs-instance") == "$instance" ]]
    for ((n=0;n<${#records[@]};n+=3)); do
        index=${records[n]}; rel=${records[n+1]}; path=$root/$rel
        if [[ $rel != . ]]; then [[ $(realpath -e "$path") == "$root/$rel" ]] || die 'clone path redirected'; fi
        subid "$path" >/dev/null
        [[ $(parentuuid "$path") == "${records[n+2]}" && $(btrfs property get "$path" ro) == ro=false ]] || die 'clone provenance mismatch'
    done
}
if [[ $action == snapshot ]]; then
    if [[ -e $bundle ]]; then validate_bundle; echo 'PASS existing immutable bundle'; exit 0; fi
    [[ ! -e $partial && ! -L $partial ]] || die 'partial snapshot retained; choose a new label after inspection'
    [[ $(cat "$top/@/etc/archbtrfs-instance") == "$instance" ]]
    subid "$top/@" >/dev/null
    # NUL-delimited paths avoid parsing the human-readable btrfs list output.
    # find -xdev sees each nested subvolume boundary, then we visit it separately.
    declare -a paths=(.)
    declare -A seen_ids=()
    inventory=$(mktemp "$d/bundle-inventory.XXXXXX")
    for ((i=0;i<${#paths[@]};i++)); do
        source=$top/@/${paths[i]}
        id=$(subid "$source")
        [[ -z ${seen_ids[$id]:-} ]] || die 'duplicate source subvolume'
        seen_ids[$id]=1
        find "$source" -xdev -mindepth 1 -type d -inum 256 -print0 > "$inventory"
        while IFS= read -r -d '' child; do
            child=$(realpath -e "$child")
            [[ $child == "$top/@/"* ]] || die 'source escaped root'
            rel=${child#"$top/@/"}; safe_relative "$rel" || die 'invalid child'
            paths+=("$rel")
        done < "$inventory"
    done
    # Only this exclusively-created temporary ordinary file is removed.
    rm -- "$inventory"
    mkdir "$partial"
    for ((i=0;i<${#paths[@]};i++)); do
        btrfs subvolume snapshot -r "$top/@/${paths[i]}" "$partial/$i"
        printf '%s\0%s\0%s\0' "$i" "${paths[i]}" "$(subuuid "$partial/$i")" >> "$partial/manifest"
    done
    printf '%s\n' "$instance" > "$partial/complete"
    sync
    mv -T "$partial" "$bundle"
    sync
    validate_bundle
    echo 'PASS offline recursive bundle saved'
    exit 0
fi
validate_bundle
[[ ! -L $journal ]] || die 'journal symlink rejected'
if [[ ! -e $journal ]]; then
    [[ ! -e $previous && ! -L $previous ]] || die 'previous root without journal'
    oldid=$(subid "$top/@")
    [[ $(cat "$top/@/etc/archbtrfs-instance") == "$instance" ]]
    [[ ! -e $pending && ! -L $pending ]] || die 'uncommitted clone retained; inspect before retry'
    btrfs subvolume snapshot "$bundle/0" "$pending"
    for ((n=3;n<${#records[@]};n+=3)); do
        index=${records[n]}; rel=${records[n+1]}
        [[ $(realpath -e "$pending/$rel") == "$pending/$rel" ]] || die 'placeholder path redirected'
        rmdir -- "$pending/$rel" # Only an empty placeholder; never recursive delete.
        btrfs subvolume snapshot "$bundle/$index" "$pending/$rel"
    done
    validate_clone "$pending"
    newid=$(subid "$pending")
    [[ ! -e $journal.tmp && ! -L $journal.tmp ]] || die 'journal temporary collision'
    (set -C; printf '%s\n' "$oldid" "$newid" "${records[2]}" > "$journal.tmp")
    sync
    mv -T "$journal.tmp" "$journal"
    sync
fi
[[ -f $journal && ! -L $journal ]]
mapfile -t ids < "$journal"
[[ ${#ids[@]} == 3 && ${ids[0]} =~ ^[0-9]+$ && ${ids[1]} =~ ^[0-9]+$ && ${ids[0]} != "${ids[1]}" && ${ids[2]} == "${records[2]}" ]] || die 'journal identity mismatch'
if [[ -e $top/@ ]]; then
    active=$(subid "$top/@")
    if [[ $active == "${ids[1]}" ]]; then
        [[ ! -e $pending && $(subid "$previous") == "${ids[0]}" ]] || die 'committed state inconsistent'
        validate_clone "$top/@"
        echo 'PASS restore already committed; old root retained'
        exit 0
    fi
    [[ $active == "${ids[0]}" && ! -e $previous && ! -L $previous ]] || die 'active root changed'
    [[ $(subid "$pending") == "${ids[1]}" ]]
    validate_clone "$pending"
    mv -T "$top/@" "$previous"
    sync
    if [[ ${ARCHBTRFS_TEST_STOP:-} == after-old-rename ]]; then echo 'INJECTED STOP; Debian rescue retained'; exit 75; fi
fi
[[ ! -e $top/@ && ! -L $top/@ && $(subid "$previous") == "${ids[0]}" && $(subid "$pending") == "${ids[1]}" ]] || die 'resume state inconsistent'
validate_clone "$pending"
mv -T "$pending" "$top/@"
sync
echo 'PASS restore committed; previous root and nested subvolumes retained'
