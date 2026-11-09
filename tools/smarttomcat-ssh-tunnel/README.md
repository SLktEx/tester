# SmartTomcat + SSH database tunnel (Windows)

SmartTomcat の実行構成を開始する前に、Windows の OpenSSH でローカルポートフォワードを立ち上げる小さなツールです。

**動作:** SmartTomcat の Run/Debug ボタン → IntelliJ の Before launch から PowerShell 実行 → SSH ポートが listen 状態になるまで待機 → SmartTomcat 開始。

本ツールは **SSH トンネルを作るだけ** です。DB 認証は既存アプリの JDBC 側で行います。DB 接続先や秘密鍵、パスワードはこの GitHub リポジトリには含めていません。

## ファイル

- start-db-tunnel.ps1: 起動・再利用・起動失敗検出（Windows PowerShell 5.1+）
- stop-db-tunnel.ps1: 対応する SSH プロセスだけを手動終了
- ssh_config.example: %USERPROFILE%\.ssh\config に入れる設定の例

## 1. SSH を設定

ssh_config.example の内容を、**自分の Windows PC** の %USERPROFILE%\.ssh\config に追加して次の値を実環境に合わせて変更します。

- HostName: SSH 接続先（踏み台）
- User: SSH ユーザー
- IdentityFile: 秘密鍵の場所
- LocalForward の db.internal.example:3306: 踏み台から見える実DBのホスト・ポート
- LocalForward の 127.0.0.1:13306: Windows 内で利用するポート

この例は MySQL (3306) 用です。PostgreSQL 等の場合は変更してください。ローカル側は必ず 127.0.0.1 に限定し、外部に公開しないこと。

**初回のみ対話的に接続して known_hosts と鍵を確認してください。**

```powershell
ssh smarttomcat-db
```

実際に認証でき、踏み台のホスト鍵を確認・登録できたら終了します。秘密鍵のパスフレーズやMFA等を毎回求められる構成では、Windows OpenSSH の ssh-agent など非対話で認証できる仕組みを別途準備してください。スクリプトは BatchMode=yes により、IDE裏でパスワード入力待ちにならないようにしています。

## 2. スクリプトを配置

SmartTomcat を使用する **Java プロジェクト** に start-db-tunnel.ps1 をコピーして、例えば次の場所に置いてください。

```text
<your-java-project>\scripts\start-db-tunnel.ps1
```

tester を別の場所に clone 済みなら、コピーせずこのリポジトリのファイルに絶対パスで直接アクセスしても構いません。

まず PowerShell から手動実行し、ポートが開くか確認します。

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\scripts\start-db-tunnel.ps1
Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 13306 -State Listen
```

再実行したときは、同じ SSH ホスト別名のトンネルなら再利用します。13306 が無関係なプロセスに使われている場合は中断します。

## 3. IntelliJ IDEA に登録

1. Settings → Tools → External Tools → + を開く。
2. Name: DB SSH Tunnel
3. Program: powershell.exe
4. Arguments:

```text
-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ProjectFileDir$\scripts\start-db-tunnel.ps1"
```

5. Working directory: $ProjectFileDir$
6. 保存したら Run → Edit Configurations → 使用中の **Smart Tomcat** を選ぶ。
7. Before launch → + → Run External Tool → DB SSH Tunnel を追加。
8. 設定を保存し、以後は SmartTomcat の ▶ / Debug から起動する。

Before launch が見えない場合は Modify options → Add before launch task を確認してください。Smart Tomcat プラグインのバージョンによって画面名が異なる可能性があります。

JetBrains の一般的な Run/Debug 設定における Before launch / Run External Tool の公式説明:
https://www.jetbrains.com/help/idea/configuring-third-party-tools.html
https://www.jetbrains.com/help/idea/run-debug-multiple.html

## 4. JDBC の接続先をローカルにする

MySQL の例:

```properties
jdbc:mysql://127.0.0.1:13306/mydb
```

127.0.0.1:13306 は「Windows 上の SSH の入口」です。実際の DB ホスト db.internal.example:3306 は SSH 設定で管理します。

**注意:** TCP のローカルポートが開くことは、転送先のDBへの接続成功までは保証しません。DBホストやDB認証は別途確認してください。

## 5. 手動停止

SmartTomcat の停止だけでは SSH プロセスは自動終了しません。不要になったら次を実行します。

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tools\smarttomcat-ssh-tunnel\stop-db-tunnel.ps1
```

※ 上のコマンドは tester リポジトリのルートから実行する場合です。別の場所にコピーした場合はパスを読み替えてください。複数のアプリで同じトンネルを使っているなら、他のアプリの接続が終わるまで停止しないでください。

## 変更できる引数

起動用・停止用ともに次の引数をサポートします。

- -SshHost smarttomcat-db （~/.ssh/config の Host 別名）
- -LocalPort 13306 （LocalForward のローカルポートと一致させる）
- 起動用のみ: -TimeoutSeconds 15 （ポート待機時間）

例:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\scripts\start-db-tunnel.ps1 -SshHost smarttomcat-db -LocalPort 13306
```

## トラブルシュート

- SSH が開始直後に終了: ssh smarttomcat-db で認証を確認。鍵・ホスト鍵・ssh-agent を点検。
- 原因を詳細に見たい: 他のトンネルを停止してから PowerShell で ssh -vvv -NT smarttomcat-db を実行（Ctrl+C で終了）。
- ポート使用中: Get-NetTCPConnection -LocalPort 13306 -State Listen | Select-Object LocalAddress, LocalPort, OwningProcess で確認。
- トンネル起動は成功、DB接続は失敗: 踏み台から見たDBのホスト名・DBポート・DB認証・ファイアウォール等を確認。
- SSH 実行ファイルがない: Windows の OpenSSH Client 機能を有効にする。

### 検証状況

PowerShell のコードは Windows 10/11 の標準的な OpenSSH Client / Get-NetTCPConnection を想定しています。実際の IntelliJ・Smart Tomcat・踏み台・DB では未検証です。実機で手動起動→再利用→ポート競合→停止を確認してから利用してください。
