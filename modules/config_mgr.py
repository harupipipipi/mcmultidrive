"""config_mgr.py - マルチワールド設定管理"""

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


# -- shared_config.json（共有設定）--

def load_shared(base: str = None) -> dict:
    if base is None:
        base = _find_base()
    path = os.path.join(base, "shared_config.json")
    if not os.path.exists(path):
        raise FileNotFoundError(f"shared_config.jsonが見つかりません: {path}")
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    missing = [k for k in SHARED_FIELDS if k not in data]
    if missing:
        raise ValueError(f"shared_config.jsonに必須フィールドがありません: {', '.join(missing)}")
    return data


# -- my_settings.json（個人設定）--

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


# -- マージされた設定の構築 --

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
