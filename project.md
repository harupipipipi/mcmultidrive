
#### project.md

```markdown
# ATM10 Session Manager — プロジェクト仕様書 v2

## 1. プロジェクト概要

### 1.1 何を作るか

Minecraft Modpack「All the Mods 10（ATM10）」を2〜3人でマルチプレイするための**外部セッション管理ツール**（Pythonアプリ）。

ホスト交代制を採用し、Google Drive上にワールドデータを共有保存することで「特定の1人がオンラインでないと遊べない」問題を解消する。マルチプレイ接続にはe4mc Modを使用し、ポート開放は一切不要。

### 1.2 なぜ作るか

ATM10を無料でマルチプレイする方法は現状2つある。

1. **Essential Mod** — ホストがワールドを開いてフレンドを招待。ホストが落ちると全員切断。
2. **e4mc Mod** — LAN公開をインターネットに公開するトンネルMod。同じくホストが落ちると全員切断。

どちらもホストが固定されるため、ホストがいないときに他のメンバーだけで遊ぶことができない。本ツールは以下を自動化し、この問題を解決する。

- Google Driveからワールドをダウンロード
- level.datのPlayerタグ削除（ホスト交代対策）
- ワールドをCurseForgeインスタンスのsavesフォルダに配置
- e4mcが生成するドメインをログから自動取得
- ドメインをGoogle Sheets（GAS経由）に書き込み（ステータス管理）
- 接続側はGAS経由でドメインを取得し、servers.datに自動追加
- セッション終了後、ワールドをGoogle Driveに自動アップロード

### 1.3 ユーザーの操作（手動部分）

**ホスト側（5クリック）:**
1. 本ツールを起動し「ホストとして開始」を選択
2. CurseForgeの「Play」ボタンを押す
3. ワールドを選択して開く
4. Esc → Open to LAN → Start LAN World

**接続側（3クリック）:**
1. 本ツールを起動し「接続する」を選択
2. CurseForgeの「Play」ボタンを押す
3. マルチプレイ画面のサーバーリスト1番目をクリック

それ以外の処理（DL/UL、ファイル編集、ステータス管理、ドメイン取得等）はすべて自動。

---

## 2. システム構成

### 2.1 全体アーキテクチャ

```
┌──────────────────────────────────────────────────────┐
│                  Google サービス                      │
│                                                      │
│  ┌──────────────┐    ┌───────────────────────────┐   │
│  │ Google Drive  │    │ Google Sheets + GAS       │   │
│  │ (共有フォルダ)│    │ (ステータス管理)          │   │
│  │  └─ world/    │    │  GAS Webアプリとして公開   │   │
│  │  └─ backups/  │    │  HTTP GET/POST で操作     │   │
│  └──────┬───────┘    └──────────┬────────────────┘   │
│         │                        │                    │
└─────────┼────────────────────────┼────────────────────┘
          │  rclone sync           │  requests
          │  (差分転送)            │  (HTTP GET/POST)
          ▼                        ▼
┌──────────────────────────────────────────────────────┐
│            ATM10 Session Manager (Python)              │
│  ┌────────────┬────────────┬────────────────────┐    │
│  │ world_sync │ status_mgr │ log_watcher        │    │
│  │ (rclone)   │ (requests) │ (e4mcドメイン取得) │    │
│  ├────────────┼────────────┼────────────────────┤    │
│  │ nbt_editor │ process_mon│ config_mgr         │    │
│  │ (nbtlib)   │ (psutil)   │ (config.json)      │    │
│  └────────────┴────────────┴────────────────────┘    │
└──────────────────────┬───────────────────────────────┘
                       │  ファイル操作
                       ▼
┌──────────────────────────────────────────────────────┐
│         CurseForge インスタンス (ATM10)               │
│  saves/<world_name>/    ← ワールド配置先              │
│  logs/latest.log        ← e4mcドメイン取得元          │
│  servers.dat            ← 接続先IP自動追加            │
│  mods/e4mc-xxx.jar      ← e4mc Mod（手動導入済み）    │
└──────────────────────────────────────────────────────┘
```

### 2.2 使用技術・ライブラリ

| 技術 | 用途 | バージョン要件 |
|------|------|----------------|
| Python | メイン言語 | 3.10以上 |
| rclone | Google Drive差分同期 | 最新安定版 |
| requests | GAS WebアプリへのHTTP通信 | 最新安定版 |
| nbtlib | level.dat / servers.dat編集 | 最新安定版 |
| psutil | Minecraftプロセス監視 | 最新安定版 |
| pyperclip | クリップボードコピー | 最新安定版 |
| PyInstaller | exe化（配布用） | 最新安定版 |

### 2.3 外部サービス

| サービス | 用途 | 費用 | 備考 |
|----------|------|------|------|
| Google Sheets + GAS | ステータス管理API | 無料 | Googleアカウントのみで利用可能 |
| Google Drive | ワールドデータ保存 | 無料 | Google Oneの容量を使用 |
| Google Cloud Console | OAuthクライアントID作成 | 無料 | 1人が1回だけ作業。5分程度 |
| e4mc Mod | NAT越えトンネル | 無料 | ホスト側のみインストール |

---

## 3. Minecraft Mod互換性

### 3.1 e4mcとATM10の互換性

e4mc NeoForge版 6.0.1（2026年2月リリース）はATM10（NeoForge + Minecraft 1.21）に対応している。CurseForgeからダウンロードし、ATM10インスタンスのmodsフォルダに配置するだけでよい。

**ホスト側のみe4mcが必要。接続する側はe4mcをインストールする必要がない。**

### 3.2 既知の互換性問題と対策

Redditの複数報告（r/allthemods）から、ATM10でe4mcを使用する際に以下のModが干渉する可能性がある。

| Mod名 | 問題 | 対策 |
|--------|------|------|
| LogProtection | LAN公開をブロックする場合がある | modsフォルダから削除 |

これらの情報は2024〜2025年時点のものであり、ATM10やe4mcのアップデートで解消されている可能性がある。問題が起きた場合のみ対処する。

### 3.3 本ツール自体のMod互換性

**本ツールはMinecraftの外部で動作するPythonアプリであり、Modとは一切干渉しない。** ツールが操作するのはファイルシステム上のファイル（saves内のワールドフォルダ、level.dat、servers.dat、logs/latest.log）のみであり、Minecraftのプロセスやメモリには触れない。ATM10に何百個のModが入っていても、本ツールの動作には影響しない。

---

## 4. ファイル構成

```
atm10-session-manager/
├── main.py                  # エントリポイント（モード選択UI）
├── config.json              # ユーザー設定
├── modules/
│   ├── __init__.py
│   ├── config_mgr.py        # 設定ファイル読み込み・バリデーション
│   ├── status_mgr.py        # GAS経由ステータス管理（HTTP）
│   ├── world_sync.py        # rclone によるワールド同期
│   ├── nbt_editor.py        # level.dat / servers.dat 編集
│   ├── log_watcher.py       # latest.log 監視（e4mcドメイン取得）
│   └── process_monitor.py   # Minecraftプロセス終了検知
├── rclone/
│   └── rclone.exe           # rclone同梱（Windowsバイナリ）
├── rclone.conf              # rclone設定（各自がrclone configで生成）
└── README.md                # セットアップ手順
```

---

## 5. config.json 仕様

```json
{
  "curseforge_instance_path": "C:\\Users\\<user>\\curseforge\\minecraft\\Instances\\All the Mods 10",
  "world_name": "ATM10_Shared",
  "gas_url": "https://script.google.com/macros/s/XXXXXXXXXXXX/exec",
  "rclone_remote_name": "gdrive",
  "rclone_drive_folder_id": "1DEFxyz...",
  "rclone_exe_path": "./rclone/rclone.exe",
  "rclone_config_path": "./rclone.conf",
  "player_name": "MyPlayerName",
  "backup_generations": 5,
  "lock_timeout_hours": 8
}
```

| フィールド | 説明 |
|------------|------|
| curseforge_instance_path | CurseForgeのATM10インスタンスフォルダの絶対パス |
| world_name | 共有ワールドのフォルダ名（saves内） |
| gas_url | GAS WebアプリのデプロイURL |
| rclone_remote_name | rclone.confで設定したリモート名 |
| rclone_drive_folder_id | Google Drive共有フォルダのID |
| rclone_exe_path | rclone.exeのパス |
| rclone_config_path | rclone.confのパス |
| player_name | 自分のMinecraftプレイヤー名（表示用） |
| backup_generations | Google Drive上に保持するバックアップ世代数 |
| lock_timeout_hours | ロックの自動解除時間（時間） |

---

## 6. Google Sheets + GAS 仕様

### 6.1 Sheetsレイアウト

シート名: `status`

| セル | 内容 | 例 |
|------|------|-----|
| A1 | ステータス | `online` / `offline` |
| A2 | ホスト名 | `PlayerA` |
| A3 | e4mcドメイン | `brave-sunset.sg.e4mc.link` |
| A4 | セッション開始時刻（UTC） | `2026-02-14T08:30:00.000Z` |
| A5 | ロックタイムスタンプ（UTC） | `2026-02-14T08:30:00.000Z` |

### 6.2 GAS Webアプリ コード

以下のコードをGoogle Sheetsの「拡張機能 → Apps Script」に貼り付け、Webアプリとしてデプロイする。

```javascript
function doGet(e) {
  var sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName("status");
  var data = {
    status: sheet.getRange("A1").getValue() || "offline",
    host: sheet.getRange("A2").getValue() || "",
    domain: sheet.getRange("A3").getValue() || "",
    start_time: sheet.getRange("A4").getValue() || "",
    lock_timestamp: sheet.getRange("A5").getValue() || ""
  };
  return ContentService.createTextOutput(JSON.stringify(data))
    .setMimeType(ContentService.MimeType.JSON);
}

function doPost(e) {
  var sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName("status");
  var params = JSON.parse(e.postData.contents);

  if (params.action === "set_online") {
    var now = new Date().toISOString();
    sheet.getRange("A1").setValue("online");
    sheet.getRange("A2").setValue(params.host);
    sheet.getRange("A3").setValue(params.domain || "preparing...");
    sheet.getRange("A4").setValue(now);
    sheet.getRange("A5").setValue(now);
    SpreadsheetApp.flush();
    var currentHost = sheet.getRange("A2").getValue();
    return ContentService.createTextOutput(JSON.stringify({
      success: (currentHost === params.host),
      current_host: currentHost
    })).setMimeType(ContentService.MimeType.JSON);
  }

  if (params.action === "update_domain") {
    sheet.getRange("A3").setValue(params.domain);
    return ContentService.createTextOutput(JSON.stringify({
      success: true
    })).setMimeType(ContentService.MimeType.JSON);
  }

  if (params.action === "set_offline") {
    sheet.getRange("A1").setValue("offline");
    sheet.getRange("A2").setValue("");
    sheet.getRange("A3").setValue("");
    sheet.getRange("A4").setValue("");
    sheet.getRange("A5").setValue("");
    return ContentService.createTextOutput(JSON.stringify({
      success: true
    })).setMimeType(ContentService.MimeType.JSON);
  }

  return ContentService.createTextOutput(JSON.stringify({
    success: false,
    error: "unknown action"
  })).setMimeType(ContentService.MimeType.JSON);
}
```

### 6.3 GASデプロイ手順

1. Google Sheetsを新規作成
2. シート名を「status」に変更
3. A1セルに `offline` と入力
4. 「拡張機能」→「Apps Script」を開く
5. 上記コードを貼り付け
6. 「デプロイ」→「新しいデプロイ」
7. 種類：「ウェブアプリ」
8. 実行ユーザー：「自分」
9. アクセスできるユーザー：「全員」
10. デプロイ → URLが発行される → これが `gas_url`

### 6.4 GASの注意点

- GAS WebアプリのURLは秘密にすること。URLを知っている人なら誰でもステータスを操作できる。3人だけで共有する。
- GASのPOSTリクエストはリダイレクト（302）を返す場合がある。Pythonのrequestsはデフォルトでリダイレクトを自動追従するが、POSTからGETにメソッドが変わる点に注意。対策として `requests.post(url, json=data, allow_redirects=True)` を使い、最終レスポンスのテキストをJSONとしてパースする。
- GASの同時実行制限：同一スクリプトの同時実行数は30。2〜3人の利用では問題にならない。

---

## 7. Google Drive フォルダ構造

```
ATM10_Shared/                    ← 共有フォルダ（folder_idで指定）
├── world/                       ← 現在のワールドデータ（最新版）
│   ├── level.dat
│   ├── region/
│   │   ├── r.0.0.mca
│   │   ├── r.0.-1.mca
│   │   └── ...
│   ├── playerdata/
│   │   ├── <uuid1>.dat
│   │   ├── <uuid2>.dat
│   │   └── ...
│   ├── data/
│   └── ...（Mod生成フォルダ含む）
└── backups/
    ├── 2026-02-14_083000/
    │   └── world/
    ├── 2026-02-13_200000/
    │   └── world/
    └── ...
```

---

## 8. モジュール仕様

### 8.1 main.py — エントリポイント

起動すると以下のCUIメニューを表示する。

```
=== ATM10 Session Manager ===
現在のステータス: offline

[1] ホストとして開始（ワールドDL → LAN公開 → 自動管理）
[2] 接続する（既存セッションに参加）
[3] ワールドを手動アップロード
[4] ワールドを手動ダウンロード
[5] 設定確認
[0] 終了

選択 >
```

**起動時の処理:**
1. config.jsonを読み込み、バリデーション
2. GAS URLにGETリクエストを送り、現在のステータスを取得
3. ステータスを表示してメニューを出す

### 8.2 status_mgr.py — ステータス管理

**使用ライブラリ:** requests（標準的なHTTPライブラリ）

**通信先:** config.jsonの `gas_url`

**主要関数:**

`get_status(gas_url: str) -> dict`
- GAS URLにGETリクエストを送信
- レスポンスJSONをパースして辞書で返す
- 戻り値: `{"status": "online", "host": "PlayerA", "domain": "xxx.e4mc.link", "start_time": "...", "lock_timestamp": "..."}`
- 通信エラー時は `{"status": "error"}` を返す

`set_online(gas_url: str, player_name: str, domain: str = "preparing...") -> bool`
- GAS URLにPOSTリクエストを送信
- ボディ: `{"action": "set_online", "host": player_name, "domain": domain}`
- レスポンスの `success` が `true` かつ `current_host` が自分の名前なら `True`
- 他の人が先に取得していたら `False`

`update_domain(gas_url: str, domain: str) -> bool`
- GAS URLにPOSTリクエストを送信
- ボディ: `{"action": "update_domain", "domain": domain}`

`set_offline(gas_url: str) -> bool`
- GAS URLにPOSTリクエストを送信
- ボディ: `{"action": "set_offline"}`

`is_lock_expired(lock_timestamp: str, timeout_hours: int) -> bool`
- lock_timestamp（ISO 8601文字列）と現在時刻UTCを比較
- timeout_hours を超えていたら `True`

**GASリダイレクト対応の実装上の注意:**
GAS Webアプリはリクエスト時に `https://script.google.com/macros/s/.../exec` から `https://script.googleusercontent.com/...` にリダイレクト（302）する。requestsはデフォルトでリダイレクトを追従するが、POSTの場合はリダイレクト先でGETに変わることがある。以下のいずれかで対処する:
- 方法A: `requests.post()` の結果がリダイレクト後のGETレスポンスになる場合があるため、レスポンスのテキストを直接 `json.loads()` する
- 方法B: `allow_redirects=False` で302を受け取り、Locationヘッダーに対してGETする

### 8.3 world_sync.py — ワールド同期

**使用ツール:** rclone（subprocess経由で呼び出し）

**主要関数:**

`download_world(config: dict) -> bool`
- rclone sync コマンドでDriveからローカルへ同期
- コマンド:
  ```
  rclone sync {remote}:{folder_id}/world {instance_path}/saves/{world_name}
    --config {rclone_conf} --progress
  ```
- 成功時 `True`、失敗時 `False`

`upload_world(config: dict) -> bool`
- rclone sync コマンドでローカルからDriveへ同期
- コマンド:
  ```
  rclone sync {instance_path}/saves/{world_name} {remote}:{folder_id}/world
    --config {rclone_conf} --progress
  ```

`create_backup(config: dict) -> bool`
- 現在のDrive上のworldをbackups/{timestamp}/にコピー
- コマンド:
  ```
  rclone copy {remote}:{folder_id}/world {remote}:{folder_id}/backups/{timestamp}/world
    --config {rclone_conf}
  ```
- バックアップ数がbackup_generationsを超えたら最古のものを削除

**rcloneの差分同期について:**
rcloneはファイルのサイズと更新日時で比較し、変更があったファイルのみを転送する。ATM10のワールドはリージョンファイル(.mca, 各最大4MB)の集合体であり、1セッションで変更されるのは探索・建築したチャンクのリージョンのみ。初回は2〜5GBの全量転送（100Mbpsで3〜7分）だが、2回目以降は差分のみで数十MB〜数百MB（1〜2分）で完了する。

### 8.4 nbt_editor.py — NBTファイル編集

**使用ライブラリ:** nbtlib

**主要関数:**

`fix_level_dat(world_path: str) -> bool`
- `{world_path}/level.dat` を読み込む（gzip圧縮NBT）
- `Data` > `Player` タグが存在すれば削除する
- 削除前に `level.dat.bak` としてバックアップを作成する
- 保存して `True` を返す

**なぜ必要か:**
Minecraftはシングルプレイヤーのホストのデータをlevel.dat内の `Data.Player` タグに保存する。ホストが交代すると、新ホストのインベントリ・位置が前ホストのデータで上書きされてしまう。`Player` タグを削除すると、各プレイヤーは `playerdata/<UUID>.dat` から自分のデータを読み込むため、この問題が解消される。

`update_servers_dat(instance_path: str, server_ip: str, server_name: str) -> bool`
- `{instance_path}/servers.dat` を読み込む（**非圧縮**NBT、`gzipped=False`）
- サーバーリストの先頭に `{"name": server_name, "ip": server_ip}` を挿入する
- 同じ名前のエントリが既にあれば、IPを更新する（重複防止）
- 保存して `True` を返す

**servers.datのNBT構造:**
```
{} (root compound)
└── servers (list)
    ├── [0] {name: "ATM10 Session", ip: "xxx.e4mc.link"}
    ├── [1] {name: "...", ip: "..."}
    └── ...
```

### 8.5 log_watcher.py — ログ監視

**監視対象:** `{instance_path}/logs/latest.log`

**検出パターン（正規表現）:**
```
Local game hosted on domain \[([^\]]+\.e4mc\.link)\]
```

**e4mcのログ出力形式（実際のログ例）:**
```
[18:40:17] [Render thread/INFO]: [System] [CHAT] Local game hosted on domain [brave-sunset.sg.e4mc.link] (Click here to stop)
```

**主要関数:**

`watch_for_domain(log_path: str, timeout_seconds: int = 120) -> str | None`
- latest.logの末尾から監視を開始する（既存の内容は無視）
- 新しい行が追加されるたびに正規表現でマッチを試みる
- マッチしたらドメイン文字列を返す
- timeout_seconds経過してもマッチしなければ `None` を返す

**実装上の注意:**
- latest.logはMinecraft起動時に新規作成される。ツールはMinecraft起動前にログ監視を開始する必要がある
- ファイルが存在しない場合は作成されるまで待機する
- ファイルの末尾からseekして、それ以降の新規行のみを読む
- readline()が空文字を返したらsleep(0.5)して再試行（ポーリング方式）

### 8.6 process_monitor.py — プロセス監視

**使用ライブラリ:** psutil

**主要関数:**

`find_minecraft_process() -> int | None`
- `psutil.process_iter()` でプロセスを列挙
- `javaw.exe` のプロセスを探す
- コマンドライン引数に `net.minecraft` または `minecraft` を含むものを特定する
- 見つかったらPIDを返す。なければ `None`

`wait_for_exit(pid: int, poll_interval: float = 3.0) -> None`
- 指定PIDのプロセスが終了するまでポーリングで待機する
- プロセスが消滅したら3秒のウェイト後（ファイル書き込み完了待ち）に戻る

---

## 9. メインフロー詳細

### 9.1 ホストフロー

```
[1] ホストとして開始 が選択された

1. ステータスを確認（status_mgr.get_status()）
   ├── status == "online" の場合
   │   ├── ロックがタイムアウトしているか確認
   │   │   ├── タイムアウト → 警告表示、続行するか確認
   │   │   └── タイムアウトしていない → 「現在 {host} がホスト中」表示→終了
   │   └
   └── status == "offline" の場合 → 続行

2. ロック取得（status_mgr.set_online(player_name, "preparing...")）
   ├── 成功（自分の名前が書かれている） → 続行
   └── 失敗（他の人が先に取得した） → 「他の人が先にホスト開始」表示→終了

3. ワールドダウンロード
   a. Drive上のworld/が存在するか確認
      ├── 存在する → rcloneでダウンロード（world_sync.download_world()）
      └── 存在しない → 「新規ワールドです」と表示
   b. ダウンロード完了を確認

4. level.dat修正（nbt_editor.fix_level_dat()）
   - Data.Playerタグを削除

5. ユーザーに指示を表示
   ```
   準備完了！
   1. CurseForgeでATM10の「Play」を押してください
   2. ワールド「ATM10_Shared」を選択して開いてください
   3. Esc → Open to LAN → Start LAN World を押してください
   e4mcドメインを自動検出中...
   ```

6. ログ監視開始（log_watcher.watch_for_domain()）
   ├── ドメイン検出成功 → 続行
   └── タイムアウト → エラーメッセージ表示

7. ドメインをGASに書き込み
   - status_mgr.update_domain(domain)

8. ドメインをクリップボードにコピー
   - pyperclip.copy(domain)

9. 表示
   ```
   セッション開始！
   ドメイン: brave-sunset.sg.e4mc.link
   （クリップボードにコピーしました）
   Minecraftを閉じると自動的にワールドがアップロードされます。
   ```

10. Minecraftプロセス終了を待機（process_monitor.wait_for_exit()）

11. セッション終了処理
    a. 3秒待機（ファイル書き込み完了待ち）
    b. バックアップ作成（world_sync.create_backup()）
    c. ワールドアップロード（world_sync.upload_world()）
    d. ステータスをofflineに更新（status_mgr.set_offline()）
    e. 「セッション終了。ワールドをアップロードしました。」と表示
```

### 9.2 接続フロー

```
[2] 接続する が選択された

1. ステータスを確認（status_mgr.get_status()）
   ├── status == "online" かつ domain が空でない → 続行
   └── それ以外 → 「ホストがいません」表示→終了

2. ドメインを取得
   - domain = status["domain"]

3. servers.datにドメインを追加（nbt_editor.update_servers_dat()）
   - サーバー名: "ATM10 Session"
   - サーバーIP: domain

4. ドメインをクリップボードにコピー

5. 表示
   ```
   接続準備完了！
   ホスト: {host_name}
   ドメイン: {domain}
   （クリップボードにコピーしました）
   
   1. CurseForgeでATM10の「Play」を押してください
   2. マルチプレイ → サーバーリスト1番目の「ATM10 Session」をクリック
      または Direct Connect に貼り付けて接続
   ```
```

### 9.3 手動アップロード / ダウンロード

メニュー[3]と[4]は、デバッグやリカバリ用途。ロック確認なしで直接 upload_world() / download_world() を実行する。実行前に確認ダイアログ（y/n）を表示する。

---

## 10. エッジケース対策

### 10.1 ホストがクラッシュした場合

MinecraftやホストのPCがクラッシュし、アップロードが実行されずにロックが残る。

**対策:** ロックタイムスタンプ（A5）を使用し、lock_timeout_hours（デフォルト8時間）を超えたロックは期限切れと判断する。新しいホストはロックを上書きできる。確認プロンプトを表示する: 「前回のセッション（{host}、{start_time}）が正常に終了していない可能性があります。続行しますか？ (y/n)」

### 10.2 アップロード中にPCがシャットダウン

rclone syncは途中で中断しても、Drive上のファイルが壊れることはない（個々のファイルはアトミックに転送される）。次回のアップロードで差分が再送される。ただし途中状態のワールドがDrive上に存在するため、次のホストがダウンロードすると不整合が起きる可能性がある。

**対策:** アップロード前にバックアップを作成する。問題が起きたらバックアップから復元する手順をREADMEに記載する。

### 10.3 2人が同時にホストを開始

ステータスがofflineの状態で2人が同時にスクリプトを実行した場合。

**対策:** set_online()内で楽観的ロックを実装する。GAS側で書き込み後に `SpreadsheetApp.flush()` してから再読み取りし、自分のplayer_nameが書かれていなければ失敗とする。2〜3人の運用でミリ秒単位の競合はほぼ起きないが、万一でもデータ破損は起きない。

### 10.4 ワールドフォルダが存在しない（初回起動）

初回はDrive上にワールドがない。

**対策:** download_world()がリモートフォルダの不在を検出したらスキップし、「新規ワールドです」と表示する。ホストがCurseForgeで新しいワールドを作成してプレイし、終了後に自動アップロードされる。

### 10.5 latest.logが見つからない/e4mcドメインが出力されない

CurseForgeのインスタンスパスが間違っている、またはe4mcがインストールされていない場合。

**対策:** タイムアウト時に具体的なエラーメッセージを表示する。ログファイルが存在しない場合は「config.jsonのcurseforge_instance_pathを確認してください」、ファイルは存在するがドメインが出ない場合は「e4mcがインストールされているか確認してください。また、Open to LANを実行したか確認してください」と案内する。

### 10.6 Windowsのパス長制限

ATM10のModが生成するファイルパスが260文字を超える場合がある。

**対策:** READMEにWindows側の長いパス有効化手順を記載する。

### 10.7 ウイルス対策ソフトによるブロック

PyInstallerで生成したexeはWindows Defenderに誤検知される場合がある。

**対策:** READMEに除外設定の手順を記載する。または、exe化せずPythonスクリプトとして配布する選択肢も用意する。

### 10.8 GAS WebアプリのURL漏洩

URLを知っている第三者がステータスを操作できてしまう。

**対策:** GASのdoPost内で簡易パスワードチェックを追加する。config.jsonに `gas_secret` フィールドを設け、POSTリクエストに含める。GAS側で `params.secret !== "共有パスワード"` なら拒否する。完全なセキュリティではないが、2〜3人の個人利用では十分。

---

## 11. セットアップ手順（READMEに記載する内容）

### 11.1 事前準備（全員共通）

1. ATM10をCurseForgeでインストール済みであること
2. e4mc NeoForge版をATM10インスタンスのmodsフォルダに追加すること（ホスト側のみ必須。全員入れておいても問題ない）
3. ATM10にLogProtectionというModが含まれている場合、e4mcとの互換性問題が起きたら削除すること

### 11.2 Google Sheets + GAS セットアップ（1人が1回だけ実施）

1. Googleアカウントでログインし、Google Sheetsを新規作成
2. シート名を「status」に変更
3. A1セルに `offline` と入力
4. 「拡張機能」→「Apps Script」を開く
5. セクション6.2のGASコードを貼り付け
6. 「デプロイ」→「新しいデプロイ」→ 種類「ウェブアプリ」→ 実行ユーザー「自分」→ アクセスできるユーザー「全員」→ デプロイ
7. 発行されたURLを3人のconfig.jsonの `gas_url` に設定

### 11.3 Google Drive 共有フォルダ セットアップ（1人が1回だけ実施）

1. Google Driveに「ATM10_Shared」フォルダを作成
2. フォルダを右クリック → 共有 → 3人全員のGoogleアカウントに「編集者」権限を付与
3. フォルダのURLからフォルダIDを取得（URLの末尾の文字列）→ config.jsonの `rclone_drive_folder_id` に設定

### 11.4 OAuthクライアントID 作成（1人が1回だけ実施、5分）

rcloneのトークンを永続化するために必要。これをやらないと7日ごとに再認証が必要になる。

1. Google Cloud Console（https://console.cloud.google.com）にアクセス
2. プロジェクトを新規作成（名前は何でもよい）
3. 「APIとサービス」→「ライブラリ」→「Google Drive API」を検索して有効化
4. 「APIとサービス」→「OAuth同意画面」→ User Type「外部」→ 作成
5. アプリ名、ユーザーサポートメール、デベロッパー連絡先メールを入力（適当でよい）→ 保存して次へ
6. スコープの設定 → そのまま「保存して次へ」
7. テストユーザー → 3人のGmailアドレスを追加 → 保存して次へ
8. **重要:** 「OAuth同意画面」に戻り、「アプリを公開」ボタンを押す（検証は不要。公開するだけでトークンが永続化される）
9. 「APIとサービス」→「認証情報」→「認証情報を作成」→「OAuthクライアントID」
10. アプリケーションの種類: 「デスクトップアプリ」→ 作成
11. **クライアントID** と **クライアントシークレット** をコピー
12. この2つを3人に共有

### 11.5 rclone セットアップ（各自が実施）

1. 同梱のrclone.exeを使用
2. コマンドプロンプトを開き、rclone.exeのあるフォルダに移動
3. `rclone config` を実行
4. `n` → 新しいリモート → 名前: `gdrive` → ストレージ: `drive`
5. `client_id` に11.4で取得したクライアントIDを入力
6. `client_secret` にクライアントシークレットを入力
7. scope: `drive`（フルアクセス）を選択
8. 残りはデフォルトで進む → ブラウザが開く → Googleアカウントでログイン → 許可
9. 「This app isn't verified」と表示されたら「Advanced」→「Go to アプリ名 (unsafe)」→ 許可
10. 設定完了。生成されたrclone.confを本ツールのフォルダにコピー

### 11.6 config.json 設定（各自が実施）

1. config.json.example を config.json にコピー
2. 各フィールドを自分の環境に合わせて編集
   - curseforge_instance_path: CurseForgeでATM10を右クリック → Open Folder で開くパス
   - world_name: 全員で統一する名前（例: ATM10_Shared）
   - gas_url: 11.2で取得したGAS WebアプリURL
   - rclone_drive_folder_id: 11.3で取得したフォルダID
   - player_name: 自分のMinecraftプレイヤー名

---

## 12. テスト方針

### 12.1 単体テスト

| テスト対象 | テスト内容 |
|------------|------------|
| status_mgr | GASへのGET/POSTが正常動作すること。楽観的ロックが機能すること。リダイレクト対応が動作すること |
| world_sync | rclone sync が正常動作すること。空フォルダへの同期、差分同期の両方 |
| nbt_editor (level.dat) | Playerタグの削除が正常動作すること。Playerタグが存在しない場合にエラーにならないこと |
| nbt_editor (servers.dat) | サーバーの追加が正常動作すること。重複エントリの更新が動作すること。servers.datが存在しない場合に新規作成されること |
| log_watcher | e4mcドメインの検出が正常動作すること。タイムアウトが動作すること |
| process_monitor | Minecraftプロセスの検出と終了待機が動作すること |

### 12.2 統合テスト

| テストシナリオ | 手順 |
|----------------|------|
| ホスト開始→終了 | [1]選択→DL→MC起動→LAN公開→ドメイン検出→MC閉じる→UL→offline確認 |
| 接続 | 別ユーザーで[2]選択→servers.dat更新確認→MC起動→接続確認 |
| ホスト交代 | ユーザーAがホスト→終了→ユーザーBが[1]で開始→ワールド引き継ぎ→インベントリ正常 |
| ロックタイムアウト | ホスト中にスクリプト強制終了→ロック残留→タイムアウト後に別ユーザーがホスト開始可能 |
| 同時ホスト試行 | 2人が同時に[1]選択→1人だけ成功、もう1人にエラー表示 |

### 12.3 ATM10実機テスト

| テスト項目 | 確認内容 |
|------------|----------|
| e4mc動作確認 | ATM10でLAN公開→e4mcドメインがチャットに表示されること |
| 接続テスト | 別PCからe4mcドメインで接続できること |
| Mod干渉確認 | 接続後、各Modが正常動作すること |
| level.dat修正確認 | ホスト交代後、各プレイヤーのインベントリ・位置が正しいこと |

---

## 13. 配布形態

### 選択肢A: PyInstallerでexe化

- `pyinstaller --onefile main.py`
- hidden-imports: `nbtlib` 等、必要に応じて追加
- rclone.exe、config.json.exampleはexeと同じフォルダに配置
- rcloneライセンス表記（MITライセンス）を同梱

### 選択肢B: Pythonスクリプトとして配布

- 各自がPython 3.10以上をインストール
- `pip install requests nbtlib psutil pyperclip` を実行
- rcloneを同梱フォルダに配置
- `python main.py` で起動

### 推奨

まずは選択肢Bで開発・テストし、安定したら選択肢Aでexe化して配布する。

---

## 14. 技術検証済みの根拠

| 項目 | 検証結果 | 根拠 |
|------|----------|------|
| GAS Webアプリ | doGet/doPostでHTTP API化可能 | Google公式ドキュメント |
| GAS同時実行制限 | 30件/スクリプト（2〜3人で問題なし） | Google公式ドキュメント |
| Google Drive無料利用 | 1日750GBまでアップロード可能 | Google公式ドキュメント |
| rcloneライセンス | MITライセンス。バイナリ同梱・再配布OK | rclone.org/licence |
| rclone差分同期 | サイズ+更新日時で比較、変更ファイルのみ転送 | rclone公式ドキュメント |
| rclone OAuth永続化 | 自前クライアントIDで本番公開すれば永続 | rcloneフォーラム検証済み |
| nbtlibでlevel.dat編集 | gzip圧縮NBT対応 | nbtlib GitHub |
| nbtlibでservers.dat編集 | 非圧縮NBT対応 | Minecraft Wiki |
| e4mcドメインのログ形式 | `Local game hosted on domain [xxx.e4mc.link]` | e4mcソースコード確認済み |
| e4mc NeoForge対応 | v6.0.1（2026年2月） | CurseForge |
| psutilプロセス監視 | javaw.exeの検出・終了監視可能 | psutil公式ドキュメント |
| ATM10ワールドサイズ | 2〜5GB（進行度による） | Reddit r/allthemods |
| CurseForgeインスタンスパス | `C:\Users\<user>\curseforge\minecraft\Instances\<name>\` | CurseForge公式サポート |

---

## 15. 制限事項・注意事項

1. **セッション中のホスト切断は回避できない。** e4mcはホストのPC上でトンネルを張る仕組みであり、ホストが落ちれば全員切断される。本ツールが解決するのは「セッション間のホスト交代」と「ワールドの共有保存」。
2. **同時編集は不可。** 同時に2人がホストを立てるとワールドデータの競合が発生する。
3. **ネットワーク帯域に依存。** ワールドの初回ダウンロードは2〜5GB。
4. **e4mcのドメインはセッションごとに変わる。** GASステータス管理がこの問題を解決する。
5. **ATM10のアップデートでe4mc互換性が変わる可能性がある。** アップデート後は実機テストを行うこと。
6. **GAS WebアプリのURLは秘密にすること。** URLを知る人なら誰でもステータス操作可能。

---

## 16. v1からの変更点サマリー

| 項目 | v1 | v2 |
|------|----|----|
| ステータス管理 | gspread + サービスアカウント | **GAS Webアプリ + requests** |
| 認証情報 | credentials.json（3人に配布） | **GAS URL共有のみ** |
| Google Cloud Console | サービスアカウント作成+API有効化+JSONキー配布 | **OAuthクライアントID作成のみ（5分、1回）** |
| rclone認証 | サービスアカウント or 内蔵OAuth | **自前OAuthクライアントID（永続トークン）** |
| Python依存ライブラリ | gspread, google-auth, nbtlib, psutil, pyperclip | **requests, nbtlib, psutil, pyperclip** |
| credentials.json | 必要 | **不要** |
```

---

