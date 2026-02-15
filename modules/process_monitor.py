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
