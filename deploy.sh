
#!/usr/bin/env bash
set -euo pipefail
#
# MC MultiDrive v2 — deploy.sh
# 実行すると全ファイルを生成し、git commit & push する
#
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== MC MultiDrive v2 デプロイ開始 ==="

# ── ディレクトリ準備 ─────────────────────────────
mkdir -p modules
mkdir -p gas

# ── .gitignore ───────────────────────────────────
cat > .gitignore << 'GITIGNORE_EOF'
my_settings.json
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
.venv/
MCMultiDrive.exe
config.json
GITIGNORE_EOF
echo "[生成] .gitignore"

# ── requirements.txt ─────────────────────────────
cat > requirements.txt << 'REQ_EOF'
FreeSimpleGUI
requests
nbtlib
psutil
pyperclip
REQ_EOF
echo "[生成] requirements.txt"

# ── shared_config.json ───────────────────────────
cat > shared_config.json << 'SHARED_EOF'
{
  "gas_url": "https://script.google.com/macros/s/YOUR_GAS_DEPLOYMENT_ID/exec",
  "rclone_remote_name": "gdrive",
  "rclone_drive_folder_id": "YOUR_GOOGLE_DRIVE_FOLDER_ID",
  "backup_generations": 5,
  "lock_timeout_hours": 8
}
SHARED_EOF
echo "[生成] shared_config.json"

# ── modules/__init__.py ──────────────────────────
cat > modules/__init__.py << 'INIT_EOF'
INIT_EOF
echo "[生成] modules/__init__.py"

# ── modules/config_mgr.py ────────────────────────
cat > modules/config_mgr.py << 'CONFIGMGR_EOF'
"""config_mgr.py - 複数ワールド対応の設定管理"""

import json
import os
import sys

SHARED_FIELDS = [
    "gas_url", "rclone_remote_name", "rclone_drive_folder_id",
    "backup_generations", "lock_timeout_hours",
]


def _find_base() -> str:
    if getattr(sys, 'frozen', False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# ── shared_config.json (全員共通) ─────────────────

def load_shared(base: str = None) -> dict:
    if base is None:
        base = _find_base()
    path = os.path.join(base, "shared_config.json")
    if not os.path.exists(path):
        raise FileNotFoundError(f"shared_config.json が見つかりません: {path}")
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    missing = [k for k in SHARED_FIELDS if k not in data]
    if missing:
        raise ValueError(f"shared_config.json にフィールドがありません: {', '.join(missing)}")
    return data


# ── my_settings.json (個人設定) ───────────────────

def load_personal(base: str = None) -> dict | None:
    if base is None:
        base = _find_base()
    path = os.path.join(base, "my_settings.json")
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if "player_name" not in data:
        return None
    if "instance_paths" not in data:
        data["instance_paths"] = {}
    return data


def save_personal(player_name: str, instance_paths: dict = None,
                  base: str = None) -> str:
    if base is None:
        base = _find_base()
    path = os.path.join(base, "my_settings.json")
    existing = load_personal(base)
    if instance_paths is None:
        instance_paths = existing["instance_paths"] if existing else {}
    data = {
        "player_name": player_name,
        "instance_paths": instance_paths,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    return path


def set_instance_path(world_name: str, path: str, base: str = None) -> None:
    if base is None:
        base = _find_base()
    personal = load_personal(base)
    if personal is None:
        return
    personal["instance_paths"][world_name] = path
    save_personal(personal["player_name"], personal["instance_paths"], base)


def get_instance_path(world_name: str, base: str = None) -> str | None:
    if base is None:
        base = _find_base()
    personal = load_personal(base)
    if personal is None:
        return None
    return personal.get("instance_paths", {}).get(world_name)


# ── 統合 config 生成 ──────────────────────────────

def build_config(world_name: str, base: str = None) -> dict | None:
    if base is None:
        base = _find_base()
    try:
        shared = load_shared(base)
    except (FileNotFoundError, ValueError):
        return None
    personal = load_personal(base)
    if personal is None:
        return None
    instance_path = personal.get("instance_paths", {}).get(world_name)
    config = {}
    config.update(shared)
    config["player_name"] = personal["player_name"]
    config["world_name"] = world_name
    config["curseforge_instance_path"] = instance_path or ""
    config["rclone_exe_path"] = os.path.join(base, "rclone", "rclone.exe")
    config["rclone_config_path"] = os.path.join(base, "rclone.conf")
    return config
CONFIGMGR_EOF
echo "[生成] modules/config_mgr.py"

# ── modules/status_mgr.py ────────────────────────
cat > modules/status_mgr.py << 'STATUSMGR_EOF'
"""status_mgr.py - GAS経由ステータス管理（複数ワールド対応）"""

import json
from datetime import datetime, timezone

import requests


def _get(gas_url: str, params: dict) -> dict:
    try:
        resp = requests.get(gas_url, params=params, timeout=15)
        resp.raise_for_status()
        return json.loads(resp.text)
    except Exception as e:
        print(f"[エラー] GAS GET 失敗: {e}")
        return {"error": str(e)}


def _post(gas_url: str, payload: dict) -> dict:
    try:
        resp = requests.post(
            gas_url, json=payload, timeout=15, allow_redirects=True,
        )
        resp.raise_for_status()
        return json.loads(resp.text)
    except Exception as e:
        print(f"[エラー] GAS POST 失敗: {e}")
        return {"success": False, "error": str(e)}


# ── 読み取り系 ─────────────────────────────────────

def list_worlds(gas_url: str) -> list[dict]:
    data = _get(gas_url, {"action": "list_worlds"})
    return data.get("worlds", [])


def get_status(gas_url: str, world_name: str) -> dict:
    data = _get(gas_url, {"action": "get_status", "world": world_name})
    return data


# ── 書き込み系 ─────────────────────────────────────

def set_online(gas_url: str, world_name: str, player_name: str,
               domain: str = "preparing...") -> bool:
    payload = {
        "action": "set_online",
        "world": world_name,
        "host": player_name,
        "domain": domain,
    }
    data = _post(gas_url, payload)
    if data.get("success") and data.get("current_host") == player_name:
        return True
    if data.get("current_host") and data.get("current_host") != player_name:
        print(f"[情報] {data['current_host']} が先にホストを開始しました。")
    return False


def update_domain(gas_url: str, world_name: str, domain: str) -> bool:
    payload = {"action": "update_domain", "world": world_name, "domain": domain}
    data = _post(gas_url, payload)
    return data.get("success", False)


def set_offline(gas_url: str, world_name: str) -> bool:
    payload = {"action": "set_offline", "world": world_name}
    data = _post(gas_url, payload)
    return data.get("success", False)


def add_world(gas_url: str, world_name: str) -> bool:
    payload = {"action": "add_world", "world": world_name}
    data = _post(gas_url, payload)
    return data.get("success", False)


# ── ロック判定 ──────────────────────────────────────

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
STATUSMGR_EOF
echo "[生成] modules/status_mgr.py"

# ── modules/world_sync.py ────────────────────────
cat > modules/world_sync.py << 'WORLDSYNC_EOF'
"""world_sync.py - rclone によるワールド同期（複数ワールド対応）"""

import os
import subprocess
from datetime import datetime, timezone


def _run_rclone(config: dict, args: list[str],
                show_progress: bool = True) -> bool:
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
        result = subprocess.run(
            cmd, capture_output=not show_progress, text=True,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0,
        )
        if result.returncode != 0:
            if not show_progress and result.stderr:
                print(f"[rclone エラー] {result.stderr.strip()}")
            return False
        return True
    except FileNotFoundError:
        print(f"[エラー] rclone が見つかりません: {rclone_exe}")
        return False
    except Exception as e:
        print(f"[エラー] rclone 実行中にエラー: {e}")
        return False


def check_remote_world_exists(config: dict) -> bool:
    rclone_exe = config["rclone_exe_path"]
    rclone_conf = config["rclone_config_path"]
    folder_id = config["rclone_drive_folder_id"]
    remote_name = config["rclone_remote_name"]
    world_name = config["world_name"]

    cmd = [
        rclone_exe, "lsf", f"{remote_name}:worlds/{world_name}",
        "--config", rclone_conf,
        "--drive-root-folder-id", folder_id,
        "--max-depth", "1",
    ]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0,
        )
        return result.returncode == 0 and result.stdout.strip() != ""
    except Exception:
        return False


def download_world(config: dict) -> bool:
    instance_path = config["curseforge_instance_path"]
    world_name = config["world_name"]
    remote_name = config["rclone_remote_name"]

    local_path = os.path.join(instance_path, "saves", world_name)
    os.makedirs(local_path, exist_ok=True)
    remote_path = f"{remote_name}:worlds/{world_name}"

    print(f"\n[同期] ダウンロード中: Drive → {local_path}")
    return _run_rclone(config, ["sync", remote_path, local_path])


def upload_world(config: dict) -> bool:
    instance_path = config["curseforge_instance_path"]
    world_name = config["world_name"]
    remote_name = config["rclone_remote_name"]

    local_path = os.path.join(instance_path, "saves", world_name)
    if not os.path.isdir(local_path):
        print(f"[エラー] ワールドフォルダが見つかりません: {local_path}")
        return False
    remote_path = f"{remote_name}:worlds/{world_name}"

    print(f"\n[同期] アップロード中: {local_path} → Drive")
    return _run_rclone(config, ["sync", local_path, remote_path])


def create_backup(config: dict) -> bool:
    remote_name = config["rclone_remote_name"]
    world_name = config["world_name"]
    backup_generations = config["backup_generations"]

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H%M%S")
    src = f"{remote_name}:worlds/{world_name}"
    dst = f"{remote_name}:backups/{world_name}/{timestamp}"

    print(f"\n[バックアップ] 作成中: backups/{world_name}/{timestamp}")
    success = _run_rclone(config, ["copy", src, dst], show_progress=False)
    if not success:
        print("[警告] バックアップの作成に失敗しました。")
        return False
    _cleanup_old_backups(config, backup_generations)
    return True


def _cleanup_old_backups(config: dict, max_generations: int) -> None:
    rclone_exe = config["rclone_exe_path"]
    rclone_conf = config["rclone_config_path"]
    folder_id = config["rclone_drive_folder_id"]
    remote_name = config["rclone_remote_name"]
    world_name = config["world_name"]

    cmd = [
        rclone_exe, "lsf", f"{remote_name}:backups/{world_name}",
        "--config", rclone_conf,
        "--drive-root-folder-id", folder_id,
        "--dirs-only", "--max-depth", "1",
    ]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0,
        )
        if result.returncode != 0:
            return
        dirs = sorted([
            d.strip().rstrip("/")
            for d in result.stdout.strip().split("\n") if d.strip()
        ])
        if len(dirs) <= max_generations:
            return
        dirs_to_delete = dirs[: len(dirs) - max_generations]
        for d in dirs_to_delete:
            print(f"[バックアップ] 古いバックアップを削除: backups/{world_name}/{d}")
            delete_cmd = [
                rclone_exe, "purge",
                f"{remote_name}:backups/{world_name}/{d}",
                "--config", rclone_conf,
                "--drive-root-folder-id", folder_id,
            ]
            subprocess.run(
                delete_cmd, capture_output=True, text=True, timeout=60,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0,
            )
    except Exception as e:
        print(f"[警告] バックアップのクリーンアップに失敗: {e}")
WORLDSYNC_EOF
echo "[生成] modules/world_sync.py"

# ── modules/nbt_editor.py ────────────────────────
cat > modules/nbt_editor.py << 'NBTEDITOR_EOF'
"""nbt_editor.py - level.dat / servers.dat NBT編集"""

import os
import shutil

import nbtlib
from nbtlib.tag import Compound, List, String, Byte


def fix_level_dat(world_path: str) -> bool:
    level_dat_path = os.path.join(world_path, "level.dat")
    if not os.path.isfile(level_dat_path):
        print("[情報] level.dat が見つかりません（新規ワールドの可能性）。")
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


def update_servers_dat(instance_path: str, server_ip: str,
                       server_name: str = "MC MultiDrive Session") -> bool:
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
NBTEDITOR_EOF
echo "[生成] modules/nbt_editor.py"

# ── modules/log_watcher.py ───────────────────────
cat > modules/log_watcher.py << 'LOGWATCHER_EOF'
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
LOGWATCHER_EOF
echo "[生成] modules/log_watcher.py"

# ── modules/process_monitor.py ───────────────────
cat > modules/process_monitor.py << 'PROCESSMON_EOF'
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
            except (psutil.NoSuchProcess, psutil.AccessDenied,
                    psutil.ZombieProcess):
                continue
    except Exception as e:
        print(f"[警告] プロセス検索中にエラー: {e}")
    return None


def wait_for_minecraft_start(timeout_seconds: int = 300,
                             poll_interval: float = 3.0) -> int | None:
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
PROCESSMON_EOF
echo "[生成] modules/process_monitor.py"

# ── main.py ──────────────────────────────────────
cat > main.py << 'MAINPY_EOF'
"""MC MultiDrive — 複数ワールド対応セッションマネージャ (GUI)"""

import os
import sys
import time
import threading
import subprocess
import platform

try:
    import pyperclip
except ImportError:
    pyperclip = None

import FreeSimpleGUI as sg

from modules.config_mgr import (
    _find_base, load_shared, load_personal, save_personal,
    set_instance_path, get_instance_path, build_config,
)
from modules.status_mgr import (
    list_worlds, get_status, set_online, update_domain,
    set_offline, add_world, is_lock_expired,
)
from modules.world_sync import (
    download_world, upload_world, create_backup, check_remote_world_exists,
)
from modules.nbt_editor import fix_level_dat, update_servers_dat
from modules.log_watcher import watch_for_domain
from modules.process_monitor import find_minecraft_process, wait_for_exit


# ─── テーマ ──────────────────────────────────────
sg.theme("DarkBlue3")

# ─── ユーティリティ ──────────────────────────────

def _clipboard_copy(text: str) -> None:
    if pyperclip:
        try:
            pyperclip.copy(text)
        except Exception:
            pass


def _open_folder(path: str) -> None:
    if not os.path.isdir(path):
        sg.popup_error(f"フォルダが見つかりません:\n{path}", title="エラー")
        return
    if platform.system() == "Windows":
        os.startfile(path)
    elif platform.system() == "Darwin":
        subprocess.Popen(["open", path])
    else:
        subprocess.Popen(["xdg-open", path])


# ─── stdout → GUI 転送 ──────────────────────────

class _GUIWriter:
    def __init__(self, window: sg.Window):
        self._window = window
        self._original = sys.stdout

    def write(self, text: str) -> None:
        if text.strip():
            try:
                self._window.write_event_value("-PRINT-", text)
            except Exception:
                pass
        if self._original:
            self._original.write(text)

    def flush(self) -> None:
        if self._original:
            self._original.flush()


# ─── 初回セットアップ ────────────────────────────

def _run_setup(base: str) -> dict | None:
    personal = load_personal(base)
    default_name = personal["player_name"] if personal else ""

    layout = [
        [sg.Text("MC MultiDrive - 初回セットアップ",
                 font=("Helvetica", 16, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("Minecraft のプレイヤー名を入力してください:")],
        [sg.Input(default_name, key="-NAME-", size=(40, 1))],
        [sg.Text("")],
        [sg.Button("開始", key="-SAVE-", size=(15, 1)),
         sg.Button("キャンセル", key="-CANCEL-", size=(10, 1))],
    ]

    win = sg.Window("MC MultiDrive - セットアップ", layout,
                    finalize=True, modal=True)

    result = None
    while True:
        event, values = win.read()
        if event in (sg.WIN_CLOSED, "-CANCEL-"):
            break
        if event == "-SAVE-":
            name = values["-NAME-"].strip()
            if not name:
                sg.popup_error("プレイヤー名を入力してください。",
                               title="エラー")
                continue
            save_personal(name, base=base)
            result = {"player_name": name}
            break

    win.close()
    return result


# ─── インスタンスパス要求ダイアログ ──────────────

def _ask_instance_path(world_name: str) -> str | None:
    layout = [
        [sg.Text(f"ワールド「{world_name}」のインスタンスフォルダを選択",
                 font=("Helvetica", 12, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("CurseForge でこのModpackを右クリック →\n"
                 "Open Folder で開くフォルダと同じものを選んでください。",
                 font=("Helvetica", 9))],
        [sg.Text("")],
        [sg.Input(key="-PATH-", size=(45, 1)),
         sg.FolderBrowse("選択", target="-PATH-")],
        [sg.Text("")],
        [sg.Button("OK", key="-OK-", size=(10, 1)),
         sg.Button("キャンセル", key="-CANCEL-", size=(10, 1))],
    ]
    win = sg.Window(f"インスタンスフォルダ - {world_name}", layout,
                    finalize=True, modal=True)
    result = None
    while True:
        event, values = win.read()
        if event in (sg.WIN_CLOSED, "-CANCEL-"):
            break
        if event == "-OK-":
            p = values["-PATH-"].strip()
            if not p or not os.path.isdir(p):
                sg.popup_error("有効なフォルダを選択してください。",
                               title="エラー")
                continue
            result = p
            break
    win.close()
    return result


# ─── 新規ワールド追加ダイアログ ──────────────────

def _ask_new_world(gas_url: str, base: str) -> str | None:
    layout = [
        [sg.Text("新しいワールドを追加",
                 font=("Helvetica", 12, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("ワールド名（全員共通の名前）:")],
        [sg.Input(key="-WNAME-", size=(40, 1))],
        [sg.Text("例: ATM10, Vanilla_1.21, Create",
                 font=("Helvetica", 9))],
        [sg.Text("")],
        [sg.Button("追加", key="-ADD-", size=(10, 1)),
         sg.Button("キャンセル", key="-CANCEL-", size=(10, 1))],
    ]
    win = sg.Window("ワールド追加", layout, finalize=True, modal=True)
    result = None
    while True:
        event, values = win.read()
        if event in (sg.WIN_CLOSED, "-CANCEL-"):
            break
        if event == "-ADD-":
            wname = values["-WNAME-"].strip()
            if not wname:
                sg.popup_error("ワールド名を入力してください。",
                               title="エラー")
                continue
            if not add_world(gas_url, wname):
                sg.popup_error("ワールドの追加に失敗しました。",
                               title="エラー")
                continue
            result = wname
            break
    win.close()
    return result


# ─── 設定画面 ────────────────────────────────────

def _show_settings(base: str, worlds: list[dict]) -> None:
    personal = load_personal(base)
    if not personal:
        return
    player_name = personal["player_name"]
    instance_paths = personal.get("instance_paths", {})

    rows = []
    rows.append([sg.Text("プレイヤー名:"),
                 sg.Input(player_name, key="-SNAME-", size=(30, 1))])
    rows.append([sg.HorizontalSeparator()])
    rows.append([sg.Text("ワールド別インスタンスパス:",
                         font=("Helvetica", 10, "bold"))])

    world_names = [w.get("world_name", "") for w in worlds]
    for wn in world_names:
        cur = instance_paths.get(wn, "")
        rows.append([
            sg.Text(f"  {wn}:", size=(18, 1)),
            sg.Input(cur, key=f"-SP-{wn}-", size=(30, 1)),
            sg.FolderBrowse("選択", target=f"-SP-{wn}-"),
        ])

    layout = [
        [sg.Text("設定", font=("Helvetica", 14, "bold"))],
        [sg.HorizontalSeparator()],
        *rows,
        [sg.Text("")],
        [sg.Button("保存", key="-SSAVE-", size=(10, 1)),
         sg.Button("閉じる", key="-SCLOSE-", size=(10, 1))],
    ]

    win = sg.Window("設定", layout, finalize=True, modal=True)
    while True:
        event, values = win.read()
        if event in (sg.WIN_CLOSED, "-SCLOSE-"):
            break
        if event == "-SSAVE-":
            new_name = values["-SNAME-"].strip()
            if not new_name:
                sg.popup_error("プレイヤー名を入力してください。",
                               title="エラー")
                continue
            new_paths = {}
            for wn in world_names:
                p = values.get(f"-SP-{wn}-", "").strip()
                if p:
                    new_paths[wn] = p
            # 既存のパス（上記リストにないワールド）を保持
            for k, v in instance_paths.items():
                if k not in new_paths and v:
                    new_paths[k] = v
            save_personal(new_name, new_paths, base)
            sg.popup("設定を保存しました。", title="保存完了")
            break
    win.close()


# ─── ワールドリスト表示文字列 ────────────────────

def _world_display(w: dict) -> str:
    name = w.get("world_name", "???")
    st = w.get("status", "offline")
    if st == "online":
        host = w.get("host", "")
        return f"[ON]  {name}  (host: {host})"
    return f"[--]  {name}"


# ─── メインレイアウト ────────────────────────────

def _make_layout(worlds: list[dict], player_name: str) -> list:
    world_items = [_world_display(w) for w in worlds]

    left_col = [
        [sg.Text("ワールド一覧", font=("Helvetica", 10, "bold"))],
        [sg.Listbox(world_items, size=(32, 12), key="-WLIST-",
                    enable_events=True, font=("Consolas", 10))],
        [sg.Button("+ 新規追加", key="-ADD-WORLD-", size=(14, 1))],
    ]

    right_col = [
        [sg.Text("詳細", font=("Helvetica", 10, "bold"))],
        [sg.Text("ワールド:", size=(10, 1)),
         sg.Text("---", key="-D-NAME-", size=(25, 1),
                 font=("Helvetica", 10, "bold"))],
        [sg.Text("ステータス:", size=(10, 1)),
         sg.Text("---", key="-D-STATUS-", size=(25, 1))],
        [sg.Text("ホスト:", size=(10, 1)),
         sg.Text("---", key="-D-HOST-", size=(25, 1))],
        [sg.Text("ドメイン:", size=(10, 1)),
         sg.Text("---", key="-D-DOMAIN-", size=(25, 1))],
        [sg.Text("")],
        [sg.Button("ホストする", key="-HOST-", size=(12, 1)),
         sg.Button("接続する", key="-JOIN-", size=(12, 1))],
        [sg.Button("ドメインコピー", key="-COPY-DOMAIN-", size=(12, 1)),
         sg.Button("savesを開く", key="-OPEN-SAVES-", size=(12, 1))],
        [sg.Button("手動UL", key="-UPLOAD-", size=(12, 1)),
         sg.Button("手動DL", key="-DOWNLOAD-", size=(12, 1))],
    ]

    layout = [
        [sg.Text("MC MultiDrive", font=("Helvetica", 18, "bold")),
         sg.Push(),
         sg.Text(f"プレイヤー: {player_name}",
                 font=("Helvetica", 10))],
        [sg.HorizontalSeparator()],
        [sg.Column(left_col, vertical_alignment="top"),
         sg.VSeperator(),
         sg.Column(right_col, vertical_alignment="top")],
        [sg.HorizontalSeparator()],
        [sg.Text("ログ:", font=("Helvetica", 10, "bold"))],
        [sg.Multiline(size=(72, 10), key="-LOG-", autoscroll=True,
                      disabled=True, font=("Consolas", 9))],
        [sg.Button("更新", key="-REFRESH-", size=(8, 1)),
         sg.Button("設定", key="-SETTINGS-", size=(8, 1)),
         sg.Push(),
         sg.Button("終了", key="-EXIT-", size=(8, 1))],
    ]
    return layout


# ─── ログ書き込み ────────────────────────────────

def _log(window: sg.Window, msg: str) -> None:
    window["-LOG-"].update(msg + "\n", append=True)
    window.refresh()


# ─── 選択中ワールド取得 ──────────────────────────

def _selected_world(window: sg.Window, worlds: list[dict]) -> dict | None:
    sel = window["-WLIST-"].get()
    if not sel:
        return None
    sel_text = sel[0]
    for w in worlds:
        if _world_display(w) == sel_text:
            return w
    return None


def _selected_world_name(window: sg.Window, worlds: list[dict]) -> str | None:
    w = _selected_world(window, worlds)
    return w.get("world_name") if w else None


# ─── 詳細パネル更新 ──────────────────────────────

def _update_detail(window: sg.Window, w: dict | None) -> None:
    if w is None:
        window["-D-NAME-"].update("---")
        window["-D-STATUS-"].update("---")
        window["-D-HOST-"].update("---")
        window["-D-DOMAIN-"].update("---")
        return
    window["-D-NAME-"].update(w.get("world_name", "---"))
    st = w.get("status", "offline")
    if st == "online":
        window["-D-STATUS-"].update("オンライン")
        window["-D-HOST-"].update(w.get("host", "---"))
        domain = w.get("domain", "")
        if domain and domain != "preparing...":
            window["-D-DOMAIN-"].update(domain)
        elif domain == "preparing...":
            window["-D-DOMAIN-"].update("準備中...")
        else:
            window["-D-DOMAIN-"].update("---")
    else:
        window["-D-STATUS-"].update("オフライン")
        window["-D-HOST-"].update("---")
        window["-D-DOMAIN-"].update("---")


# ─── インスタンスパス確保 ────────────────────────

def _ensure_instance_path(world_name: str, base: str) -> str | None:
    p = get_instance_path(world_name, base)
    if p and os.path.isdir(p):
        return p
    p = _ask_instance_path(world_name)
    if p:
        set_instance_path(world_name, p, base)
    return p


# ─── ホスト処理（バックグラウンドスレッド） ──────

def _host_thread(window: sg.Window, config: dict) -> None:
    gas_url = config["gas_url"]
    player_name = config["player_name"]
    instance_path = config["curseforge_instance_path"]
    world_name = config["world_name"]
    lock_timeout = config["lock_timeout_hours"]

    def send(msg):
        window.write_event_value("-PRINT-", msg)

    try:
        send(f"[{world_name}] ステータスを確認中...")
        status_info = get_status(gas_url, world_name)
        status = status_info.get("status", "error")

        if status == "error":
            send(f"[{world_name}] ステータスを取得できませんでした。")
            window.write_event_value("-HOST-DONE-", False)
            return

        if status == "online":
            host = status_info.get("host", "不明")
            lock_ts = status_info.get("lock_timestamp", "")
            if is_lock_expired(lock_ts, lock_timeout):
                window.write_event_value("-HOST-LOCK-EXPIRED-",
                                         {"world": world_name, "host": host})
                return
            else:
                send(f"[{world_name}] 現在 {host} がホスト中です。")
                window.write_event_value("-HOST-DONE-", False)
                return

        send(f"[{world_name}] ホスト権限を取得中...")
        if not set_online(gas_url, world_name, player_name):
            send(f"[{world_name}] ホスト権限を取得できませんでした。")
            window.write_event_value("-HOST-DONE-", False)
            return
        send(f"[{world_name}] ホスト取得成功（{player_name}）")

        if check_remote_world_exists(config):
            send(f"[{world_name}] ワールドをダウンロード中...")
            if not download_world(config):
                send(f"[{world_name}] ダウンロード失敗。")
                set_offline(gas_url, world_name)
                window.write_event_value("-HOST-DONE-", False)
                return
            send(f"[{world_name}] ダウンロード完了！")
        else:
            send(f"[{world_name}] Drive上にワールドデータなし（新規）。")

        world_path = os.path.join(instance_path, "saves", world_name)
        if os.path.isdir(world_path):
            send(f"[{world_name}] level.dat を修正中...")
            fix_level_dat(world_path)

        send("=" * 50)
        send("準備完了！")
        send(f"  1. CurseForge で Modpack の Play を押す")
        send(f"  2. ワールド「{world_name}」を開く")
        send(f"  3. Esc → Open to LAN → Start LAN World")
        send("=" * 50)
        send("e4mc ドメインを自動検出中...")

        log_path = os.path.join(instance_path, "logs", "latest.log")
        domain = watch_for_domain(log_path, timeout_seconds=600)

        if domain:
            send(f"[ドメイン検出] {domain}")
            update_domain(gas_url, world_name, domain)
            _clipboard_copy(domain)
            send(f"ドメインをクリップボードにコピーしました。")
        else:
            send("[警告] e4mc ドメインが検出できませんでした。")

        send("Minecraft の終了を待機中...")
        pid = find_minecraft_process()
        if pid:
            wait_for_exit(pid)
        else:
            send("[情報] Minecraft プロセスが見つかりません。手動ULしてください。")
            window.write_event_value("-HOST-DONE-", True)
            return

        send(f"[{world_name}] バックアップ作成中...")
        create_backup(config)

        send(f"[{world_name}] アップロード中...")
        if upload_world(config):
            send(f"[{world_name}] アップロード完了！")
        else:
            send(f"[{world_name}] アップロード失敗。")

        set_offline(gas_url, world_name)
        send(f"[{world_name}] セッション終了。ステータスをオフラインに更新しました。")
        window.write_event_value("-HOST-DONE-", True)

    except Exception as e:
        send(f"[エラー] ホスト処理中に例外: {e}")
        try:
            set_offline(gas_url, world_name)
        except Exception:
            pass
        window.write_event_value("-HOST-DONE-", False)


# ─── メインループ ────────────────────────────────

def main():
    base = _find_base()

    # shared_config.json チェック
    try:
        shared = load_shared(base)
    except (FileNotFoundError, ValueError) as e:
        sg.popup_error(
            f"共有設定ファイルのエラー:\n{e}\n\n"
            "shared_config.json が exe と同じフォルダにあるか確認してください。",
            title="起動エラー",
        )
        return

    gas_url = shared["gas_url"]

    # 初回セットアップ
    personal = load_personal(base)
    if personal is None:
        result = _run_setup(base)
        if result is None:
            return
        personal = load_personal(base)
        if personal is None:
            return

    player_name = personal["player_name"]

    # ワールド一覧取得
    worlds = list_worlds(gas_url)
    if not worlds:
        worlds = []

    # メインウィンドウ
    window = sg.Window(
        "MC MultiDrive",
        _make_layout(worlds, player_name),
        finalize=True,
    )

    sys.stdout = _GUIWriter(window)
    hosting = False

    while True:
        event, values = window.read(timeout=100)

        if event in (sg.WIN_CLOSED, "-EXIT-"):
            break

        # ─── stdout からのログ転送 ─────────────
        if event == "-PRINT-":
            _log(window, values["-PRINT-"])

        # ─── ワールド選択 ─────────────────────
        if event == "-WLIST-":
            w = _selected_world(window, worlds)
            _update_detail(window, w)

        # ─── ステータス更新 ───────────────────
        if event == "-REFRESH-":
            _log(window, "[更新] ステータスを取得中...")
            worlds = list_worlds(gas_url)
            sel_name = _selected_world_name(window, worlds)
            items = [_world_display(w) for w in worlds]
            window["-WLIST-"].update(items)
            # 選択を復元
            if sel_name:
                for i, w in enumerate(worlds):
                    if w.get("world_name") == sel_name:
                        window["-WLIST-"].update(
                            set_to_index=[i])
                        _update_detail(window, w)
                        break
            _log(window, f"[更新] {len(worlds)} 個のワールドを取得しました。")

        # ─── ワールド追加 ─────────────────────
        if event == "-ADD-WORLD-":
            wname = _ask_new_world(gas_url, base)
            if wname:
                _log(window, f"[追加] ワールド「{wname}」を追加しました。")
                worlds = list_worlds(gas_url)
                items = [_world_display(w) for w in worlds]
                window["-WLIST-"].update(items)

        # ─── ホスト ───────────────────────────
        if event == "-HOST-":
            if hosting:
                sg.popup("既にホスト処理が実行中です。", title="情報")
                continue
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを選択してください。", title="情報")
                continue
            inst = _ensure_instance_path(wname, base)
            if not inst:
                continue
            config = build_config(wname, base)
            if not config:
                sg.popup_error("設定の構築に失敗しました。", title="エラー")
                continue
            hosting = True
            threading.Thread(
                target=_host_thread, args=(window, config),
                daemon=True,
            ).start()

        if event == "-HOST-DONE-":
            hosting = False
            # 自動で更新
            worlds = list_worlds(gas_url)
            items = [_world_display(w) for w in worlds]
            window["-WLIST-"].update(items)

        if event == "-HOST-LOCK-EXPIRED-":
            info = values["-HOST-LOCK-EXPIRED-"]
            wn = info["world"]
            old_host = info["host"]
            ans = sg.popup_yes_no(
                f"ワールド「{wn}」のロックが期限切れです。\n"
                f"（前回ホスト: {old_host}）\n\n"
                "強制的にホストを引き継ぎますか？",
                title="ロック期限切れ",
            )
            if ans == "Yes":
                config = build_config(wn, base)
                if config:
                    set_offline(gas_url, wn)
                    hosting = True
                    threading.Thread(
                        target=_host_thread, args=(window, config),
                        daemon=True,
                    ).start()
            else:
                hosting = False

        # ─── 接続 ────────────────────────────
        if event == "-JOIN-":
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを選択してください。", title="情報")
                continue
            w = _selected_world(window, worlds)
            if not w or w.get("status") != "online":
                sg.popup("このワールドはオフラインです。", title="情報")
                continue
            domain = w.get("domain", "")
            if not domain or domain == "preparing...":
                sg.popup("ドメインがまだ準備中です。少し待ってから更新してください。",
                         title="情報")
                continue
            inst = _ensure_instance_path(wname, base)
            if inst:
                server_label = f"MC MultiDrive - {wname}"
                update_servers_dat(inst, domain, server_label)
            _clipboard_copy(domain)
            _log(window, f"[接続] {domain} をクリップボードにコピーしました。")
            sg.popup(
                f"ドメインをコピーしました:\n{domain}\n\n"
                "CurseForge で Play → マルチプレイから接続してください。",
                title="接続情報",
            )

        # ─── ドメインコピー ───────────────────
        if event == "-COPY-DOMAIN-":
            w = _selected_world(window, worlds)
            if w and w.get("domain") and w["domain"] != "preparing...":
                _clipboard_copy(w["domain"])
                _log(window, f"[コピー] {w['domain']}")
            else:
                sg.popup("コピーできるドメインがありません。", title="情報")

        # ─── saves を開く ─────────────────────
        if event == "-OPEN-SAVES-":
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを選択してください。", title="情報")
                continue
            inst = get_instance_path(wname, base)
            if inst:
                saves_path = os.path.join(inst, "saves")
                if os.path.isdir(saves_path):
                    _open_folder(saves_path)
                else:
                    sg.popup(f"saves フォルダが見つかりません:\n{saves_path}",
                             title="エラー")
            else:
                sg.popup("インスタンスパスが未設定です。\n"
                         "設定画面で設定してください。", title="情報")

        # ─── 手動アップロード ─────────────────
        if event == "-UPLOAD-":
            if hosting:
                sg.popup("ホスト処理中はアップロードできません。",
                         title="情報")
                continue
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを選択してください。", title="情報")
                continue
            inst = _ensure_instance_path(wname, base)
            if not inst:
                continue
            ans = sg.popup_yes_no(
                f"ワールド「{wname}」を Google Drive にアップロードしますか？\n"
                "Drive 上のデータは上書きされます。",
                title="手動アップロード確認",
            )
            if ans == "Yes":
                config = build_config(wname, base)
                if config:
                    _log(window, f"[手動UL] {wname} アップロード中...")
                    threading.Thread(
                        target=lambda: (
                            upload_world(config),
                            window.write_event_value("-REFRESH-", None),
                        ),
                        daemon=True,
                    ).start()

        # ─── 手動ダウンロード ─────────────────
        if event == "-DOWNLOAD-":
            if hosting:
                sg.popup("ホスト処理中はダウンロードできません。",
                         title="情報")
                continue
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを選択してください。", title="情報")
                continue
            inst = _ensure_instance_path(wname, base)
            if not inst:
                continue
            ans = sg.popup_yes_no(
                f"ワールド「{wname}」を Google Drive からダウンロードしますか？\n"
                "ローカルのデータは上書きされます。",
                title="手動ダウンロード確認",
            )
            if ans == "Yes":
                config = build_config(wname, base)
                if config:
                    _log(window, f"[手動DL] {wname} ダウンロード中...")
                    threading.Thread(
                        target=lambda: (
                            download_world(config),
                            window.write_event_value("-REFRESH-", None),
                        ),
                        daemon=True,
                    ).start()

        # ─── 設定 ────────────────────────────
        if event == "-SETTINGS-":
            _show_settings(base, worlds)
            personal = load_personal(base)
            if personal:
                player_name = personal["player_name"]

    window.close()


if __name__ == "__main__":
    main()
MAINPY_EOF
echo "[生成] main.py"

# ── gas/code.gs ──────────────────────────────────
cat > gas/code.gs << 'GASEOF'
/**
 * MC MultiDrive — Google Apps Script (複数ワールド対応)
 *
 * スプレッドシートに "status" シートを作成し、このスクリプトを
 * ウェブアプリとしてデプロイしてください。
 *
 * status シート構成:
 *   A列: world_name
 *   B列: status (online / offline)
 *   C列: host
 *   D列: domain
 *   E列: lock_timestamp (UTC ISO8601)
 */

function getSheet() {
  return SpreadsheetApp.getActiveSpreadsheet().getSheetByName("status");
}

function findRow(sheet, worldName) {
  var data = sheet.getDataRange().getValues();
  for (var i = 0; i < data.length; i++) {
    if (data[i][0] === worldName) {
      return i + 1; // 1-indexed
    }
  }
  return -1;
}

function jsonResponse(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

// ─── GET ─────────────────────────────────────────

function doGet(e) {
  var action = (e.parameter.action || "list_worlds");
  var sheet = getSheet();

  if (action === "list_worlds") {
    return listWorlds(sheet);
  }
  if (action === "get_status") {
    return getStatus(sheet, e.parameter.world || "");
  }

  return jsonResponse({error: "unknown action"});
}

function listWorlds(sheet) {
  var data = sheet.getDataRange().getValues();
  var worlds = [];
  for (var i = 0; i < data.length; i++) {
    if (!data[i][0]) continue;
    worlds.push({
      world_name:     data[i][0],
      status:         data[i][1] || "offline",
      host:           data[i][2] || "",
      domain:         data[i][3] || "",
      lock_timestamp: data[i][4] || "",
    });
  }
  return jsonResponse({worlds: worlds});
}

function getStatus(sheet, worldName) {
  var row = findRow(sheet, worldName);
  if (row === -1) {
    return jsonResponse({status: "not_found"});
  }
  var vals = sheet.getRange(row, 1, 1, 5).getValues()[0];
  return jsonResponse({
    world_name:     vals[0],
    status:         vals[1] || "offline",
    host:           vals[2] || "",
    domain:         vals[3] || "",
    lock_timestamp: vals[4] || "",
  });
}

// ─── POST ────────────────────────────────────────

function doPost(e) {
  var data = JSON.parse(e.postData.contents);
  var sheet = getSheet();
  var action = data.action || "";

  switch (action) {
    case "set_online":
      return setOnline(sheet, data);
    case "set_offline":
      return setOffline(sheet, data);
    case "update_domain":
      return updateDomain(sheet, data);
    case "add_world":
      return addWorld(sheet, data);
    default:
      return jsonResponse({success: false, error: "unknown action"});
  }
}

function setOnline(sheet, data) {
  var world = data.world || "";
  var host  = data.host  || "";
  var domain = data.domain || "preparing...";

  if (!world || !host) {
    return jsonResponse({success: false, error: "missing world or host"});
  }

  var row = findRow(sheet, world);
  if (row === -1) {
    return jsonResponse({success: false, error: "world not found"});
  }

  var currentStatus = sheet.getRange(row, 2).getValue();
  var currentHost   = sheet.getRange(row, 3).getValue();

  if (currentStatus === "online" && currentHost && currentHost !== host) {
    return jsonResponse({
      success: false,
      current_host: currentHost,
      error: "already hosted by " + currentHost,
    });
  }

  var now = new Date().toISOString();
  sheet.getRange(row, 2).setValue("online");
  sheet.getRange(row, 3).setValue(host);
  sheet.getRange(row, 4).setValue(domain);
  sheet.getRange(row, 5).setValue(now);

  return jsonResponse({success: true, current_host: host});
}

function setOffline(sheet, data) {
  var world = data.world || "";
  if (!world) {
    return jsonResponse({success: false, error: "missing world"});
  }

  var row = findRow(sheet, world);
  if (row === -1) {
    return jsonResponse({success: false, error: "world not found"});
  }

  sheet.getRange(row, 2).setValue("offline");
  sheet.getRange(row, 3).setValue("");
  sheet.getRange(row, 4).setValue("");
  sheet.getRange(row, 5).setValue("");

  return jsonResponse({success: true});
}

function updateDomain(sheet, data) {
  var world  = data.world  || "";
  var domain = data.domain || "";

  if (!world) {
    return jsonResponse({success: false, error: "missing world"});
  }

  var row = findRow(sheet, world);
  if (row === -1) {
    return jsonResponse({success: false, error: "world not found"});
  }

  sheet.getRange(row, 4).setValue(domain);
  return jsonResponse({success: true});
}

function addWorld(sheet, data) {
  var world = data.world || "";
  if (!world) {
    return jsonResponse({success: false, error: "missing world"});
  }

  var row = findRow(sheet, world);
  if (row !== -1) {
    return jsonResponse({success: true, message: "already exists"});
  }

  var lastRow = sheet.getLastRow();
  sheet.getRange(lastRow + 1, 1).setValue(world);
  sheet.getRange(lastRow + 1, 2).setValue("offline");

  return jsonResponse({success: true});
}
GASEOF
echo "[生成] gas/code.gs"

# ── build.bat ────────────────────────────────────
cat > build.bat << 'BUILDBAT_EOF'
@echo off
echo === MC MultiDrive ビルド ===
echo.

pip install pyinstaller FreeSimpleGUI requests nbtlib psutil pyperclip

pyinstaller --onefile --noconsole --name MCMultiDrive main.py --hidden-import=nbtlib --hidden-import=FreeSimpleGUI

echo.
echo === ビルド完了 ===
echo dist\MCMultiDrive.exe が生成されました。
echo.
echo 配布フォルダを作成します...

if not exist "dist\release" mkdir "dist\release"
copy dist\MCMultiDrive.exe dist\release\
copy shared_config.json dist\release\
if not exist "dist\release\rclone" mkdir "dist\release\rclone"
if exist "rclone\rclone.exe" copy rclone\rclone.exe dist\release\rclone\
if exist "rclone.conf" copy rclone.conf dist\release\

echo.
echo === dist\release フォルダの中身を配布してください ===
echo 各自が rclone.conf を追加する必要はありません（同梱済み）。
pause
BUILDBAT_EOF
echo "[生成] build.bat"

# ── README.md ────────────────────────────────────
cat > README.md << 'README_EOF'
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
README_EOF
echo "[生成] README.md"

# ── 不要ファイルの削除 ───────────────────────────
rm -f config.json.example 2>/dev/null || true
rm -f project.md 2>/dev/null || true

# ── Git commit & push ────────────────────────────
echo ""
echo "=== Git コミット & プッシュ ==="

git add -A
git commit -m "v2: 複数ワールド対応、GUI刷新、GAS複数管理、rclone同梱配布

- 複数ワールド管理（ATM10, Vanilla, Create 等を1つのツールで）
- GAS: 1スプレッドシートで複数ワールドのステータスを行ベース管理
- GUI: ダッシュボード型（ワールド一覧 + 詳細パネル + ログ）
- 初回セットアップ簡略化（プレイヤー名を入れるだけ）
- ワールド追加: 誰でもGUIからワンクリック追加
- rclone.conf 同梱配布（管理者のみセットアップ）
- インスタンスパスは初回使用時にGUIで選択
- shared_config.json の簡略化
- gas/code.gs 追加（GASスクリプト同梱）
- README.md 全面書き直し"

git push origin main

echo ""
echo "=== デプロイ完了 ==="
echo "次のステップ:"
echo "  1. shared_config.json の gas_url と rclone_drive_folder_id を記入"
echo "  2. rclone/rclone.exe を配置"
echo "  3. rclone config でGoogle Driveを設定し rclone.conf を配置"
echo "  4. gas/code.gs をGoogle Sheetsのスクリプトエディタに貼り付けてデプロイ"
echo "  5. build.bat でexeをビルド"
echo "  6. dist/release/ を友達に配布"
