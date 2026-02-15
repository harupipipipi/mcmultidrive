"""process_monitor.py - Minecraftプロセス検出"""

import time

import psutil

_MC_PROC_NAMES = ("javaw.exe", "java.exe", "java", "javaw", "minecraft.exe")
_MC_CMDLINE_KEYWORDS = (
    "net.minecraft",
    "minecraft",
    "cpw.mods.bootstraplauncher",
    "net.minecraftforge",
    "net.neoforged",
    "fabricmc",
)


def find_minecraft_process() -> int | None:
    try:
        for proc in psutil.process_iter(["pid", "name", "cmdline"]):
            try:
                name = proc.info["name"]
                if not name:
                    continue
                if name.lower() in _MC_PROC_NAMES:
                    cmdline = proc.info["cmdline"]
                    if cmdline:
                        cmdline_str = " ".join(cmdline).lower()
                        if any(kw in cmdline_str for kw in _MC_CMDLINE_KEYWORDS):
                            return proc.info["pid"]
            except (psutil.NoSuchProcess, psutil.AccessDenied,
                    psutil.ZombieProcess):
                continue
    except Exception as e:
        print(f"[警告] プロセス検索エラー: {e}")
    return None


def wait_for_minecraft_start(timeout_seconds: int = 300,
                             poll_interval: float = 3.0) -> int | None:
    start_time = time.time()
    while time.time() - start_time < timeout_seconds:
        pid = find_minecraft_process()
        if pid is not None:
            print(f"[プロセス] Minecraft検出 (PID: {pid})")
            return pid
        time.sleep(poll_interval)
    print("[エラー] Minecraftプロセスが検出されませんでした（タイムアウト）。")
    return None


def wait_for_exit(pid: int, poll_interval: float = 3.0) -> None:
    print(f"[プロセス] Minecraftの終了を待機中 (PID: {pid})...")
    while True:
        try:
            proc = psutil.Process(pid)
            if not proc.is_running() or proc.status() == psutil.STATUS_ZOMBIE:
                break
        except psutil.NoSuchProcess:
            break
        time.sleep(poll_interval)
    print("[プロセス] Minecraftが終了しました。")
    print("[プロセス] ファイル書き込みを待機中 (3秒)...")
    time.sleep(3)
