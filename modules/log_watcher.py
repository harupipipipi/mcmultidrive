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
