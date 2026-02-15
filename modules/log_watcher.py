"""log_watcher.py - latest.log監視（e4mcドメイン検出）"""

import os
import re
import time

# e4mcドメイン検出パターン（優先順位順）
E4MC_DOMAIN_PATTERNS = [
    re.compile(r"Domain assigned:\s*([\w.-]+\.e4mc\.link)"),
    re.compile(r"Local game hosted on domain \[([\w.-]+\.e4mc\.link)\]"),
    re.compile(r"([\w.-]+\.e4mc\.link)"),
]


def watch_for_domain(log_path: str, timeout_seconds: int = 600) -> str | None:
    start_time = time.time()

    print("[ログ] latest.logを待機中...")
    while not os.path.isfile(log_path):
        if time.time() - start_time > timeout_seconds:
            print(f"[エラー] latest.logが見つかりません: {log_path}")
            return None
        time.sleep(1)

    print("[ログ] latest.logを検出。e4mcドメインを監視中...")

    try:
        initial_size = os.path.getsize(log_path)
    except OSError:
        initial_size = 0

    last_read_pos = initial_size
    last_known_size = initial_size

    while True:
        if time.time() - start_time > timeout_seconds:
            print("[エラー] e4mcドメインが検出されませんでした（タイムアウト）。")
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
                for pattern in E4MC_DOMAIN_PATTERNS:
                    match = pattern.search(line)
                    if match:
                        domain = match.group(1)
                        print(f"[ログ] e4mcドメインを検出: {domain}")
                        return domain

        except OSError:
            pass

        time.sleep(0.5)
