# VHDXのオフライン復旧バンドル

2026-11-26の専用Labで手動検証した後に `recovery/vhdx-bundle.sh` を実装した。
これはVHDX全体の完成版setupではない。接続済みの専用VHDXと、Debian救援状態を必要とする。

## 実機で確認したこと

1. 検査を先に追加し、試験データ不在でREDになることを確認した。
2. `/home/arch` と、systemdが作った `/var/lib/machines` の別サブボリュームに
   baselineを保存。救援起動後、rootと入れ子2個を別々にreadonly snapshotにした。
3. rootだけのsnapshotにはmachines内のデータが含まれないことを実測した。
   これは[Btrfs公式の非再帰snapshot仕様](https://btrfs.readthedocs.io/en/latest/btrfs-subvolume.html#nested-subvolumes)とも一致する。
4. 現在の2ファイルをchangedに変更。readonly snapshotから書込可能cloneを組み立てた。
5. 元rootの退避後、新rootを `@` にする前に意図的にexit 75で停止。
   新規セッションでもDebian救援を利用できた。
6. 保存したsubvolume IDと実体を照合して再開。Arch起動後、両ファイルのbaseline復元、
   元root側のchanged保持、systemd、新規root/default session、UNCを確認した。
7. 成功手順を汎用化したスクリプトでも、snapshot要求2回、exit 75停止、restore再開、
   restore再実行、全一時mount解除がPASS。

より深い入れ子と空白を含む名前の試験を `tests/vhdx-bundle-contract.sh` に追加した。
この追加ケースの結果はCIログで別に確認する。旧手動試験の成功を代用しない。

## 使用条件と操作

Windows側で通常のセットアップ・起動操作と同じ専用distroロックを取得して操作する。
`recovery/recover.ps1 -Action Debian` でactivation markerを無効化して対象だけ救援起動する。
未対応の旧 `snapshot.sh` をVHDXで使わない。

Debian内で、実際のinstanceと新しいlabelを指定する。`--apply`なしはdry-run。

```sh
bash /path/to/project/recovery/vhdx-bundle.sh snapshot baseline INSTANCE --apply
bash /path/to/project/recovery/vhdx-bundle.sh restore baseline INSTANCE --apply
```

root確認と同一UUIDのwhole disk確認、marker無効、loop不在、Btrfsの他mount不在が必要。
Linux側も `setup.lock` で排他する。Windows側の排他は呼出元の責務。
完了後に接続状態を確認し、`recover.ps1 -Action Arch` で戻る。
VS Codeの既存接続はroot切替後にReload Windowを要する場合がある。

## 保存と復旧の仕組み

- `@snapshots/bundle-LABEL` にroot・全入れ子のreadonly snapshotとNUL区切りのmanifestを保存。
  サブボリューム境界は `find -xdev` とinode/subvolume IDで確認し、子を順番に列挙する。
- 同名の完成済みbundleはUUID/readonly/instanceを検証して再利用する。上書きしない。
- 書込可能cloneを構築し、各cloneのParent UUIDを元snapshotと照合する。
  入れ子の空placeholderだけを `rmdir` し、再帰削除はしない。
- 旧/new root IDとsnapshot UUIDをDebian側journalに同期保存してから2回のrenameを行う。
  旧rootは `@before-restore-LABEL` として入れ子ごと保持する。
- 2回のrenameの間で停止した場合は、markerを無効のまま同じrestoreを再実行する。
  完了後の再実行はIDを検査してno-opになる。

## 現時点の制約

- オフライン操作のみ。稼働中のアプリケーションを整合状態にする機能はない。
- 1 labelにつき1復旧トランザクション。同じ内容へ別の復旧を行うAPIは未実装。
- snapshot生成途中、またはrestore journal確定前の停止では、不完全artifactを保持して停止する。
  元rootは変更していない。状態確認と新labelでの再試行が必要で、この区間の自動再開は未実装。
- snapshotは同じVHDX内のコピーなので、VHDX紛失・破損への外部バックアップにはならない。
- 自然なVM idle、Windows再起動、保護store/task、無人VHDX setupと独立Clean再現の合格は
  この復旧試験だけでは証明できない。

`Native-Process.ps1` には実プロセスで検証したUTF-8引数処理、終了コード、上限時間、
ファイルロックを追加した。タイムアウト時に終了するのは起動したクライアントだけ。
OS側の要求が継続している可能性を報告し、WSL VMや他distroは停止しない。
