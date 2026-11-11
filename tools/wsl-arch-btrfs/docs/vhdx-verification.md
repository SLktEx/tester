# VHDX検証記録

記録日: 2026-11-11。**未完成 / Draft。新規Lab作成は承認済み。VHDX接続はUAC本人操作待ち。**
過去のloop方式の合格をVHDX方式の合格に転用しない。

承認後の[実機試行・失敗修正・変換成功の記録](vhdx-native-trials.md)を追加した。
最新の単体テストはBash 12件＋PowerShell 17件＝29件PASS、構文11ファイルPASS。
以下の当初マトリクスで未検証としたVHDX起動/連携/復旧は、まだ合格していない。

## Phaseの実施状況

| Phase | 状態 | 実施内容 |
|---|---|---|
| 調査・先行テスト | PASS（範囲限定） | ZIP指示・実装監査、公式資料/WSLソース、Windows read-only inventory、単体テスト |
| 専用Labで手動試行 | 一部PASS | 新規Labのloop基準測定、Debian救援修正、raw→VHDX変換成功。VHDX接続はUAC待ち |
| 成功手順のスクリプト化 | 一部実施 | 変換成功手順と救援修正を反映。完成版VHDX setup/launcherは未作成 |
| 別のClean環境で再現 | NOT TESTED | Lab成功前には作成しない |
| WSLg/systemd/interop/VS Code/snapshot | NOT TESTED（VHDX） | 合格を主張しない |

## 観察したホスト（read-only）

`wsl --version` は WSL 3.0.3.0、kernel 6.18.54.1-1、WSLg 1.0.79、Windows 10.0.26300.9818を報告した。
`wsl --list --verbose` で既存のloopテスト登録が稼働中だった。
対象外の停止・再起動・設定変更・VHDX操作・task登録は実行していない。
ホスト個別のパス、全登録名、GUID等は公開ログに含めない。

## テスト先行の記録

1. `tests/vhdx-state.Tests.ps1` を先に追加し実行:
   `RED: VHDX state machine is not implemented yet` で失敗した。
2. 純粋な状態機械を追加。偽taskの開始前状態のfixtureを修正し、14件がPASS。
3. Bashテストは最初sandbox内でMSYSの起動制限により実行不能だった。
   これは製品の成否ではない。通常Windows権限で**偽コマンドのみ**のテストを再実行した。
4. 添付版ではRequestのdry-runが実際にfake taskを実行した。
   Findのテストには候補device属性を差し込める境界も必要だった。
   明示apply、正確なUUID、loop重複拒否、lsblk失敗伝搬を修正後、Bash挙動10件がPASS。
5. 全shellの構文検査と追加のroot拒否テストを追加。runnerのバージョン表示pipeが
   SIGPIPEを生む問題を修正後、**Bash 11件＋PowerShell状態機械17件＝28件PASS**、
   PowerShell構文11ファイルPASS。最終ログは [logs/vhdx-unit-20261111.txt](logs/vhdx-unit-20261111.txt)。

## 受け入れマトリクス

| シナリオ | モック/構文 | Windows WSL実機 |
|---|---|---|
| 未接続 → task完了 → restart → Arch | PASS | NOT TESTED |
| 接続済み / Arch到達済みの冪等性 | PASS | NOT TESTED |
| task失敗、未完了、古い結果 | PASS | NOT TESTED |
| deviceが出ない / timeout / 昇格要求失敗 | PASS | NOT TESTED |
| UUID形式、重複、loop/partition拒否、lsblk失敗 | PASS | NOT TESTED |
| 再起動後1回の接続消失と再接続 | PASS | NOT TESTED |
| 接続消失継続の回数制限 / pivot失敗 | PASS | NOT TESTED |
| instance/UUID/PID1の判断 | PASS（偽データ） | NOT TESTED |
| task ACL/ユーザー/固定action、VHDX親dir保護 | NOT TESTED | NOT TESTED |
| 二つのWindows launcher、ロック衝突 | NOT TESTED | NOT TESTED |
| 全native callの期限、停止完了待ち | NOT TESTED | NOT TESTED |
| raw変換、qemu-img compare、hash前後 | 構文PASS | PASS（手動Lab。汎用スクリプト全適用は未検証） |
| 自然なVM idle / host reboot後 | NOT TESTED | NOT TESTED |
| 明示global shutdown | NOT TESTED | NOT FEASIBLE（既存環境を触らない今回の条件下） |
| 初期/新規session、管理者/通常token、UNC | NOT TESTED | NOT TESTED |
| systemd、WSLg GUI/音声、cmd.exe、code . | NOT TESTED | NOT TESTED |
| snapshot、復旧、loopへの復帰 | NOT TESTED | NOT TESTED |
| 独立Clean構築、再実行、中断復旧 | NOT TESTED | NOT TESTED |

## 再実行コマンド

リポジトリの `tools/wsl-arch-btrfs` で:

```powershell
.\tests\Invoke-VhdxUnitTests.ps1
```

Python 3とGit Bashが必要。WSLの `bash.exe` エイリアスは自動選択しない。
このテストはtask/VHDX/WSLを変更しない。Bashのdevice/blkid/taskは偽物。
PowerShellのTask/Root/Request/Terminateも偽物。

承認された専用Labの構築後に限り、次の診断を使用する（setupではない）:

```powershell
.\tests\vhdx-native.ps1 -Name ArchBtrfs-VhdxLab -Base C:\path\to\new-labs
# 対象表示を確認し、承認済みの場合だけ -Apply を追加
```

診断は登録GUID/パス/instanceを照合し、VHDX mode・root device・新規session・PID1・UNC・interopを検査する。
この診断スクリプト自体の実機動作もまだ未検証。GUI/IDE・復旧・task ACLは別試験が必要。

## 次の実験の必須証跡

コマンド全文とexit、task定義/ACL/今回の開始時刻・終了結果、block deviceとUUID、
各root/namespace/PID1、自然idle前後のVM boot ID、Windows token種別、WSLg窓/音声、
`code .`で接続したextensionHostのroot、snapshot内容差分、raw保全hash、Clean再実行ログ。
失敗も削除せず、修正→手動で再試行→スクリプト化→別Clean再検証の順番を守る。

## 2026-11-12 GitHub Actions実機試験（上の未検証表への追記）

[初回run](https://github.com/SLktEx/tester/actions/runs/43078869822)はFAIL。
未登録のWindows runnerで `wsl --list --verbose` が非zeroとなることを確認した。
登録前はレジストリinventoryで空を判定するよう修正。

[再試行run](https://github.com/SLktEx/tester/actions/runs/43079038923)はPASS。
Windows Server 2025 10.0.26100.33674、WSL 3.0.3.0、kernel 6.18.54.1-1、
WSLg 1.0.79。管理者token、GitHub-hosted runner。ユーザーのPCは操作していない。

- PASS: 新規loop版構築、Arch/systemd、初期・新規session、UNC、Debian救援。
- PASS: raw→VHDX実変換、qemu-img内容一致・raw hash保全、同じ変換の再実行。
- PASS: `wsl --mount ... --vhd --bare`、実disk `/dev/sde` のUUID/instance照合。
- PASS: 読取専用snapshot、書込可能cloneで内容復元（起動復旧とは別）。
- PASS: Debian interop→実際のmount-only task、今回のLastRunTime、結果0、device可視性。
- NOT TESTED（このrun）: VHDXからのroot起動、GUI/IDE、production ACL、通常token、完全Clean構築。

次のroot pivot試験は [`actions-native.md`](actions-native.md) の手順を使う。
実験fixtureと汎用setupの完成を混同しない。
