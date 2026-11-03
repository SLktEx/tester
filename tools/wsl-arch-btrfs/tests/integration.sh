#!/bin/bash
# Opens one short-lived WSLg window and one VS Code WSL window.
set -euo pipefail
instance=$1
[[ $(id -un) == arch && $(cat /etc/archbtrfs-instance) == "$instance" ]]
[[ $(findmnt -nro FSTYPE,FSROOT /) == 'btrfs /@' ]]
[[ $(timeout 45 systemctl --user is-system-running --wait) == running ]]
tmp=$(mktemp -d)
timeout 15 wayland-info >"$tmp/wayland"
grep -q wl_compositor "$tmp/wayland"
timeout 10 pactl info >"$tmp/pulse"
grep -q PulseServer "$tmp/pulse"
xmessage -title "$WSL_DISTRO_NAME-integration" -timeout 8 'WSLg integration test' &
gui=$!
for _ in {1..15}; do
    if xwininfo -name "$WSL_DISTRO_NAME-integration" >"$tmp/window" 2>/dev/null; then break; fi
    sleep 0.4
done
grep 'Map State: IsViewable' "$tmp/window"
wait "$gui" || :
(cd /mnt/c && cmd.exe /d /c ver) >"$tmp/interop"
grep -a 'Microsoft Windows' "$tmp/interop"
mkdir -p "$HOME/archbtrfs-verification"
cd "$HOME/archbtrfs-verification"
timeout 300 code .
for _ in {1..90}; do
    for proc in /proc/[0-9]*; do
        case $(readlink "$proc/exe" 2>/dev/null || :) in
            "$HOME"/.vscode-server/*/node)
                if tr '\0' '\n' <"$proc/cmdline" | grep -Fx -- '--type=extensionHost' >/dev/null &&
                    [[ $(stat -Lc '%d:%i' "$proc/root") == "$(stat -Lc '%d:%i' /)" ]]; then
                    echo "Connected extension host on Arch root: ${proc##*/}"
                    exit 0
                fi ;;
        esac
    done
    sleep 1
done
echo 'No connected extension host with matching root' >&2
exit 1
