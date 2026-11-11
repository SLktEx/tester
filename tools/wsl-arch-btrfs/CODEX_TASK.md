# Codex依頼: WSL2 Arch/Btrfs VHDX 2段階右折方式を完成させる

## 目的
既存の `wsl-arch-btrfs` (Debian/ext4 の early `/etc/fstab` → `mount.archbtrfs` → `pivot_root` → Arch/Btrfs) を VHDX方式にも対応させる。元の raw `arch.img` + loopback 方式は維持する。ユーザーが実現したいのは、通常利用で Arch Linux の `/` そのものがBtrfsであり、WSL/WSLg、Windows interop、VS Code、systemd を引き継げること。

## 合意した設計（2段階右折）
1. WSLのcold startでArch用Btrfs VHDXが未接続なら、早期 `/etc/fstab` ではArchへのpivotを試みず、救援用Debianで起動し、interopの初期化を待つ。
2. Debianから `schtasks.exe /Run` でWindowsの登録済み昇格タスクを呼ぶ。そのタスクがすることは **`wsl.exe --mount <専用VHDX> --vhd --bare` のみ**。初回登録は明示的管理者操作とし、通常起動のたびにUACを要求しない。
3. タスクの依頼だけでは成功扱いしない。タスク終了コード/状態とWSL内の想定Btrfs UUID、device type、mount状態を確認する。
4. 接続済みを確認してから**対象のテスト用distroだけ**を停止し、Windows側のオーケストレーターが再度起動する。WSL2 VMがアイドル停止すると追加VHDX接続が失われる懸念を実験で検証し、安全な維持・再接続・復旧方法を実装。
5. 2回目の `/etc/fstab` は既存の `mount.archbtrfs` を実行し、UUIDでVHDXを識別、Btrfs `@` をマウントし `pivot_root` してArchへ入る。
6. 常用コマンドを `wsl -d ArchBtrfs-Clean` のままにできるかをまず検証。原理的に同じターミナルへの自動再接続が不可能なら、Windows Terminalのプロファイル用起動スクリプトなど**最小の操作変更**で成立させ、制約を正確に説明する。

## 既存実装
- `docs/vhdx-two-stage.md` が現状の未実機検証設計。
- `scripts/Register-MountTask.ps1` などのタスク登録・起動・監視用の実験スクリプトがある。
- `scripts/mount.archbtrfs` と `scripts/Find-ArchVhdxDevice.sh` が接続済みVHDXへの切り替え処理。
- `scripts/Start-TwoStage.ps1` はWindows側から起動/接続要求/停止/再起動する実験版。
- 元の早期 `pivot_root`、`/etc/wsl.conf` bind共有、WSL環境継承ロジックを壊さない。

## まずやること
- 現行の全スクリプトを批判的にレビューして、タイミング・起動レース・セキュリティ/権限・VM寿命・誤ったdistro識別・パス検証・ログインフック依存・失敗時フォールバックの欠陥を列挙。Windowsの `schtasks /Run` と実タスク終了の相違、WSL実行環境でのinteropの条件もチェック。
- Microsoftの現在の仕様（WSL `wsl --mount --vhd --bare`, `wsl --terminate`, `--shutdown`, interop、スケジュールタスクの最高権限実行）を一次資料で確認。
- 仮説は複数候補を広く比較してから採用理由を明示。必要ならOS依存部分をテスト用の注入可能インターフェースに分離する。
- 承認前にユーザーのWindows/WSL実環境へ操作をしない。Codex Cloud上のLinuxだけではWindows/WSL実機検証不能なので必ず未検証扱いにする。

## 要求実装
- Windowsの**接続専用**タスク: 明示的登録・確認・削除、同名競合回避、権限/ACLの最小化、タスク引数の安全性、終了待ちと失敗報告。
- 初回Debian起動の管理: 冪等、同時複数起動時の排他、待ち時間の上限、マウント成功確認、ログ。ターミナルやVS Code等の挙動を説明。
- 再起動: `wsl --terminate <対象のテストdistro>` のみ。再起動時にVHDXが切れていた場合の再接続は無限ループせず、Debian救援環境へ戻れる設計。
- 変換: 既存Btrfs rawイメージから**新しい**VHDXへ、入力破壊なし・ハッシュ/UUID/サブボリューム確認・失敗時の原本保存。未作成VHDXの初期化と既存ext4.vhdxの誤操作を拒否。
- Archの `@` Btrfs root とPID1、systemd、Windowsから作る追加WSLセッション、WSLg、Windows DrvFs、`code .`、Btrfs snapshotsの動作を検証。
- docsとscriptの使用例を整合させる。`README.md`から本手順へ誘導。

## 受け入れテスト
| シナリオ | 期待 |
|---|---|
| Cold start / VHDX未接続 | 1回目Debian → 接続タスク → 状態確認 → 安全な2回目起動でArch/Btrfs |
| VHDX接続済み | 1回の起動でArch/Btrfs、二重マウントしない |
| `wsl --terminate` の後 | VM維持または安全な再接続によってArch到達、または検知して停止 |
| VM全停止の後 | 明確なリカバリと無限ループ防止 |
| 並行起動 | VHDXに重複書込や起動レースがない |
| Windows昇格タスクが失敗 | 誤成功と見なさず、Debian救援とログを残す |
| `arch.img`方式 | 既存の利用と復旧が継続できる |
| 初期化済みセッションと新規セッション | Arch/Btrfs root のUUIDが一致。単なるchroot成功を合格にしない |
| Windows連携 / GUI / IDE | `cmd.exe`, WSLg, `code .`, systemdを検証 |
| 起動中断・復旧 | 原本保全、テスト専用環境のみ変更、手順明瞭 |

## 必須の成果物
- 実装・テスト・文書をリポジトリにコミット。可能であればPRを開く。既存環境の変更はしない。
- テスト実行ログ付き `docs/vhdx-verification.md`（PASS/FAIL/NOT TESTED/NOT FEASIBLEを明記）。
- 改訂版 `docs/vhdx-two-stage.md` と簡単な移行/復旧手順。
- 過去のloopback方式との差分、既知の制約、残る手動操作、実機での検証チェックリストを報告。
- Windows実機が使えない環境では**完了宣言をしない**。可能な自動/モック/構文テストを実施し、実機用テストスクリプトを納品する。

## 終了時の報告（日本語）
1. 何を変更したか（主要ファイル）、2. テスト結果、3. 未検証・実機で必要な作業、4. 既存環境を守るための復旧手順、5. 最小の次の一手。
