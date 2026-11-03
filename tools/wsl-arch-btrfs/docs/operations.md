# 導入・再試験・復旧

## 対象

動作を検証している組み合わせは x64 Windows 26300.9818、WSL 3.0.3.0、標準 6.18.54.1 カーネル、WSLg 1.0.79。通常権限の Windows ユーザーで、ローカル C: の通常のディレクトリにリポジトリを置く。Git、PowerShell、curl.exe、WSL2、Windows 版 VS Code と WSL 拡張を使用する。既定の保存先はチェックアウトの隣の wsl-arch-btrfs-labs。初回は14 GiB以上の空きと配布元へのネットワーク接続が必要。

セットアップは新規登録に Debian の VHDX を作り、その中の専用通常ファイルを8 GiBの sparse Btrfs イメージにする。実デバイスや VHDX を mkfs に渡す経路はない。別PCで配布ファイルをあらかじめ用意する場合は、保存先の inputs に Debian.wsl・archlinux.wsl、inputs/packages に固定版の公式パッケージと署名を置く。内容は毎回照合する。Debian apt の指定バージョンや公開アーカイブが入手できない場合は停止する。

## セットアップ

リポジトリ直下の PowerShell から実行する。既定名は ArchBtrfs-Clean。既存名、新設先と衝突するディレクトリ、管理マニフェストの登録 GUID・保存先不一致はエラーとなる。初回 export の後に Debian の設定と Btrfs を準備し、対象登録だけを停止して起動し直す。成功時に Verified Arch/Btrfs と登録名が出る。

```powershell
.\setup.ps1
wsl -d ArchBtrfs-Clean --cd '~'
```

Arch の一般ユーザーは arch (UID 1000)。root の保守シェルは Windows から対象名と `-u root` を指定して開く。Arch のプロジェクトディレクトリで `code .` を実行すると、WSL 拡張がその登録に接続する。再度の setup は同じ登録を検証する。ホスト側ログは保存先の「登録名-日時-PID.log」、ゲスト側は Debian 上の /var/lib/archbtrfs の prepare.log・boot.log・finish.log。Arch 稼働中は root で /.bootstrap/old 以下から読める。

## 起動設計と更新

通常起動では Debian の fstab が C: と専用 mount helper を順に処理する。Windows 側の有効化ファイルが存在すれば、helper が Btrfs のルートをマウントし、WSL の一時マウントと疑似ファイルシステムを渡して pivot する。その後に Plan9 が / を公開し、WSL が Arch の systemd を PID 1 として起動する。元の Debian の /sbin/init は使える状態で残る。旧ルートは root 専用の .bootstrap ディレクトリ内に配置する。fstab 初期化時の環境変数・一時名は WSL 内部仕様への依存であり、更新後は専用登録で再試験する。

Arch rootfs と61個の追加・更新パッケージはハッシュを固定し、パッケージは Arch の署名も検証する。固定した初期状態から通常の Arch ローリング更新を行う場合は、最初にスナップショットを作成する。Btrfs イメージは VHDX と同じドライブにあり、スナップショットはディスク紛失に対する外部バックアップにはならない。

## 試験

```powershell
.\tests\session.ps1
.\tests\reproduce.ps1
```

前者は現在の Windows トークンから新規プロセス・PID 1・UNC のルートを検査する。後者はクリーン試験専用登録を再起動し、セットアップ再実行、ファイルを変更してからのスナップショット復旧、準備後の故障注入、X11 表示、Wayland・PulseAudio、cmd.exe、VS Code リモート拡張ホストの root を検証する。試験用のサブボリュームとホーム内の検査ファイルを証跡として残す。実行中のエディターを含め、対象ディストリビューションは停止される。

昇格の有無でルートが変わらないかを検査するには、未昇格の PowerShell 7 から `.\tests\token-order.ps1 -Name ArchBtrfs-Clean02` を使う。対象を停止して通常→管理者の順に入り、もう一度対象を停止して管理者→通常の順に入る。各組で /run の一時ファイルと PID 名前空間を照合し、mount 名前空間を切り替えても Btrfs UUID・サブボリューム・root の device:inode が一致することを要求する。管理者側は Windows の UAC と本人の同意を使う。

## 復旧

次の例は対象登録を既定名としている。別の専用登録は各スクリプトに同じ `-Name` と `-Base` を渡す。スナップショット取得前には編集中のファイルやデータベースをアプリ側で整合する状態にする。

```powershell
.\recovery\recover.ps1 -Action Snapshot -Label before-update
.\recovery\recover.ps1 -Action Restore -Label before-update
```

Restore は有効化ファイルを退避し、Debian/ext4 で起動し直す。読み取り専用スナップショットから書き込み可能なクローンを作り、元の @ を別名で保持してから新しい @ に切り替える。復旧中断時は同じラベルで再試行し、候補の親 UUID を照合する。

```powershell
.\recovery\recover.ps1 -Action Debian
.\recovery\recover.ps1 -Action Arch
```

前者は Btrfs の有効化を外して Debian を起動する。boot.log、UUID、loop ファイルや署名を確認できる。壊れたファイルを見つけた場合に mkfs をやり直す操作は含めていない。初期設定を取り外すには `-Action Uninstall` を使う。管理中の fstab が設置時の内容に一致することを確認し、元の設定へ戻す。登録・8 GiB イメージ・スナップショットは保存される。登録解除は VHDX の削除を伴うため自動化の対象外。

Debian 自体を起動できない場合は、Windows 側に保存した「登録名-preboot.tar」の SHA-256 を対応する .sha256 と照合する。元の登録・VHDX を保管し、別名と空の保存先を承認してから backup tar を WSL2 に import する。これは Btrfs 作成前の Debian を復元する操作であり、Arch のデータは別途保存したイメージまたは元の VHDX から回収する必要がある。

## 本番利用に移る場合の手順案

1. 専用の新規登録名（例 `ArchBtrfs-Daily`）と保存先を決め、空き容量とバックアップ先を確認して、変更範囲の明示的な承認を受ける。
2. 承認後に `.\setup.ps1 -Name ArchBtrfs-Daily` で新規構築する。旧環境の登録とデータは移行元として保持する。
3. `.\tests\session.ps1 -Name ArchBtrfs-Daily` でルートを照合し、対象環境で実際のプロジェクトを `code .` で開く。日常利用前のスナップショットと、対象停止中の別媒体バックアップを取得してからデータ移行を行う。
4. WSL 更新後はまず専用テスト登録で再起動・通常／昇格・連携・復旧試験を行い、合格したバージョンと結果を記録する。本番利用への移行は今回の実機試験の対象外。
