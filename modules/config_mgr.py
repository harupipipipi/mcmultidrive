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
