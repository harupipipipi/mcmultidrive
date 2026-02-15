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
