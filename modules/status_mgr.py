"""status_mgr.py - GAS経由ステータス管理（HTTP GET/POST）"""

import json
from datetime import datetime, timezone

import requests


def get_status(gas_url: str) -> dict:
    try:
        resp = requests.get(gas_url, timeout=15)
        resp.raise_for_status()
        data = json.loads(resp.text)
        return data
    except Exception as e:
        print(f"[エラー] ステータス取得に失敗しました: {e}")
        return {"status": "error"}


def _post_to_gas(gas_url: str, payload: dict) -> dict:
    try:
        resp = requests.post(
            gas_url, json=payload, timeout=15, allow_redirects=True,
        )
        resp.raise_for_status()
        data = json.loads(resp.text)
        return data
    except Exception as e:
        print(f"[エラー] GAS通信に失敗しました: {e}")
        return {"success": False, "error": str(e)}


def set_online(gas_url: str, player_name: str, domain: str = "preparing...") -> bool:
    payload = {"action": "set_online", "host": player_name, "domain": domain}
    data = _post_to_gas(gas_url, payload)
    if data.get("success") and data.get("current_host") == player_name:
        return True
    if data.get("current_host") and data.get("current_host") != player_name:
        print(f"[情報] {data['current_host']} が先にホストを開始しました。")
    return False


def update_domain(gas_url: str, domain: str) -> bool:
    payload = {"action": "update_domain", "domain": domain}
    data = _post_to_gas(gas_url, payload)
    return data.get("success", False)


def set_offline(gas_url: str) -> bool:
    payload = {"action": "set_offline"}
    data = _post_to_gas(gas_url, payload)
    return data.get("success", False)


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
