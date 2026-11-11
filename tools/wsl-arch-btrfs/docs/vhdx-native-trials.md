# 実機試行記録 — Lab作成と変換

2026-11-11（JST）。ユーザーの承認後に **新規 `ArchBtrfs-VhdxLab` のみ**を作成した。
既存の登録・VHDX・グローバル設定は変更していない。Cleanはまだ作成していない。
この記録はVHDX起動完成を意味しない。

## 実行した順番と結果

| 試行 | 結果 | 観測と処置 |
|---|---|---|
| 新規Labのraw/loop構築 | PASS | 固定hashのDebian/Arch rootfs・署名付きパッケージで構築。8 GiBの新規通常ファイルだけをmkfs |
| 新規session・PID1・UNC | PASS（loop） | Arch、glibc 2.44、Btrfs `/@`、systemd、初期rootと新規rootの一致 |
| WSLg・interop・VS Code | PASS（loop） | X11窓IsViewable、Wayland compositor、PulseServer、cmd.exe、code .のextensionHostがArch rootと一致 |
| marker退避→対象だけterminate→Debian | FAIL（systemd） | rootはext4だがmaintenance。`archbtrfs\x2dhook.mount`失敗でlocal-fs.targetが依存失敗 |
| fstab依存関係の修正と対象再起動 | PASS | helper行へ`x-systemd.wanted-by=archbtrfs-manual.target`を追加。Debianでrunning、failed units 0 |
| 変換前のread-only検査・試行1 | FAIL（mount） | kernelが単独`nologreplay`を拒否。出力VHDXはまだ未作成。原本hash一致とloop解放を確認 |
| read-only検査・試行2 | PASS | `ro,rescue=nologreplay,subvolid=5`で`@`・`@snapshots`・instance・systemd実体を確認 |
| raw→新規dynamic VHDX | PASS（手動） | qemu-img 10.0.13。virtual size 8 GiB、初期実ファイル約2 GiB。format=vhdx |
| 内容一致と原本保全 | PASS | `qemu-img compare`が`Images are identical.`。変換前後とRO検査後のSHA-256一致 |
| 再利用可能な変換スクリプト | PARTIAL | 成功コマンドから作成。構文・実機dry-runはPASS。全適用・再実行・Clean再現はまだNOT TESTED |
| 手動VHDX接続 | PENDING | 対象とhashを固定した単発helperをUACで要求。記録時点ではUACの本人操作待ち |
| 昇格mount-only task | NOT TESTED | 親dir置換を防ぐProgramDataの専用保管先について追加承認待ち。登録していない |

`PARTIAL`/`PENDING`はいずれも受け入れテストのPASSには数えない。

## 試行で得た修正

### 救援起動でもsystemdを正常にする

従来のfstab hookはWSLの初期化時に実行されるが、markerを外したDebian起動では
systemd-fstab-generatorも同じ行からmount unitを作る。helperは通常のfilesystemを
`/archbtrfs-hook`へmountしないので、systemd側の再実行が失敗しlocal-fs.targetを止めていた。
rootユーザーのWSL session timeout警告も同時に発生した。

バックアップ後、Labの行を次に変更して対象だけ再起動した:

```fstab
none /archbtrfs-hook archbtrfs defaults,x-systemd.wanted-by=archbtrfs-manual.target 0 0
```

このtargetは自動起動しない。WSLのmount -aでのearly hookは保持し、systemdの通常の
local-fs依存関係から外す。[systemd.mountの仕様](https://www.freedesktop.org/software/systemd/man/257/systemd.mount.html)
を確認してから試行した。結果は`running`、failed units 0。成功後に`prepare.sh`へ反映し、
読み取り専用の`tests/rescue.sh`でも同じLabを検証した。新規Cleanでの再現は未実施。

### 読み取り専用検査でログを再生しない

最初の試行は`ro,nologreplay`で失敗した。
[Btrfs公式変更履歴](https://btrfs.readthedocs.io/en/latest/Feature-by-version.html)によると
単独のnologreplayはkernel 6.16で削除され、`rescue=nologreplay`へ置換されている。
試行1のフォルダーとログを保留し、別の新規フォルダーで再試行した。

実行した主要コマンド（保存先だけ汎用表記）:

```bash
sha256sum /var/lib/archbtrfs/arch.img > "$output/source.sha256"
mount -o loop,ro,rescue=nologreplay,subvolid=5 /var/lib/archbtrfs/arch.img "$verify"
cmp /var/lib/archbtrfs/instance "$verify/@/etc/archbtrfs-instance"
btrfs subvolume show "$verify/@"
btrfs subvolume show "$verify/@snapshots"
umount "$verify"
# losetup -j が空になるまで有限待機してから
qemu-img convert -f raw -O vhdx -o subformat=dynamic /var/lib/archbtrfs/arch.img "$output/arch-data.vhdx"
qemu-img compare -f raw -F vhdx /var/lib/archbtrfs/arch.img "$output/arch-data.vhdx"
sha256sum -c "$output/source.sha256"
```

成功したこの順序から`Convert-ArchImg-ToVhdx.sh`を作成した。
新規出力dirを排他的に作成し、不完全な出力は上書きしない。同一UUIDの接続deviceが存在すると拒否する。
VHDXを起動設定へ有効化したり、task登録・attach・mkfsを行う処理は含まない。

## 現在の復旧状態と残作業

Labの有効化markerは退避済みで、Debian/ext4 rescue、systemd running。
原本arch.img、preboot export、設定backup、試行1の失敗ログ、試行2のVHDXとhashを保持する。
UACが承認された場合も、この単発helperは新規VHDXをbare attachするだけでpivotや再起動はしない。

次はattachの実結果・唯一のdevice・UUID・subvolumeを確認し、early pivotを手動検証する。
その後にtask/launcher、snapshot/復旧、並行・失敗試験を行い、別Cleanで再現する。
現時点でVHDX版のsystemd/WSLg/VS Code/snapshot互換性を合格とはしない。

公開用の[ログ抜粋](logs/vhdx-lab-native-excerpts.txt)と[単体テストログ](logs/vhdx-unit-native-followup.txt)を保存した。
元ログと試行コマンドはローカルlabフォルダーに保持し、個別ホスト名・パスを公開しない。
この実行ホストのPowerShell transcriptにはnative stdoutが欠落することも判明した。
変換はゲスト側teeログを回収し、救援診断はnative出力を明示保存した。
基準測定の一部はツール出力からの転記と明記している。以降のsetup/recoveryは
`host.ps1`でnative stdout・コマンド・終了コードを別ログへ明示保存する。
