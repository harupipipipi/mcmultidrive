#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# ディレクトリ作成
mkdir -p modules rclone

# --- config.json.example ---
cat > config.json.example << 'EOF'
{
  "curseforge_instance_path": "C:\\Users\\YourName\\curseforge\\minecraft\\Instances\\All the Mods 10",
  "world_name": "ATM10_Shared",
  "gas_url": "https://script.google.com/macros/s/XXXXXXXXXXXX/exec",
  "rclone_remote_name": "gdrive",
  "rclone_drive_folder_id": "1DEFxyz_your_folder_id_here",
  "rclone_exe_path": "./rclone/rclone.exe",
  "rclone_config_path": "./rclone.conf",
  "player_name": "MyPlayerName",
  "backup_generations": 5,
  "lock_timeout_hours": 8
}
EOF

# --- .gitignore ---
cat > .gitignore << 'EOF'
config.json
rclone.conf
rclone/rclone.exe
__pycache__/
modules/__pycache__/
*.pyc
*.pyo
*.egg-info/
dist/
build/
*.spec
EOF

# --- modules/__init__.py ---
cat > modules/__init__.py << 'EOF'
EOF

# --- modules/config_mgr.py ---
cat > modules/config_mgr.py << 'PYEOF'
"""config_mgr.py - 設定ファイル読み込み・バリデーション"""

import json
import os
import sys


REQUIRED_FIELDS = [
    "curseforge_instance_path",
    "world_name",
    "gas_url",
    "rclone_remote_name",
    "rclone_drive_folder_id",
    "rclone_exe_path",
    "rclone_config_path",
    "player_name",
    "backup_generations",
    "lock_timeout_hours",
]


def load_config(config_path: str = "config.json") -> dict:
    if not os.path.exists(config_path):
        print(f"[エラー] 設定ファイルが見つかりません: {config_path}")
        print("config.json.example を config.json にコピーして編集してください。")
        sys.exit(1)

    try:
        with open(config_path, "r", encoding="utf-8") as f:
            config = json.load(f)
    except json.JSONDecodeError as e:
        print(f"[エラー] config.json の JSON 形式が不正です: {e}")
        sys.exit(1)

    missing = [field for field in REQUIRED_FIELDS if field not in config]
    if missing:
        print(f"[エラー] config.json に以下のフィールドがありません: {', '.join(missing)}")
        sys.exit(1)

    str_fields = [
        "curseforge_instance_path", "world_name", "gas_url",
        "rclone_remote_name", "rclone_drive_folder_id",
        "rclone_exe_path", "rclone_config_path", "player_name",
    ]
    for field in str_fields:
        if not isinstance(config[field], str) or not config[field].strip():
            print(f"[エラー] config.json の {field} は空でない文字列である必要があります。")
            sys.exit(1)

    int_fields = ["backup_generations", "lock_timeout_hours"]
    for field in int_fields:
        if not isinstance(config[field], int) or config[field] < 1:
            print(f"[エラー] config.json の {field} は 1 以上の整数である必要があります。")
            sys.exit(1)

    instance_path = config["curseforge_instance_path"]
    if not os.path.isdir(instance_path):
        print(f"[警告] CurseForge インスタンスフォルダが見つかりません: {instance_path}")

    rclone_exe = config["rclone_exe_path"]
    if not os.path.isfile(rclone_exe):
        print(f"[警告] rclone.exe が見つかりません: {rclone_exe}")

    rclone_conf = config["rclone_config_path"]
    if not os.path.isfile(rclone_conf):
        print(f"[警告] rclone.conf が見つかりません: {rclone_conf}")

    return config


def print_config(config: dict) -> None:
    print("\n=== 現在の設定 ===")
    print(f"  インスタンスパス  : {config['curseforge_instance_path']}")
    print(f"  ワールド名       : {config['world_name']}")
    print(f"  GAS URL          : {config['gas_url'][:60]}...")
    print(f"  rclone リモート  : {config['rclone_remote_name']}")
    print(f"  Drive フォルダID : {config['rclone_drive_folder_id'][:20]}...")
    print(f"  プレイヤー名     : {config['player_name']}")
    print(f"  バックアップ世代 : {config['backup_generations']}")
    print(f"  ロックタイムアウト: {config['lock_timeout_hours']} 時間")
    print()
PYEOF

# --- modules/status_mgr.py ---
cat > modules/status_mgr.py << 'PYEOF'
"""status_mgr.py - GAS経由ステータス管理（HTTP GET/POST）"""

import json
from datetime import datetime, timezone

import requests


def get_status(gas_url: str) -> dict:
    try:
        resp = requests.get(gas_url, timeout=15)
        resp.raise_for_status()
        data = json.loads(resp.text)
        return data
    except Exception as e:
        print(f"[エラー] ステータス取得に失敗しました: {e}")
        return {"status": "error"}


def _post_to_gas(gas_url: str, payload: dict) -> dict:
    try:
        resp = requests.post(
            gas_url, json=payload, timeout=15, allow_redirects=True,
        )
        resp.raise_for_status()
        data = json.loads(resp.text)
        return data
    except Exception as e:
        print(f"[エラー] GAS通信に失敗しました: {e}")
        return {"success": False, "error": str(e)}


def set_online(gas_url: str, player_name: str, domain: str = "preparing...") -> bool:
    payload = {"action": "set_online", "host": player_name, "domain": domain}
    data = _post_to_gas(gas_url, payload)
    if data.get("success") and data.get("current_host") == player_name:
        return True
    if data.get("current_host") and data.get("current_host") != player_name:
        print(f"[情報] {data['current_host']} が先にホストを開始しました。")
    return False


def update_domain(gas_url: str, domain: str) -> bool:
    payload = {"action": "update_domain", "domain": domain}
    data = _post_to_gas(gas_url, payload)
    return data.get("success", False)


def set_offline(gas_url: str) -> bool:
    payload = {"action": "set_offline"}
    data = _post_to_gas(gas_url, payload)
    return data.get("success", False)


def is_lock_expired(lock_timestamp: str, timeout_hours: int) -> bool:
    if not lock_timestamp:
        return True
    try:
        ts_str = lock_timestamp.replace("Z", "+00:00")
        lock_time = datetime.fromisoformat(ts_str)
        if lock_time.tzinfo is None:
            lock_time = lock_time.replace(tzinfo=timezone.utc)
        now = datetime.now(timezone.utc)
        elapsed_hours = (now - lock_time).total_seconds() / 3600
        return elapsed_hours > timeout_hours
    except (ValueError, TypeError):
        return True
PYEOF

# --- modules/world_sync.py ---
cat > modules/world_sync.py << 'PYEOF'
"""world_sync.py - rclone によるワールド同期"""

import os
import subprocess
from datetime import datetime, timezone


def _run_rclone(config: dict, args: list[str], show_progress: bool = True) -> bool:
    rclone_exe = config["rclone_exe_path"]
    rclone_conf = config["rclone_config_path"]
    folder_id = config["rclone_drive_folder_id"]

    cmd = [
        rclone_exe, *args,
        "--config", rclone_conf,
        "--drive-root-folder-id", folder_id,
    ]
    if show_progress:
        cmd.append("--progress")

    print(f"[rclone] 実行中: {' '.join(cmd)}")

    try:
        result = subprocess.run(cmd, capture_output=not show_progress, text=True)
        if result.returncode != 0:
            if not show_progress and result.stderr:
                print(f"[rclone エラー] {result.stderr.strip()}")
            return False
        return True
    except FileNotFoundError:
        print(f"[エラー] rclone が見つかりません: {rclone_exe}")
        return False
    except Exception as e:
        print(f"[エラー] rclone 実行中にエラーが発生しました: {e}")
        return False


def check_remote_world_exists(config: dict) -> bool:
    rclone_exe = config["rclone_exe_path"]
    rclone_conf = config["rclone_config_path"]
    folder_id = config["rclone_drive_folder_id"]
    remote_name = config["rclone_remote_name"]

    cmd = [
        rclone_exe, "lsf", f"{remote_name}:world",
        "--config", rclone_conf,
        "--drive-root-folder-id", folder_id,
        "--max-depth", "1",
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return result.returncode == 0 and result.stdout.strip() != ""
    except Exception:
        return False


def download_world(config: dict) -> bool:
    instance_path = config["curseforge_instance_path"]
    world_name = config["world_name"]
    local_path = os.path.join(instance_path, "saves", world_name)
    os.makedirs(local_path, exist_ok=True)
    remote_name = config["rclone_remote_name"]
    remote_path = f"{remote_name}:world"
    print(f"\n[同期] ダウンロード中: Drive → {local_path}")
    return _run_rclone(config, ["sync", remote_path, local_path])


def upload_world(config: dict) -> bool:
    instance_path = config["curseforge_instance_path"]
    world_name = config["world_name"]
    local_path = os.path.join(instance_path, "saves", world_name)
    if not os.path.isdir(local_path):
        print(f"[エラー] ワールドフォルダが見つかりません: {local_path}")
        return False
    remote_name = config["rclone_remote_name"]
    remote_path = f"{remote_name}:world"
    print(f"\n[同期] アップロード中: {local_path} → Drive")
    return _run_rclone(config, ["sync", local_path, remote_path])


def create_backup(config: dict) -> bool:
    remote_name = config["rclone_remote_name"]
    backup_generations = config["backup_generations"]
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H%M%S")
    src = f"{remote_name}:world"
    dst = f"{remote_name}:backups/{timestamp}/world"
    print(f"\n[バックアップ] 作成中: backups/{timestamp}/world")
    success = _run_rclone(config, ["copy", src, dst], show_progress=False)
    if not success:
        print("[警告] バックアップの作成に失敗しました。アップロードは続行します。")
        return False
    _cleanup_old_backups(config, backup_generations)
    return True


def _cleanup_old_backups(config: dict, max_generations: int) -> None:
    rclone_exe = config["rclone_exe_path"]
    rclone_conf = config["rclone_config_path"]
    folder_id = config["rclone_drive_folder_id"]
    remote_name = config["rclone_remote_name"]

    cmd = [
        rclone_exe, "lsf", f"{remote_name}:backups",
        "--config", rclone_conf,
        "--drive-root-folder-id", folder_id,
        "--dirs-only", "--max-depth", "1",
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            return
        dirs = sorted([d.strip().rstrip("/") for d in result.stdout.strip().split("\n") if d.strip()])
        if len(dirs) <= max_generations:
            return
        dirs_to_delete = dirs[: len(dirs) - max_generations]
        for d in dirs_to_delete:
            print(f"[バックアップ] 古いバックアップを削除: backups/{d}")
            delete_cmd = [
                rclone_exe, "purge", f"{remote_name}:backups/{d}",
                "--config", rclone_conf,
                "--drive-root-folder-id", folder_id,
            ]
            subprocess.run(delete_cmd, capture_output=True, text=True, timeout=60)
    except Exception as e:
        print(f"[警告] バックアップのクリーンアップに失敗しました: {e}")
PYEOF

# --- modules/nbt_editor.py ---
cat > modules/nbt_editor.py << 'PYEOF'
"""nbt_editor.py - level.dat / servers.dat NBT編集"""

import os
import shutil

import nbtlib
from nbtlib.tag import Compound, List, String, Byte


def fix_level_dat(world_path: str) -> bool:
    level_dat_path = os.path.join(world_path, "level.dat")
    if not os.path.isfile(level_dat_path):
        print("[情報] level.dat が見つかりません（新規ワールドの可能性があります）。")
        return True
    try:
        backup_path = level_dat_path + ".bak"
        shutil.copy2(level_dat_path, backup_path)
        nbt_file = nbtlib.load(level_dat_path)
        if "Data" in nbt_file:
            data = nbt_file["Data"]
            if "Player" in data:
                del data["Player"]
                nbt_file.save()
                print("[NBT] level.dat から Player タグを削除しました。")
            else:
                print("[NBT] Player タグは存在しません（削除不要）。")
        else:
            print("[警告] level.dat に Data タグが見つかりません。")
        return True
    except Exception as e:
        print(f"[エラー] level.dat の編集に失敗しました: {e}")
        return False


def update_servers_dat(instance_path: str, server_ip: str, server_name: str = "ATM10 Session") -> bool:
    servers_dat_path = os.path.join(instance_path, "servers.dat")
    try:
        if os.path.isfile(servers_dat_path):
            nbt_file = nbtlib.load(servers_dat_path)
        else:
            nbt_file = nbtlib.File(
                {"servers": List[Compound]()}, gzipped=False,
            )
            nbt_file.filename = servers_dat_path

        if "servers" not in nbt_file:
            nbt_file["servers"] = List[Compound]()

        servers = nbt_file["servers"]

        existing_index = None
        for i, server in enumerate(servers):
            if "name" in server and str(server["name"]) == server_name:
                existing_index = i
                break

        new_entry = Compound({
            "name": String(server_name),
            "ip": String(server_ip),
            "acceptTextures": Byte(1),
        })

        if existing_index is not None:
            servers.pop(existing_index)

        servers.insert(0, new_entry)
        nbt_file.save(servers_dat_path, gzipped=False)
        print(f"[NBT] servers.dat を更新しました: {server_name} → {server_ip}")
        return True
    except Exception as e:
        print(f"[エラー] servers.dat の編集に失敗しました: {e}")
        return False
PYEOF

# --- modules/log_watcher.py ---
cat > modules/log_watcher.py << 'PYEOF'
"""log_watcher.py - latest.log 監視（e4mcドメイン取得）"""

import os
import re
import time

E4MC_DOMAIN_PATTERN = re.compile(
    r"Local game hosted on domain \[([^\]]+\.e4mc\.link)\]"
)


def watch_for_domain(log_path: str, timeout_seconds: int = 120) -> str | None:
    start_time = time.time()

    print("[ログ監視] latest.log を待機中...")
    while not os.path.isfile(log_path):
        if time.time() - start_time > timeout_seconds:
            print(f"[エラー] latest.log が見つかりません: {log_path}")
            print("config.json の curseforge_instance_path を確認してください。")
            return None
        time.sleep(1)

    print("[ログ監視] latest.log を検出。e4mc ドメインを監視中...")

    try:
        initial_size = os.path.getsize(log_path)
    except OSError:
        initial_size = 0

    last_read_pos = initial_size
    last_known_size = initial_size

    while True:
        if time.time() - start_time > timeout_seconds:
            print("[エラー] e4mc ドメインが検出できませんでした（タイムアウト）。")
            print("以下を確認してください:")
            print("  - e4mc Mod がインストールされているか")
            print("  - Esc → Open to LAN → Start LAN World を実行したか")
            return None

        try:
            if not os.path.isfile(log_path):
                last_read_pos = 0
                last_known_size = 0
                time.sleep(0.5)
                continue

            current_size = os.path.getsize(log_path)

            if current_size < last_known_size:
                last_read_pos = 0

            last_known_size = current_size

            if current_size <= last_read_pos:
                time.sleep(0.5)
                continue

            with open(log_path, "r", encoding="utf-8", errors="replace") as f:
                f.seek(last_read_pos)
                new_content = f.read()
                last_read_pos = f.tell()

            for line in new_content.splitlines():
                match = E4MC_DOMAIN_PATTERN.search(line)
                if match:
                    domain = match.group(1)
                    print(f"[ログ監視] e4mc ドメインを検出: {domain}")
                    return domain

        except OSError:
            pass

        time.sleep(0.5)
PYEOF

# --- modules/process_monitor.py ---
cat > modules/process_monitor.py << 'PYEOF'
"""process_monitor.py - Minecraftプロセス終了検知"""

import time

import psutil


def find_minecraft_process() -> int | None:
    try:
        for proc in psutil.process_iter(["pid", "name", "cmdline"]):
            try:
                name = proc.info["name"]
                if name and name.lower() in ("javaw.exe", "java.exe"):
                    cmdline = proc.info["cmdline"]
                    if cmdline:
                        cmdline_str = " ".join(cmdline).lower()
                        if "net.minecraft" in cmdline_str or "minecraft" in cmdline_str:
                            return proc.info["pid"]
            except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                continue
    except Exception as e:
        print(f"[警告] プロセス検索中にエラーが発生しました: {e}")
    return None


def wait_for_minecraft_start(timeout_seconds: int = 300, poll_interval: float = 3.0) -> int | None:
    start_time = time.time()
    while time.time() - start_time < timeout_seconds:
        pid = find_minecraft_process()
        if pid is not None:
            print(f"[プロセス] Minecraft を検出しました (PID: {pid})")
            return pid
        time.sleep(poll_interval)
    print("[エラー] Minecraft プロセスが検出できませんでした（タイムアウト）。")
    return None


def wait_for_exit(pid: int, poll_interval: float = 3.0) -> None:
    print(f"[プロセス] Minecraft の終了を待機中 (PID: {pid})...")
    while True:
        try:
            proc = psutil.Process(pid)
            if not proc.is_running() or proc.status() == psutil.STATUS_ZOMBIE:
                break
        except psutil.NoSuchProcess:
            break
        time.sleep(poll_interval)
    print("[プロセス] Minecraft が終了しました。")
    print("[プロセス] ファイル書き込み完了待ち（3秒）...")
    time.sleep(3)
PYEOF

# --- main.py ---
cat > main.py << 'PYEOF'
"""ATM10 Session Manager — エントリポイント"""

import os
import sys
import time

try:
    import pyperclip
except ImportError:
    pyperclip = None

from modules.config_mgr import load_config, print_config
from modules.status_mgr import get_status, set_online, update_domain, set_offline, is_lock_expired
from modules.world_sync import download_world, upload_world, create_backup, check_remote_world_exists
from modules.nbt_editor import fix_level_dat, update_servers_dat
from modules.log_watcher import watch_for_domain
from modules.process_monitor import find_minecraft_process, wait_for_exit


def clipboard_copy(text: str) -> None:
    if pyperclip:
        try:
            pyperclip.copy(text)
            print("（クリップボードにコピーしました）")
        except Exception:
            print("（クリップボードへのコピーに失敗しました）")
    else:
        print("（pyperclip 未インストールのため、クリップボードコピーはスキップ）")


def show_menu(status_info: dict) -> str:
    print("\n=== ATM10 Session Manager ===")
    status = status_info.get("status", "error")
    if status == "online":
        host = status_info.get("host", "不明")
        domain = status_info.get("domain", "")
        print(f"現在のステータス: オンライン（ホスト: {host}）")
        if domain and domain != "preparing...":
            print(f"ドメイン: {domain}")
        elif domain == "preparing...":
            print("ドメイン: 準備中...")
    elif status == "offline":
        print("現在のステータス: オフライン")
    else:
        print("現在のステータス: 取得失敗")
    print()
    print("[1] ホストとして開始（ワールドDL → LAN公開 → 自動管理）")
    print("[2] 接続する（既存セッションに参加）")
    print("[3] ワールドを手動アップロード")
    print("[4] ワールドを手動ダウンロード")
    print("[5] 設定確認")
    print("[0] 終了")
    print()
    return input("選択 > ").strip()


def host_flow(config: dict) -> None:
    gas_url = config["gas_url"]
    player_name = config["player_name"]
    instance_path = config["curseforge_instance_path"]
    world_name = config["world_name"]
    lock_timeout = config["lock_timeout_hours"]

    print("\n[ステータス] 現在の状態を確認中...")
    status_info = get_status(gas_url)
    status = status_info.get("status", "error")

    if status == "error":
        print("[エラー] ステータスを取得できませんでした。ネットワーク接続を確認してください。")
        return

    if status == "online":
        host = status_info.get("host", "不明")
        lock_ts = status_info.get("lock_timestamp", "")
        if is_lock_expired(lock_ts, lock_timeout):
            print(f"\n[警告] 前回のセッション（ホスト: {host}）が正常に終了していない可能性があります。")
            print(f"       ロックは {lock_timeout} 時間を超えて期限切れです。")
            confirm = input("続行しますか？ (y/n) > ").strip().lower()
            if confirm != "y":
                print("キャンセルしました。")
                return
        else:
            print(f"\n[情報] 現在 {host} がホスト中です。")
            print("セッションが終了するまでお待ちください。")
            return

    print("\n[ロック] ホスト権限を取得中...")
    if not set_online(gas_url, player_name):
        print("[エラー] ホスト権限を取得できませんでした。他の人が先に開始した可能性があります。")
        return

    print(f"[ロック] ホスト権限を取得しました（プレイヤー: {player_name}）")

    try:
        if check_remote_world_exists(config):
            print("\n[同期] Drive からワールドをダウンロードします...")
            if not download_world(config):
                print("[エラー] ワールドのダウンロードに失敗しました。")
                set_offline(gas_url)
                return
            print("[同期] ダウンロード完了！")
        else:
            print("\n[情報] Drive 上にワールドデータがありません（新規ワールド）。")
            print("       Minecraft でワールドを新規作成してください。")

        world_path = os.path.join(instance_path, "saves", world_name)
        if os.path.isdir(world_path):
            print("\n[NBT] level.dat を修正中...")
            fix_level_dat(world_path)

        print("\n" + "=" * 50)
        print("準備完了！")
        print("=" * 50)
        print()
        print("以下の手順を実行してください:")
        print(f"  1. CurseForge で ATM10 の「Play」を押してください")
        print(f"  2. ワールド「{world_name}」を選択して開いてください")
        print(f"  3. Esc → Open to LAN → Start LAN World を押してください")
        print()
        print("e4mc ドメインを自動検出中...")
        print()

        log_path = os.path.join(instance_path, "logs", "latest.log")
        domain = watch_for_domain(log_path, timeout_seconds=600)

        if not domain:
            print("\n[エラー] e4mc ドメインが検出できませんでした。")
            print("手動でセッションを管理してください。")
            print("Minecraft を閉じた後、メニュー [3] で手動アップロードを実行してください。")
            confirm = input("\nMinecraft の終了を待機して自動アップロードしますか？ (y/n) > ").strip().lower()
            if confirm != "y":
                set_offline(gas_url)
                return
        else:
            print("\n[ステータス] ドメインを更新中...")
            update_domain(gas_url, domain)
            print()
            print("=" * 50)
            print("セッション開始！")
            print("=" * 50)
            print(f"ドメイン: {domain}")
            clipboard_copy(domain)
            print()
            print("Minecraft を閉じると自動的にワールドがアップロードされます。")
            print("このウィンドウは閉じないでください。")
            print()

        print("[プロセス] Minecraft プロセスを検索中...")
        pid = None
        for _ in range(60):
            pid = find_minecraft_process()
            if pid:
                break
            time.sleep(3)

        if pid:
            wait_for_exit(pid)
        else:
            print("[警告] Minecraft プロセスが見つかりませんでした。")
            input("Minecraft を閉じたら Enter を押してください > ")

        print("\n[終了処理] セッション終了処理を開始します...")
        print("[終了処理] バックアップを作成中...")
        create_backup(config)

        print("[終了処理] ワールドをアップロード中...")
        if upload_world(config):
            print("[終了処理] アップロード完了！")
        else:
            print("[エラー] アップロードに失敗しました。")
            print("メニュー [3] で手動アップロードを試してください。")

        set_offline(gas_url)
        print()
        print("=" * 50)
        print("セッション終了。ワールドをアップロードしました。")
        print("=" * 50)

    except KeyboardInterrupt:
        print("\n\n[中断] Ctrl+C が押されました。")
        print("[中断] ステータスをオフラインに設定します...")
        set_offline(gas_url)
        print("[中断] 完了。ワールドはアップロードされていません。")
        print("       必要に応じてメニュー [3] で手動アップロードしてください。")

    except Exception as e:
        print(f"\n[エラー] 予期しないエラーが発生しました: {e}")
        print("[エラー] ステータスをオフラインに設定します...")
        set_offline(gas_url)


def join_flow(config: dict) -> None:
    gas_url = config["gas_url"]
    instance_path = config["curseforge_instance_path"]

    print("\n[ステータス] 現在の状態を確認中...")
    status_info = get_status(gas_url)
    status = status_info.get("status", "error")

    if status != "online":
        print("\n[情報] 現在ホストがいません。")
        print("ホストが「ホストとして開始」を実行するまでお待ちください。")
        return

    domain = status_info.get("domain", "")
    host = status_info.get("host", "不明")

    if not domain or domain == "preparing...":
        print(f"\n[情報] {host} がホストを準備中です。")
        print("もう少しお待ちください（LAN公開が完了するまで）。")
        return

    print(f"\n[NBT] servers.dat を更新中...")
    update_servers_dat(instance_path, domain, "ATM10 Session")

    print()
    print("=" * 50)
    print("接続準備完了！")
    print("=" * 50)
    print(f"ホスト  : {host}")
    print(f"ドメイン: {domain}")
    clipboard_copy(domain)
    print()
    print("以下の手順を実行してください:")
    print("  1. CurseForge で ATM10 の「Play」を押してください")
    print("  2. マルチプレイ → サーバーリスト1番目の「ATM10 Session」をクリック")
    print("     または Direct Connect にドメインを貼り付けて接続")
    print()


def manual_upload(config: dict) -> None:
    print("\n[手動アップロード] ローカルのワールドを Drive にアップロードします。")
    print("[警告] Drive 上のワールドが上書きされます。")
    confirm = input("続行しますか？ (y/n) > ").strip().lower()
    if confirm != "y":
        print("キャンセルしました。")
        return
    print("\n[バックアップ] アップロード前にバックアップを作成します...")
    create_backup(config)
    if upload_world(config):
        print("\n[完了] アップロードが完了しました。")
    else:
        print("\n[エラー] アップロードに失敗しました。")


def manual_download(config: dict) -> None:
    instance_path = config["curseforge_instance_path"]
    world_name = config["world_name"]
    local_path = os.path.join(instance_path, "saves", world_name)
    print("\n[手動ダウンロード] Drive のワールドをローカルにダウンロードします。")
    if os.path.isdir(local_path):
        print(f"[警告] ローカルのワールドフォルダが上書きされます: {local_path}")
    confirm = input("続行しますか？ (y/n) > ").strip().lower()
    if confirm != "y":
        print("キャンセルしました。")
        return
    if download_world(config):
        print("\n[完了] ダウンロードが完了しました。")
    else:
        print("\n[エラー] ダウンロードに失敗しました。")


def main() -> None:
    config = load_config()
    while True:
        status_info = get_status(config["gas_url"])
        choice = show_menu(status_info)
        if choice == "1":
            host_flow(config)
            input("\nEnter を押してメニューに戻ります > ")
        elif choice == "2":
            join_flow(config)
            input("\nEnter を押してメニューに戻ります > ")
        elif choice == "3":
            manual_upload(config)
            input("\nEnter を押してメニューに戻ります > ")
        elif choice == "4":
            manual_download(config)
            input("\nEnter を押してメニューに戻ります > ")
        elif choice == "5":
            print_config(config)
            input("\nEnter を押してメニューに戻ります > ")
        elif choice == "0":
            print("終了します。")
            break
        else:
            print("無効な選択です。")


if __name__ == "__main__":
    main()
PYEOF

# --- requirements.txt ---
cat > requirements.txt << 'EOF'
requests
nbtlib
psutil
pyperclip
EOF

echo ""
echo "=== ファイル生成完了 ==="
echo ""

# Git add, commit, push
git add -A
git commit -m "feat: ATM10 Session Manager 初回実装

- main.py: CUIメニュー、ホストフロー、接続フロー、手動UL/DL
- modules/config_mgr.py: config.json読み込み・バリデーション
- modules/status_mgr.py: GAS経由ステータス管理
- modules/world_sync.py: rclone差分同期・バックアップ
- modules/nbt_editor.py: level.dat Player削除、servers.dat更新
- modules/log_watcher.py: e4mcドメイン自動検出
- modules/process_monitor.py: Minecraftプロセス監視
- config.json.example: 設定テンプレート
- requirements.txt: Python依存ライブラリ
- .gitignore: 秘密情報・ビルド成果物除外"

git push origin HEAD

echo ""
echo "=== push 完了 ==="
