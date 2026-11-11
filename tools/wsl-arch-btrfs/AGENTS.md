# Codex project instructions

Read `CODEX_TASK.md` first. This repository is an experimental WSL2 Debian/ext4 -> Arch Linux/Btrfs root switcher. Never assume that cloud Linux tests validate Windows WSL behavior.

## Safety and scope
- Scope changes to the `ArchBtrfs-*` **dedicated test distro** only. Do not alter or unregister the user's real Debian/Ubuntu/Arch distros, the global `.wslconfig`, existing `ext4.vhdx`, or physical disks.
- Default every mutating command to dry-run; require explicit `-Apply` / `--apply` and print targets, risk, rollback before changes. No irreversible conversion; keep original `arch.img` and logs/backups.
- Schedule the **mount-only** elevated Windows task; don't grant an arbitrary shell command or terminate/shutdown privileges to that scheduled task. No UAC prompts on each normal launch once securely registered.
- Do not silently use Debian as if it were Arch. Expose a clear fallback/error signal while retaining an explicit rescue path.
- Do not `wsl --shutdown` as part of the normal two-stage restart. Before `wsl --terminate <test-distro>`, check the WSL VM will retain access to the attached VHDX or implement a safe observed fallback. No termination of other distros.
- Verify Btrfs UUID, subvolume `@`, instance marker, and correct filesystem before pivot. Guard against malformed paths, race conditions and concurrent callers.
- Avoid running experimental destructive operations in this Codex sandbox. Static tests and mocks are fine here; Windows/WSL integration must be marked NOT TESTED when unavailable.
- Do not claim a test passed unless you actually executed it. Separate PASS / FAIL / NOT TESTED / NOT FEASIBLE.

## Engineering expectations
- Preserve original loopback mode and the ext4 Debian rescue path.
- Investigate timing: `/etc/fstab` precedes Windows interop; never synchronously call `wsl.exe` there. `schtasks.exe` runs only after interop is available.
- Make the normal user journey as close as possible to a single launch `wsl -d ArchBtrfs-Clean` or Windows Terminal profile; where vanilla `wsl` cannot reattach to a restarted distro, implement a clearly described alternative and explain the limitation.
- Test idempotency, cold start, already-mounted VHDX, missing VHDX, failure to elevate, timeout, two simultaneous launches, VM idle teardown, systemd, WSLg, `code .`, Windows interop and recovery. Avoid fragile timing-only sleeps.
- Implement only after reading current code and upstream Microsoft WSL docs/source. Prefer small, audited changes and record the exact changed files.
- Write a Japanese README, architecture notes, test matrix and verification log for any new workflow.
