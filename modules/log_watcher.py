"""log_watcher.py - latest.log watcher (e4mc domain detection)"""

import os
import re
import time

# e4mc domain detection patterns (priority order)
E4MC_DOMAIN_PATTERNS = [
    re.compile(r"Domain assigned:\s*([\w.-]+\.e4mc\.link)"),
    re.compile(r"Local game hosted on domain \[([\w.-]+\.e4mc\.link)\]"),
    re.compile(r"([\w.-]+\.e4mc\.link)"),
]


def watch_for_domain(log_path: str, timeout_seconds: int = 600) -> str | None:
    start_time = time.time()

    print("[log] waiting for latest.log...")
    while not os.path.isfile(log_path):
        if time.time() - start_time > timeout_seconds:
            print(f"[error] latest.log not found: {log_path}")
            return None
        time.sleep(1)

    print("[log] latest.log found. watching for e4mc domain...")

    try:
        initial_size = os.path.getsize(log_path)
    except OSError:
        initial_size = 0

    last_read_pos = initial_size
    last_known_size = initial_size

    while True:
        if time.time() - start_time > timeout_seconds:
            print("[error] e4mc domain not detected (timeout).")
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
                        print(f"[log] e4mc domain detected: {domain}")
                        return domain

        except OSError:
            pass

        time.sleep(0.5)
