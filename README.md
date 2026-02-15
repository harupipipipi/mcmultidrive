# MC MultiDrive

複数のMinecraftワールドを友達と共有できるセッション管理ツール。

## 特徴

- **複数ワールド対応** — ATM10, Vanilla, Create 等を1つのツールで管理
- **GUIで簡単操作** — プレイヤー名を入れるだけで使い始められる
- **自動同期** — ホスト開始時に自動DL、終了時に自動UL
- **e4mcドメイン自動検出** — ドメインを自動でクリップボードにコピー
- **誰でもワールド追加可能** — GUIから新しいワールドをワンクリック追加

## 管理者セットアップ（1回だけ）

### 1. Google Sheets + GAS

1. Google スプレッドシートを作成
2. シート名を `status` に変更
3. `gas/code.gs` の内容をスクリプトエディタに貼り付け
4. ウェブアプリとしてデプロイ（全員がアクセス可能に設定）
5. デプロイURLを `shared_config.json` の `gas_url` に記入

### 2. Google Drive 共有フォルダ

1. Google Drive にフォルダを作成（例: `minecraft_worlds`）
2. フォルダIDを `shared_config.json` の `rclone_drive_folder_id` に記入

### 3. rclone セットアップ

1. https://rclone.org/downloads/ から rclone をダウンロード
2. `rclone/rclone.exe` として配置
3. `rclone.exe config` でGoogle Driveリモートを設定（名前: `gdrive`）
4. 生成された `rclone.conf` をプロジェクトルートに配置

### 4. ビルド＆配布

```bash
build.bat
```

`dist/release/` フォルダをzipで友達に配布。

## 使う人（友達）がやること

1. 受け取ったフォルダを展開
2. `MCMultiDrive.exe` を起動
3. プレイヤー名を入力
4. 以上！

## ファイル構成

```
MCMultiDrive/
├── MCMultiDrive.exe          # メインアプリ
├── shared_config.json        # 共通設定
├── rclone/
│   └── rclone.exe            # rclone
└── rclone.conf               # rclone認証情報
```
