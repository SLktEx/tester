# 2026-11-26 専用LabでのUAC再試行とVHDX起動

ユーザーがUACを操作可能になり、既存の承認済み `ArchBtrfs-VhdxLab` で再開した。
本番や他のLab/Cleanは変更・停止していない。global shutdownは実行していない。
今回の実験はローカルWindows実機。Actionsの結果とは分けて扱う。

## 実測環境

- Windows `10.0.26300.10075`
- WSL `3.0.5.0` / kernel `6.18.58.1-1` / WSLg `1.0.79`
- 基準としたrepo commit `7f19c7971da50b77616958b59a3e18540bb52a5e`
- 接続だけ本人のUAC承認を経た管理者プロセス。
  後続session試験はWindows administrator token **False**。
- [WSLコマンド仕様](https://learn.microsoft.com/en-us/windows/wsl/basic-commands)と
  [3.0.5リリース](https://github.com/microsoft/WSL/releases/tag/3.0.5)を再確認した。

## 試行・失敗・成功の順序

1. manifestと登録GUID/保存先を照合。退避済みenable marker、原本loop未接続、
   想定UUIDのdisk不在を確認。preboot exportのSHA-256も照合した。
2. 最初のRunAs要求はPID返却後、スクリプトログなしで終了。
   Windows PowerShellの実行ポリシーはLocalMachine Restricted、他scope Undefinedだった。
   この起動では接続成功としない。
3. プロセス限定RemoteSignedによる再要求は、Windowsから「操作はユーザーによって取り消されました」。
   再度disk不在を確認した。ユーザーの操作意図とOSの結果を同一視しない。
4. 本人の再連絡後に状態を再確認し、重複するhelperがないことを確認して再要求。
   **UAC accepted、helper exit 0、result PASS**。永続execution policyは変更していない。
   固定された変換済みVHDXだけを `wsl --mount <VHDX> --vhd --bare` で接続した。
5. Find scriptで一意のwhole Btrfs diskを特定。`/dev/sdf` と期待UUIDを照合。
   `ro,rescue=nologreplay,subvolid=5` で一時mountし、instance・Arch・systemd実体・
   `@`・`@snapshots`を検査してunmount。
6. このRO検査の最初のOS判定はFAIL。`@/etc/os-release`が絶対symlink
   `/usr/lib/os-release`なので、救援側Debianを読んでいた。
   引用符の問題という初期仮説は外れ。`@/usr/lib/os-release`実体を読んでPASS。
   失敗時もtrapで一時mountを解除した。
7. VHDX root検査を先に用意し、Debian/ext4では期待どおりRED。
   Actionsで成功したfixtureから、許可distroをこのLabの名前に限定した手動試行用helperを作成。
   既存loop helperがrepo版と同一であることをcmpし、helper原本とfstab/wsl.confをbackup。
   backup tarのhashを保存した後でhelperを配置、`vhdx-mode`を作成した。
8. Windows側でmarkerを有効化し、対象だけterminate/restart。
   raw loopを使わずVHDX上のArch/Btrfsへpivotして、root検査がGREEN。
9. 新しいroot/default-user session、UNC、Windows interopを検査。
   `integration.sh --apply`でWSLgと `code .` の接続を検査した。
10. markerを退避して対象だけDebian救援へ戻した。
    `rescue.sh`と元rawのSHA-256照合がPASS。
    markerを再有効化し、Archへ戻した後もroot/session検査がPASS。
11. 救援往復後の既存VS Codeウィンドウへの再接続はFAIL。
    `Unknown reconnection token (never seen)` がサーバーログに記録され、
    90秒のextensionHost検査は失敗した。UIにも `Cannot reconnect. Please reload the window.` が表示された。
    専用LabのウィンドウだけでReload Windowを実行し、接続表示への復帰を観察した。
    その後の `integration.sh --apply` 再実行もPASS、Arch rootと一致するextensionHostを再確認。
    接続の初回成功と、既存ウィンドウの無操作再接続失敗を分けて記録する。

## PASSと未検証を分ける

| 項目 | このLabでの結果 |
|---|---|
| 本人UAC→実VHDX attach | PASS |
| `/ /etc /usr /var /home`が期待UUIDのBtrfs `@` | PASS |
| PID1 systemd、sessionと同じroot inode、systemd running | PASS |
| mount SOURCEとdisk、wsl.conf bind共有、原本loop未接続 | PASS |
| 非昇格Windows tokenからの新規root/default sessionとUNC | PASS |
| cmd.exe | PASS |
| WSLg Wayland compositor応答、XウィンドウIsViewable | PASS（APIでの判定。人による画面観察とは別） |
| PulseServer応答 | PASS（音声を実際に再生・聴取したわけではない） |
| code . のextensionHostがArchと同じrootで稼働 | PASS |
| 救援往復後の既存VS Codeウィンドウの無操作再接続 | FAIL。Reload Windowによる復帰を確認 |
| Debian救援→原本hash一致→Arch再起動 | PASS |
| 自動attach task/production ACL、無人launcher、自然idle/host reboot | NOT TESTED（今回のローカル試験） |
| snapshotからの起動復旧、完全VHDX setup、独立Cleanでの再現 | NOT TESTED |

初回のDebian救援検査では `getty@tty1` がstart-limit-hitとなりdegradedだった。
設定を変更せず、後続と救援往復時の検査ではrunning/failed units 0となった。
原因と再発条件は未確定であり、「修正済み」とは扱わない。

## 現在のLabと復旧

LabはVHDX接続済み、marker有効のArch/Btrfs状態。
通常の `wsl -d ArchBtrfs-VhdxLab --cd ~` でこの登録へ入れる。
**VHDXが未接続ならhelperはDebian救援へ戻る。自動再接続launcherはまだない。**

repoの `tools/wsl-arch-btrfs` から、manifestを保存しているlabディレクトリを指定する:

```powershell
.\recovery\recover.ps1 -Action Debian -Name ArchBtrfs-VhdxLab -Base <lab-directory> -Apply
# VHDX接続済みを確認した後だけArchへ戻す
.\recovery\recover.ps1 -Action Arch -Name ArchBtrfs-VhdxLab -Base <lab-directory> -Apply
```

Debian側 `/var/lib/archbtrfs/lab-original-helper-20261126` と
`lab-boot-backup-20261126.tar` を保持。元rawとpreboot exportも保持。
VHDXはArch起動により書き込まれたため、**変換直後hashを要求する旧04-attach-trialは再接続用に使えない**。
初期hashの検査を無条件に外す修正はせず、今後のattach処理では保護された設定とidentityの管理を実装する。
未対応の既存snapshot処理をVHDX modeで強行して原本rawを接続しないこと。

ローカルの `05-readonly-vhdx-trial.sh`、`06-*`、`Lab-*20261126*` に試行と生ログを保存。
これらは特定Labの手動実験で、汎用setupの完成品ではない。
公開用[ログ抜粋](logs/vhdx-local-20261126.txt)には成功行だけを抽出し、完全ログではないと明記した。
