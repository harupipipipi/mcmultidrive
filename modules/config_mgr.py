"""config_mgr.py - 共有設定 + 個人設定の読み込み・バリデーション"""

import json
import os
import sys


SHARED_FIELDS = [
    "gas_url", "rclone_remote_name", "rclone_drive_folder_id",
    "world_name", "backup_generations", "lock_timeout_hours",
]
PERSONAL_FIELDS = ["player_name", "curseforge_instance_path"]


def _find_base() -> str:
    if getattr(sys, 'frozen', False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


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


def load_personal(base: str = None) -> dict | None:
    if base is None:
        base = _find_base()
    path = os.path.join(base, "my_settings.json")
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    missing = [k for k in PERSONAL_FIELDS if k not in data]
    if missing:
        return None
    return data


def save_personal(player_name: str, instance_path: str, base: str = None) -> str:
    if base is None:
        base = _find_base()
    path = os.path.join(base, "my_settings.json")
    data = {
        "player_name": player_name,
        "curseforge_instance_path": instance_path,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    return path


def build_config(base: str = None) -> dict:
    if base is None:
        base = _find_base()
    shared = load_shared(base)
    personal = load_personal(base)
    if personal is None:
        return None
    config = {}
    config.update(shared)
    config.update(personal)
    config["rclone_exe_path"] = os.path.join(base, "rclone", "rclone.exe")
    config["rclone_config_path"] = os.path.join(base, "rclone.conf")
    return config


def print_config(config: dict) -> str:
    return (
        f"インスタンスパス : {config.get('curseforge_instance_path','')}\n"
        f"ワールド名      : {config.get('world_name','')}\n"
        f"GAS URL         : {config.get('gas_url','')[:60]}...\n"
        f"rclone リモート : {config.get('rclone_remote_name','')}\n"
        f"Drive フォルダID: {config.get('rclone_drive_folder_id','')[:20]}...\n"
        f"プレイヤー名    : {config.get('player_name','')}\n"
        f"バックアップ世代: {config.get('backup_generations','')}\n"
        f"ロックタイムアウト: {config.get('lock_timeout_hours','')} 時間"
    )
