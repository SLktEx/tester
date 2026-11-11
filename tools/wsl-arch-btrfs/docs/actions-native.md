# GitHub ActionsでのWindows/WSL2実験

`arch-vhdx-native.yml` は `windows-2025` のGitHubホスト型ランナーに
新しい `ArchBtrfs-Actions-<run>-<attempt>` だけを作る実機実験。
ローカルPC/self-hosted runnerでの実行はガードで拒否する。
ユーザーのPCのUACや登録・ディスク・グローバル設定は操作しない。

[GitHubの仕様](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)では
Windowsランナーは管理者で動作し、UACは無効に設定されている。
テスト自身はUAC設定を変更しない。ランナー上で管理者トークンとWSLのバージョンを実測する。

## 試験範囲

1. 固定hashのDebian/Arch配布物から、既存のloop版setupを実行。
2. Archのroot/PID1・新規session・UNCを検査し、対象だけDebian救援へ戻す。
3. 実際のqemu-img変換と再実行を検査。原本hash・内容一致を確認する。
4. Windowsから新規VHDXをbare attachし、唯一のBtrfs device・UUID・instanceを検査。
5. VHDX上の読み取り専用snapshotと書込み可能cloneを作り、内容を検査。
   これはroot切替後の起動復旧とは別の試験。
6. 対象VHDXだけdetachし、Debian interopから実際のmount-only taskを依頼。
   今回のtask開始時刻・終了状態・結果・deviceを確認する。
7. CI専用のearly pivot fixtureをバックアップ後に配置。未接続時Debian救援を確認し、
   taskで接続→対象だけ再起動→VHDX上のArch rootを検査する。
   UUID/device・PID1・systemd・wsl.conf bind共有・cmd.exe・新規session・UNC・再起動を検査。
8. Windowsのenable markerを無効化してDebian救援に戻し、対象VHDXをdetach。
   raw原本hashが変わっていないことを検査する。

`tests/fixtures/mount.archbtrfs-vhdx` はActions専用の実験。通常のloop helperや
利用者向けsetupをまだ置き換えない。失敗時は明確にFAILとし、無限再起動はしない。

`evidence` artifactにnative出力、失敗情報、変換ログを保存する（7日間）。
イメージ、rootfs、生成された鍵はuploadしない。通常のワークフローログも証跡として参照する。
ジョブ終了時にrunnerが破棄されるため、ユーザーのホストでのunregisterやdisk削除は不要。

## 誤って合格としない範囲

Windows Serverの管理者tokenでの成功は、Windows 11の通常token/UAC/production ACLの証明ではない。
WSLgがインストールされているだけではGUI表示・音声の成功とは数えない。
VS Code Serverのファイルやプロセスがあるだけでは `code .` からの接続成功とは数えない。
VHDXの一時mountに成功しても、通常起動後の `/` がVHDX上にある証明にはならない。
再実行のたびに新しいrunnerで試すが、完全なVHDXセットアップ手順の再現と呼べるのは
その全手順が実装・実行されてから。

実施結果とrun URLは `vhdx-verification.md` に追記する。
