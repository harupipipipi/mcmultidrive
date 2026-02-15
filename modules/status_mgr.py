"""status_mgr.py - GASステータス管理（マルチワールド）"""

import json
from datetime import datetime, timezone

import requests


def _get(gas_url: str, params: dict) -> dict:
    try:
        resp = requests.get(gas_url, params=params, timeout=15)
        resp.raise_for_status()
        return json.loads(resp.text)
    except Exception as e:
        print(f"[エラー] GAS GETリクエスト失敗: {e}")
        return {"error": str(e)}


def _post(gas_url: str, payload: dict) -> dict:
    try:
        resp = requests.post(
            gas_url, json=payload, timeout=15, allow_redirects=True,
        )
        resp.raise_for_status()
        return json.loads(resp.text)
    except Exception as e:
        print(f"[エラー] GAS POSTリクエスト失敗: {e}")
        return {"success": False, "error": str(e)}


# -- 読み取り --

def list_worlds(gas_url: str) -> list[dict]:
    data = _get(gas_url, {"action": "list_worlds"})
    return data.get("worlds", [])


def get_status(gas_url: str, world_name: str) -> dict:
    data = _get(gas_url, {"action": "get_status", "world": world_name})
    return data


# -- 書き込み --

def set_online(gas_url: str, world_name: str, player_name: str,
               domain: str = "preparing...") -> bool:
    payload = {
        "action": "set_online",
        "world": world_name,
        "host": player_name,
        "domain": domain,
    }
    data = _post(gas_url, payload)
    if data.get("success") and data.get("current_host") == player_name:
        return True
    if data.get("current_host") and data.get("current_host") != player_name:
        print(f"[情報] {data['current_host']} が既にホスト中です。")
    return False


def update_domain(gas_url: str, world_name: str, domain: str) -> bool:
    payload = {"action": "update_domain", "world": world_name, "domain": domain}
    data = _post(gas_url, payload)
    return data.get("success", False)


def set_offline(gas_url: str, world_name: str) -> bool:
    payload = {"action": "set_offline", "world": world_name}
    data = _post(gas_url, payload)
    return data.get("success", False)


def add_world(gas_url: str, world_name: str) -> bool:
    payload = {"action": "add_world", "world": world_name}
    data = _post(gas_url, payload)
    return data.get("success", False)


def delete_world(gas_url: str, world_name: str) -> bool:
    """GASステータスシートからワールドを削除"""
    payload = {"action": "delete_world", "world": world_name}
    data = _post(gas_url, payload)
    return data.get("success", False)


# -- ロック --

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
