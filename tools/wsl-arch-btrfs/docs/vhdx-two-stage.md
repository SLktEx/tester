# VHDX 2段階起動 — 調査と検証前の設計

**状態: 未完成。新規Labで手動変換・救援修正まで成功。VHDX起動・クリーン再現は未実施。**
従来の `setup.ps1` は raw/loop 専用のまま。VHDXの完成版セットアップとして使わない。
ZIP内の未検証の登録・起動スクリプトを完成品として追加していない。
変換は[実機試行](vhdx-native-trials.md)で成功した順序をスクリプト化したが、汎用版の全適用・再現は未検証。
起動の手動実験が成功してからWindowsアダプターを確定する。

## 調べた実装と事実

2026-11-11 に Microsoft/WSL の最新HEAD
`6e43d804cc1571079283df80f4cdd27608e611da` と、導入済み3.0.3のタグ
`15ea3b3846c5f18318722d1381186b2ff6ed72eb` を確認した。
最新ソースと実行バイナリーは同一ではない。

* [`config.cpp`](https://github.com/microsoft/WSL/blob/6e43d804cc1571079283df80f4cdd27608e611da/src/linux/init/config.cpp#L747)
  は `ConfigMountFsTab` 後に `ConfigInitializeVmMode` を呼ぶ。
  `ConfigMountFsTab` のコメントは、この時点でinteropサーバーが未起動と明記する。
  fstab失敗は起動全体の致命エラーではない。従って失敗後のext4をArch成功と扱えない。
* [`init.cpp`](https://github.com/microsoft/WSL/blob/6e43d804cc1571079283df80f4cdd27608e611da/src/linux/init/init.cpp#L2365)
  は `boot.systemd` に応じてPID1のdistro initを起動し、親側でinitをexecする。
  `/sbin/init`だけを替える方式では、既に作られた別プロセスのroot参照は書き換わらない。
* [`plan9.cpp`](https://github.com/microsoft/WSL/blob/6e43d804cc1571079283df80f4cdd27608e611da/src/linux/init/plan9.cpp#L208)
  は `/` を開いたFDを共有に渡す。UNC/VS Code検証ではLinuxの現在のシェルだけでなく
  この共有とWindowsからの新規セッションを測定する必要がある。
* 最新版の [`_VmIdleTerminate`](https://github.com/microsoft/WSL/blob/6e43d804cc1571079283df80f4cdd27608e611da/src/windows/service/exe/LxssUserSession.cpp#L4226)
  は停止前に `SaveAttachedDisksState()` を呼ぶ。`_LoadDiskMounts()` は保存情報を再読込する。
  同じ処理は[3.0.3](https://github.com/microsoft/WSL/blob/15ea3b3846c5f18318722d1381186b2ff6ed72eb/src/windows/service/exe/LxssUserSession.cpp#L4006)
  にも存在する。明示的shutdownの経路は保存ディスク情報を消去する。
  **「アイドル停止で必ず接続が失われる」も「常に保持される」も実験なしには断定しない。**
* [`SaveDiskState`](https://github.com/microsoft/WSL/blob/6e43d804cc1571079283df80f4cdd27608e611da/src/windows/service/exe/WslCoreVm.cpp#L2215)
  のレジストリはvolatile。ホスト再起動、明示shutdown、自然なidleは別シナリオとして扱う。

[公式ディスク接続仕様](https://learn.microsoft.com/en-us/windows/wsl/wsl2-mount-disk)では接続に管理者権限が必要。
[`schtasks /Run`](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks-run)
は実行要求であり、完了待ちAPIではない。
[interop仕様](https://wsl.dev/technical-documentation/interop/)と、
[タスクのセキュリティ記述子](https://learn.microsoft.com/en-us/windows/win32/taskschd/registeredtask-setsecuritydescriptor)
も参照した。

## 添付実装の監査結果

| 対象 | 発見事項 | 今回の扱い |
|---|---|---|
| `Start-TwoStage.ps1` | task要求後にdeviceだけを見る。古い成功・task失敗を区別しない | 完了・世代・deviceを同時に要求する状態機械とテストを追加 |
| 同上 | BtrfsならUUID/instance/PID1未確認で成功。停止後未確認 | 全属性を検査し、再起動後も同じ検査を繰り返すテスト |
| 同上 | 全probe失敗を未接続として再試行 | `absent` と異常を分離。重複・I/O失敗は即停止 |
| 同上 | 登録GUID/パス照合、排他、native呼出しtimeoutがない | Windowsアダプターの実験前必須条件として残す |
| `Find-ArchVhdxDevice.sh` | UUID形式が緩い。loop重複を無視。lsblk失敗が消える | strict UUID、全device走査、inventory失敗伝搬を実装・モック検証 |
| `Probe-ArchDisk.sh` | 最初の一致だけを返し、重複検出しない | 独立実装を採用せず、確定後Findへ一本化 |
| `Request-Mount.sh` | デフォルトでtask実行 | `--apply`必須、対象・影響・復旧表示を実装・検証 |
| `archvhdx-login.sh` | login以外/VS Codeで実行されず、UIDごとに競合 | 自動副作用のあるlogin hookは不採用。説明表示だけにする予定 |
| `mount.archbtrfs` | `/run`の通知dirが1777。失敗後の部分mountを残し得る | root所有0755と失敗時巻き戻しを実機で確認するまで置換しない |
| `Register-MountTask.ps1` | Replaceが既存taskを上書き。ACL/保護されたVHDXの検査なし | 置換禁止、完全一致時のみno-op、固定action/ACL検証が必要 |
| `Check-MountTask.ps1` | 未実行・実行中でも正常終了 | 状態報告と今回の実行成功判定を分離する |
| `Remove-MountTask.ps1` | 名前だけで削除し、対象actionの一致を確認しない | 所有instanceとactionを照合してから削除する必要 |
| `New-TestVhdx.ps1` | path競合・reparse/race・diskpart出力検査が不足 | 空ディスク作成/mkfs経路は採用しない。rawのコピー変換を検証する |
| `Convert-ArchImg-ToVhdx.sh` | 排他、hash前後、compare、原本subvolume検査不足 | 原本保存・検証・失敗artifact保留の手動実験を先に行う |
| `Enable-VhdxMode.sh` | dry-runでもmkdir/mount。再実行で失敗 | dry-runは一切mountしない。mode変更を最後のatomic操作にする |
| `Install-VhdxSupport.sh` | 有効時の再実行不可、helper更新が非atomic | backup・hash・atomic install・中断復旧が必要 |
| 従来snapshot/recovery | 常にarch.imgをloop mountする | VHDX有効時には原本を絶対に接続しない変更が必要。現状はVHDXに流用禁止 |

## 比較と暫定採用

| 案 | 利点 | 問題/判断 |
|---|---|---|
| fstabからWindowsを呼ぶ | 入口が少ない | interop未初期化なので不採用 |
| `/sbin/init` wrapperだけでpivot | systemd近辺に集約 | Plan9のrootやWSL sessionの参照を修正できる保証がなく不採用 |
| login hookが停止して再起動 | bashログインで自動化しやすい | 自分のrelay/terminalを失う。非login IDEにも対応しないため不採用 |
| keeper distro / system distroでkeepalive | VM寿命を延ばせる可能性 | 管理対象・副作用が増える。今回未採用 |
| Windows launcher＋有限再接続 | consoleを保持し、全結果を検証できる | 初回は専用launcherが必要。**手動実験の第一候補** |

自然idleではWSLの保存復元も観察する。keeperやグローバル`.wslconfig`変更を前提にしない。
単なる `wsl -d NAME` はディスク接続済みならearly pivotを期待できるが、
未接続で起動した同一クライアントがterminate後に再接続する仕様は確認できていない。
ここは未検証として扱い、Windows Terminalでlauncherを指定する案を用意する。

## 状態機械（OSアダプター未接続）

`scripts/Vhdx-State.ps1` は外部操作を注入する純粋な制御部。
通常の `wsl.exe`、タスク登録、ディスク操作を呼ばず、インストールもしない。

1. 登録identity検査 → rootを取得。
2. ArchならUUID・instance・`/@`・PID1検査。一致時のみ成功。
3. Debianなら明示的なrescueとして報告し、modeとidentity検査。
4. disk absent時だけ接続を要求。現在のtask世代・終了状態・exit 0・deviceを待つ。
5. identity/deviceを再検査して対象のみ停止。
6. 二度目の起動結果を検査。接続消失時だけ再試行。停止は最大2回。
   diskがあるのにpivotしなかった場合やその他のエラーはrescueで停止する。

Windowsアダプターは、準備・復旧と共通のファイルロック、native processのtimeout、
task action/principal/ACL検査、文字列ではなく引数配列、transcript、登録GUID/パス照合を持つ必要がある。
モックの `Verify` が実際にこれを保証するという意味ではない。

## 昇格taskの設計上の追加条件

actionは固定のSystem32 `wsl.exe --mount <専用VHDX> --vhd --bare` 一つだけ。
triggerなし、同時実行IgnoreNew、実行上限あり。同じWindowsユーザーのInteractiveToken/Highestを使い、
SYSTEMユーザーの別WSL登録を触らない。通常ユーザーにはtaskのread/runだけを許し、定義変更を許さない。
同名taskが一部でも異なる場合は上書きせず停止する。

VHDXの末端fileだけにACLを付けても、ユーザーが祖先dirをrename/置換できれば固定pathの保護にならない。
管理者所有の新規専用store（例 `%ProgramData%\ArchBtrfs-Vhdx\<instance>\arch-data.vhdx`）への
コピーと、その親を含むACLの検証が必要。**これは追加の承認対象。まだ作成していない。**
source rawと変換結果は元の新規labに保存し、可逆性を保つ。

## 手動検証の順番・移行・復旧

これは実施予定であり、成功した導入手順ではない。

1. 新規Labだけを承認後に作る。既存登録の複製や既存VHDXの操作をしない。
   registration/instance、rootfs配布物hash、設定backup、コマンドと結果を記録する。
2. まず既存のloop構成で動作確認。markerを退避し、対象だけ停止してDebian rescueへ。
3. rawを未接続にする。hash・UUID・`@`・instance・snapshotを検査。
   新規VHDXへqemu-img変換しcompare・hash前後を確認。途中生成物は再利用せず保留する。
4. 接続taskを専用に登録し、通常tokenからDebianのinteropで実行依頼。
   taskの実終了、唯一のwhole disk、Btrfs UUIDとsubvolume/instanceを確認する。
5. 早期helperをbackupして実験。部分失敗のunmount、ext4 rescue、接続なしを先に試す。
6. 対象のみ停止・再起動してArchを確認。新規session、UNC、PID1、WSLg、`code .`を測定。
7. target restart、task失敗、timeout、並行launcher、snapshot/restoreを試す。
   他のdistroが稼働中ならVM全停止・idle試験は**NOT TESTED**。他を止めない。
8. 成功コマンドをスクリプトへ反映してから別の新規Cleanで無人構築、再実行、中断再開を測定。

復旧時はWindowsの対象enable markerを退避→対象だけ停止→ext4 rescueを確認する。
VHDX用snapshot/restore完成前に従来loop用snapshotコマンドを流用しない。
元のloopへ戻す場合、まずVHDXを明示的にdetachし、同じUUIDのblock deviceが消えたことを確認してから
modeを戻す。rawは**移行時点のコピー**なので、VHDX上の後続変更が失われることを説明・承認する。
不明なディスク、同名task、部分生成物、既存ext4.vhdxは削除/formatしない。

実際の実行状況は [vhdx-verification.md](vhdx-verification.md) を参照。
