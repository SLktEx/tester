# Arch Linux on Btrfs under WSL2

**VHDXの2段階起動は開発中です。** [設計・添付版の監査](docs/vhdx-two-stage.md) と
[テスト結果・未検証一覧](docs/vhdx-verification.md) を参照してください。
現時点では先行テストと安全性の修正のみで、VHDX実機・クリーン再現の完了は主張しません。
以下は従来のraw/loop方式です。

Windows PowerShell から専用の WSL2 登録を作り、通常起動した Arch Linux のルートに Btrfs を使う。起動基盤は Debian/ext4、Arch はその内部に置く 8 GiB のイメージに展開する。WSL が Windows 向けのファイル共有を開始する前にルートを切り替えるため、Windows から開いた新しいセッションと VS Code の WSL 拡張も Arch を参照する。

このディレクトリを作業場所にして実行する。

```powershell
.\setup.ps1
wsl -d ArchBtrfs-Clean --cd '~'
```

[前提条件、保存先、スナップショットと復旧手順](docs/operations.md)

WSL 3.0.3 の x64 環境で、新規登録からの無人構築、再起動、セットアップ再実行、故障後の再開、スナップショット復旧を確認した。通常・昇格の両起動順で同じ Btrfs のルートを確認し、WSLg、Windows 実行ファイル、VS Code のリモート拡張ホストも検証した。WSL 更新後は専用登録で再試験する。
