#!/bin/bash
set -euo pipefail

# =============================================================================
# deploy_ja.sh - MC MultiDrive 全UI・メッセージ・コメント日本語化スクリプト
# =============================================================================

# --- main.py ---
cat << 'PYTHON_EOF' > main.py
"""MC MultiDrive — マルチワールドセッションマネージャー (GUI)"""

import os
import sys
import time
import threading
import subprocess
import platform

import psutil

try:
    import pyperclip
except ImportError:
    pyperclip = None

import FreeSimpleGUI as sg

from modules.config_mgr import (
    _find_base, load_shared, load_personal, save_personal,
    set_instance_path, get_instance_path, build_config,
)
from modules.status_mgr import (
    list_worlds, get_status, set_online, update_domain,
    set_offline, add_world, is_lock_expired, delete_world,
)
from modules.world_sync import (
    download_world, upload_world, create_backup, check_remote_world_exists,
    archive_world,
)
from modules.nbt_editor import fix_level_dat, update_servers_dat
from modules.log_watcher import watch_for_domain
from modules.process_monitor import (
    find_minecraft_process, wait_for_exit, wait_for_minecraft_start,
)


# --- スレッド間のドメイン共有 ---
_manual_domain_event = threading.Event()
_manual_domain_value = ""

# --- テーマ ---
sg.theme("DarkBlue3")


# --- ユーティリティ ---

def _clipboard_copy(text: str) -> None:
    if pyperclip:
        try:
            pyperclip.copy(text)
        except Exception:
            pass


def _open_folder(path: str) -> None:
    if not os.path.isdir(path):
        sg.popup_error(f"フォルダが見つかりません:\n{path}", title="エラー")
        return
    if platform.system() == "Windows":
        os.startfile(path)
    elif platform.system() == "Darwin":
        subprocess.Popen(["open", path])
    else:
        subprocess.Popen(["xdg-open", path])


# --- 標準出力 -> GUI ---

class _GUIWriter:
    def __init__(self, window: sg.Window):
        self._window = window
        self._original = sys.stdout

    def write(self, text: str) -> None:
        if text.strip():
            try:
                self._window.write_event_value("-PRINT-", text)
            except Exception:
                pass
        if self._original:
            self._original.write(text)

    def flush(self) -> None:
        if self._original:
            self._original.flush()


# --- 初回セットアップ ---

def _run_setup(base: str) -> dict | None:
    personal = load_personal(base)
    default_name = personal["player_name"] if personal else ""

    layout = [
        [sg.Text("MC MultiDrive - セットアップ",
                 font=("Helvetica", 16, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("Minecraftのプレイヤー名を入力してください:")],
        [sg.Input(default_name, key="-NAME-", size=(40, 1))],
        [sg.Text("")],
        [sg.Button("開始", key="-SAVE-", size=(15, 1)),
         sg.Button("キャンセル", key="-CANCEL-", size=(10, 1))],
    ]

    win = sg.Window("MC MultiDrive - セットアップ", layout,
                    finalize=True, modal=True)

    result = None
    while True:
        event, values = win.read()
        if event in (sg.WIN_CLOSED, "-CANCEL-"):
            break
        if event == "-SAVE-":
            name = values["-NAME-"].strip()
            if not name:
                sg.popup_error("プレイヤー名を入力してください。", title="エラー")
                continue
            save_personal(name, base=base)
            result = {"player_name": name}
            break

    win.close()
    return result


# --- インスタンスパスダイアログ ---

def _ask_instance_path(world_name: str) -> str | None:
    layout = [
        [sg.Text(f"「{world_name}」のインスタンスフォルダを選択",
                 font=("Helvetica", 12, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("CurseForge: Modパックを右クリック → フォルダを開く",
                 font=("Helvetica", 9))],
        [sg.Text("")],
        [sg.Input(key="-PATH-", size=(45, 1)),
         sg.FolderBrowse("参照", target="-PATH-")],
        [sg.Text("")],
        [sg.Button("OK", key="-OK-", size=(10, 1)),
         sg.Button("キャンセル", key="-CANCEL-", size=(10, 1))],
    ]
    win = sg.Window(f"インスタンスフォルダ - {world_name}", layout,
                    finalize=True, modal=True)
    result = None
    while True:
        event, values = win.read()
        if event in (sg.WIN_CLOSED, "-CANCEL-"):
            break
        if event == "-OK-":
            p = values["-PATH-"].strip()
            if not p or not os.path.isdir(p):
                sg.popup_error("有効なフォルダを選択してください。", title="エラー")
                continue
            result = p
            break
    win.close()
    return result


# --- ワールド追加ダイアログ（2段階: インスタンス選択 → savesフォルダ選択）---

def _ask_new_world(gas_url: str, base: str) -> str | None:
    # ステップ1: インスタンスフォルダ選択
    layout1 = [
        [sg.Text("ワールド追加 (1/2)",
                 font=("Helvetica", 12, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("ワールドが含まれるインスタンスフォルダを選択:")],
        [sg.Text("CurseForge: Modパックを右クリック → フォルダを開く",
                 font=("Helvetica", 9))],
        [sg.Input(key="-INST-", size=(45, 1)),
         sg.FolderBrowse("参照", target="-INST-")],
        [sg.Text("")],
        [sg.Button("次へ", key="-NEXT-", size=(10, 1)),
         sg.Button("キャンセル", key="-CANCEL-", size=(10, 1))],
    ]
    win1 = sg.Window("ワールド追加 (1/2)", layout1, finalize=True, modal=True)
    instance_path = None
    while True:
        event, values = win1.read()
        if event in (sg.WIN_CLOSED, "-CANCEL-"):
            win1.close()
            return None
        if event == "-NEXT-":
            p = values["-INST-"].strip()
            saves_dir = os.path.join(p, "saves") if p else ""
            if not p or not os.path.isdir(saves_dir):
                sg.popup_error(
                    "有効なインスタンスフォルダを選択してください。\n"
                    "（'saves'フォルダが含まれている必要があります）",
                    title="エラー")
                continue
            instance_path = p
            break
    win1.close()

    # ステップ2: saves/ 内のワールド一覧
    saves_dir = os.path.join(instance_path, "saves")
    world_dirs = sorted([
        d for d in os.listdir(saves_dir)
        if os.path.isdir(os.path.join(saves_dir, d))
        and not d.startswith(".")
    ])
    if not world_dirs:
        sg.popup_error("savesフォルダにワールドが見つかりません。\n"
                       "先にMinecraftでワールドを作成してください。",
                       title="エラー")
        return None

    layout2 = [
        [sg.Text("ワールド追加 (2/2)",
                 font=("Helvetica", 12, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("共有するワールドを選択:")],
        [sg.Listbox(world_dirs, size=(40, 10), key="-WSEL-",
                    select_mode=sg.LISTBOX_SELECT_MODE_SINGLE)],
        [sg.Text("")],
        [sg.Button("追加", key="-ADD-", size=(10, 1)),
         sg.Button("キャンセル", key="-CANCEL-", size=(10, 1))],
    ]
    win2 = sg.Window("ワールド追加 (2/2)", layout2, finalize=True, modal=True)
    result = None
    while True:
        event, values = win2.read()
        if event in (sg.WIN_CLOSED, "-CANCEL-"):
            break
        if event == "-ADD-":
            sel = values["-WSEL-"]
            if not sel:
                sg.popup_error("ワールドを選択してください。", title="エラー")
                continue
            wname = sel[0]
            if not add_world(gas_url, wname):
                sg.popup_error("ワールドの追加に失敗しました。", title="エラー")
                continue
            set_instance_path(wname, instance_path, base)
            result = wname
            break
    win2.close()
    return result


# --- 設定ダイアログ ---

def _show_settings(base: str, worlds: list[dict]) -> None:
    personal = load_personal(base)
    if not personal:
        return
    player_name = personal["player_name"]
    instance_paths = personal.get("instance_paths", {})

    rows = []
    rows.append([sg.Text("プレイヤー名:"),
                 sg.Input(player_name, key="-SNAME-", size=(30, 1))])
    rows.append([sg.HorizontalSeparator()])
    rows.append([sg.Text("ワールドごとのインスタンスパス:",
                         font=("Helvetica", 10, "bold"))])

    world_names = [w.get("world_name", "") for w in worlds]
    for wn in world_names:
        cur = instance_paths.get(wn, "")
        rows.append([
            sg.Text(f"  {wn}:", size=(18, 1)),
            sg.Input(cur, key=f"-SP-{wn}-", size=(30, 1)),
            sg.FolderBrowse("参照", target=f"-SP-{wn}-"),
        ])

    layout = [
        [sg.Text("設定", font=("Helvetica", 14, "bold"))],
        [sg.HorizontalSeparator()],
        *rows,
        [sg.Text("")],
        [sg.Button("保存", key="-SSAVE-", size=(10, 1)),
         sg.Button("閉じる", key="-SCLOSE-", size=(10, 1))],
    ]

    win = sg.Window("設定", layout, finalize=True, modal=True)
    while True:
        event, values = win.read()
        if event in (sg.WIN_CLOSED, "-SCLOSE-"):
            break
        if event == "-SSAVE-":
            new_name = values["-SNAME-"].strip()
            if not new_name:
                sg.popup_error("プレイヤー名を入力してください。", title="エラー")
                continue
            new_paths = {}
            for wn in world_names:
                p = values.get(f"-SP-{wn}-", "").strip()
                if p:
                    new_paths[wn] = p
            for k, v in instance_paths.items():
                if k not in new_paths and v:
                    new_paths[k] = v
            save_personal(new_name, new_paths, base)
            sg.popup("設定を保存しました。", title="完了")
            break
    win.close()


# --- ワールド表示文字列 ---

def _world_display(w: dict) -> str:
    name = w.get("world_name", "???")
    st = w.get("status", "offline")
    if st == "online":
        host = w.get("host", "")
        return f"[ON]  {name}  (ホスト: {host})"
    return f"[--]  {name}"


# --- メインレイアウト ---

def _make_layout(worlds: list[dict], player_name: str) -> list:
    world_items = [_world_display(w) for w in worlds]

    left_col = [
        [sg.Text("ワールド一覧", font=("Helvetica", 10, "bold"))],
        [sg.Listbox(world_items, size=(32, 12), key="-WLIST-",
                    enable_events=True, font=("Consolas", 10))],
        [sg.Button("+ ワールド追加", key="-ADD-WORLD-", size=(14, 1))],
        [sg.Button("削除", key="-DELETE-WORLD-", size=(14, 1),
                   button_color=("white", "firebrick"))],
    ]

    right_col = [
        [sg.Text("詳細", font=("Helvetica", 10, "bold"))],
        [sg.Text("ワールド:", size=(10, 1)),
         sg.Text("---", key="-D-NAME-", size=(25, 1),
                 font=("Helvetica", 10, "bold"))],
        [sg.Text("ステータス:", size=(10, 1)),
         sg.Text("---", key="-D-STATUS-", size=(25, 1))],
        [sg.Text("ホスト:", size=(10, 1)),
         sg.Text("---", key="-D-HOST-", size=(25, 1))],
        [sg.Text("ドメイン:", size=(10, 1)),
         sg.Text("---", key="-D-DOMAIN-", size=(25, 1))],
        [sg.Text("")],
        [sg.Button("ホスト", key="-HOST-", size=(12, 1)),
         sg.Button("参加", key="-JOIN-", size=(12, 1))],
        [sg.Button("ドメインコピー", key="-COPY-DOMAIN-", size=(12, 1)),
         sg.Button("savesを開く", key="-OPEN-SAVES-", size=(12, 1))],
        [sg.Button("手動UL", key="-UPLOAD-", size=(12, 1)),
         sg.Button("手動DL", key="-DOWNLOAD-", size=(12, 1))],
        [sg.Text("")],
        [sg.Text("手動ドメイン:", size=(14, 1)),
         sg.Input(key="-MANUAL-DOMAIN-", size=(20, 1)),
         sg.Button("設定", key="-SET-DOMAIN-", size=(5, 1))],
    ]

    layout = [
        [sg.Text("MC MultiDrive", font=("Helvetica", 18, "bold")),
         sg.Push(),
         sg.Text(f"プレイヤー: {player_name}",
                 font=("Helvetica", 10))],
        [sg.HorizontalSeparator()],
        [sg.Column(left_col, vertical_alignment="top"),
         sg.VSeperator(),
         sg.Column(right_col, vertical_alignment="top")],
        [sg.HorizontalSeparator()],
        [sg.Text("ログ:", font=("Helvetica", 10, "bold"))],
        [sg.Multiline(size=(72, 10), key="-LOG-", autoscroll=True,
                      disabled=True, font=("Consolas", 9))],
        [sg.Button("更新", key="-REFRESH-", size=(8, 1)),
         sg.Button("設定", key="-SETTINGS-", size=(8, 1)),
         sg.Push(),
         sg.Button("終了", key="-EXIT-", size=(8, 1))],
    ]
    return layout


# --- ログヘルパー ---

def _log(window: sg.Window, msg: str) -> None:
    window["-LOG-"].update(msg + "\n", append=True)
    window.refresh()


# --- 選択中のワールド ---

def _selected_world(window: sg.Window, worlds: list[dict]) -> dict | None:
    sel = window["-WLIST-"].get()
    if not sel:
        return None
    sel_text = sel[0]
    for w in worlds:
        if _world_display(w) == sel_text:
            return w
    return None


def _selected_world_name(window: sg.Window, worlds: list[dict]) -> str | None:
    w = _selected_world(window, worlds)
    return w.get("world_name") if w else None


# --- 詳細パネル更新 ---

def _update_detail(window: sg.Window, w: dict | None) -> None:
    if w is None:
        window["-D-NAME-"].update("---")
        window["-D-STATUS-"].update("---")
        window["-D-HOST-"].update("---")
        window["-D-DOMAIN-"].update("---")
        return
    window["-D-NAME-"].update(w.get("world_name", "---"))
    st = w.get("status", "offline")
    if st == "online":
        window["-D-STATUS-"].update("オンライン")
        window["-D-HOST-"].update(w.get("host", "---"))
        domain = w.get("domain", "")
        if domain and domain != "preparing...":
            window["-D-DOMAIN-"].update(domain)
        elif domain == "preparing...":
            window["-D-DOMAIN-"].update("準備中...")
        else:
            window["-D-DOMAIN-"].update("---")
    else:
        window["-D-STATUS-"].update("オフライン")
        window["-D-HOST-"].update("---")
        window["-D-DOMAIN-"].update("---")


# --- インスタンスパス確認 ---

def _ensure_instance_path(world_name: str, base: str) -> str | None:
    p = get_instance_path(world_name, base)
    if p and os.path.isdir(p):
        return p
    p = _ask_instance_path(world_name)
    if p:
        set_instance_path(world_name, p, base)
    return p


# --- ホストスレッド（バックグラウンド）---

def _host_thread(window: sg.Window, config: dict) -> None:
    gas_url = config["gas_url"]
    player_name = config["player_name"]
    instance_path = config["curseforge_instance_path"]
    world_name = config["world_name"]
    lock_timeout = config["lock_timeout_hours"]

    def send(msg):
        window.write_event_value("-PRINT-", msg)

    try:
        send(f"[{world_name}] ステータス確認中...")
        status_info = get_status(gas_url, world_name)
        status = status_info.get("status", "error")

        if status == "error":
            send(f"[{world_name}] ステータスを取得できませんでした。")
            window.write_event_value("-HOST-DONE-", False)
            return

        if status == "online":
            host = status_info.get("host", "unknown")
            lock_ts = status_info.get("lock_timestamp", "")
            if is_lock_expired(lock_ts, lock_timeout):
                window.write_event_value("-HOST-LOCK-EXPIRED-",
                                         {"world": world_name, "host": host})
                return
            else:
                send(f"[{world_name}] 現在 {host} がホスト中です。")
                window.write_event_value("-HOST-DONE-", False)
                return

        send(f"[{world_name}] ホストロック取得中...")
        if not set_online(gas_url, world_name, player_name):
            send(f"[{world_name}] ホストロックの取得に失敗しました。")
            window.write_event_value("-HOST-DONE-", False)
            return
        send(f"[{world_name}] ホスト取得完了 ({player_name})")

        if check_remote_world_exists(config):
            send(f"[{world_name}] ワールドをダウンロード中...")
            if not download_world(config):
                send(f"[{world_name}] ダウンロードに失敗しました。")
                set_offline(gas_url, world_name)
                window.write_event_value("-HOST-DONE-", False)
                return
            send(f"[{world_name}] ダウンロード完了！")
        else:
            send(f"[{world_name}] Driveにワールドデータがありません（新規ワールド）。")

        world_path = os.path.join(instance_path, "saves", world_name)
        if os.path.isdir(world_path):
            send(f"[{world_name}] level.datを修正中...")
            fix_level_dat(world_path)

        send("=" * 50)
        send("準備完了！")
        send("  1. CurseForgeでプレイを押す")
        send(f"  2. ワールド「{world_name}」を開く")
        send("  3. Esc → LANに公開 → LANワールドを開始")
        send("=" * 50)
        send("e4mcドメインを検出中...")
        send("自動検出に失敗した場合は、右パネルにドメインを手動入力し「設定」をクリックしてください。")

        log_path = os.path.join(instance_path, "logs", "latest.log")

        # バックグラウンドスレッドで自動検出
        domain_result = [None]
        def _auto_detect():
            domain_result[0] = watch_for_domain(log_path, timeout_seconds=600)
        detect_thread = threading.Thread(target=_auto_detect, daemon=True)
        detect_thread.start()

        # 自動検出またはマニュアル入力を待機
        global _manual_domain_value
        _manual_domain_event.clear()
        _manual_domain_value = ""
        domain = None

        while detect_thread.is_alive():
            detect_thread.join(timeout=1.0)
            if domain_result[0]:
                domain = domain_result[0]
                break
            if _manual_domain_event.is_set():
                domain = _manual_domain_value
                break

        if domain is None and domain_result[0]:
            domain = domain_result[0]

        if domain:
            send(f"[ドメイン] {domain}")
            update_domain(gas_url, world_name, domain)
            _clipboard_copy(domain)
            send("ドメインをクリップボードにコピーしました。")
        else:
            send("[警告] e4mcドメインが検出されませんでした。")

        # -- Minecraft終了待機 + 定期自動保存 --
        send("Minecraftの終了を待機中（10分ごとに自動保存）...")
        AUTOSAVE_INTERVAL = 600

        pid = find_minecraft_process()
        if not pid:
            send("[情報] Minecraftの起動を待機中（最大5分）...")
            pid = wait_for_minecraft_start(timeout_seconds=300)

        if not pid:
            send("[情報] Minecraftのプロセスが見つかりません。手動ULを使用してください。")
            window.write_event_value("-HOST-DONE-", True)
            return

        send(f"[プロセス] Minecraft検出 (PID: {pid})")
        last_save = time.time()
        while True:
            try:
                proc = psutil.Process(pid)
                if not proc.is_running() or proc.status() == psutil.STATUS_ZOMBIE:
                    break
            except psutil.NoSuchProcess:
                break
            if time.time() - last_save >= AUTOSAVE_INTERVAL:
                send(f"[自動保存] {world_name} をアップロード中...")
                upload_world(config)
                last_save = time.time()
                send("[自動保存] 完了。")
            time.sleep(3)

        send("[プロセス] Minecraftが終了しました。")
        time.sleep(3)

        send(f"[{world_name}] バックアップを作成中...")
        create_backup(config)

        send(f"[{world_name}] アップロード中...")
        if upload_world(config):
            send(f"[{world_name}] アップロード完了！")
        else:
            send(f"[{world_name}] アップロードに失敗しました。")

        set_offline(gas_url, world_name)
        send(f"[{world_name}] セッション終了。ステータスをオフラインに設定しました。")
        window.write_event_value("-HOST-DONE-", True)

    except Exception as e:
        send(f"[エラー] ホスト処理中に例外発生: {e}")
        try:
            set_offline(gas_url, world_name)
        except Exception:
            pass
        window.write_event_value("-HOST-DONE-", False)


# --- メインループ ---

def main():
    base = _find_base()

    try:
        shared = load_shared(base)
    except (FileNotFoundError, ValueError) as e:
        sg.popup_error(
            f"共有設定エラー:\n{e}\n\n"
            "shared_config.jsonが実行ファイルと同じ場所にあることを確認してください。",
            title="起動エラー",
        )
        return

    gas_url = shared["gas_url"]

    personal = load_personal(base)
    if personal is None:
        result = _run_setup(base)
        if result is None:
            return
        personal = load_personal(base)
        if personal is None:
            return

    player_name = personal["player_name"]

    worlds = list_worlds(gas_url)
    if not worlds:
        worlds = []

    window = sg.Window(
        "MC MultiDrive",
        _make_layout(worlds, player_name),
        finalize=True,
    )

    sys.stdout = _GUIWriter(window)
    hosting = False

    while True:
        event, values = window.read(timeout=100)

        if event in (sg.WIN_CLOSED, "-EXIT-"):
            break

        # --- 標準出力ログ ---
        if event == "-PRINT-":
            _log(window, values["-PRINT-"])

        # --- ワールド選択 ---
        if event == "-WLIST-":
            w = _selected_world(window, worlds)
            _update_detail(window, w)

        # --- 更新 ---
        if event == "-REFRESH-":
            _log(window, "[更新] ステータスを取得中...")
            worlds = list_worlds(gas_url)
            sel_name = _selected_world_name(window, worlds)
            items = [_world_display(w) for w in worlds]
            window["-WLIST-"].update(items)
            if sel_name:
                for i, w in enumerate(worlds):
                    if w.get("world_name") == sel_name:
                        window["-WLIST-"].update(set_to_index=[i])
                        _update_detail(window, w)
                        break
            _log(window, f"[更新] {len(worlds)}個のワールドが見つかりました。")

        # --- ワールド追加 ---
        if event == "-ADD-WORLD-":
            wname = _ask_new_world(gas_url, base)
            if wname:
                _log(window, f"[追加] ワールド「{wname}」を追加しました。")
                worlds = list_worlds(gas_url)
                items = [_world_display(w) for w in worlds]
                window["-WLIST-"].update(items)

        # --- ワールド削除 ---
        if event == "-DELETE-WORLD-":
            if hosting:
                sg.popup("ホスト中は削除できません。", title="情報")
                continue
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを先に選択してください。", title="情報")
                continue
            w = _selected_world(window, worlds)
            if w and w.get("status") == "online":
                sg.popup("オンラインのワールドは削除できません。", title="エラー")
                continue
            ans = sg.popup_yes_no(
                f"ワールド「{wname}」を削除しますか？\n\n"
                "Driveのデータはbackups/に移動されます。\n"
                "必要に応じてbackups/から手動で削除してください。",
                title="削除確認",
            )
            if ans == "Yes":
                config = build_config(wname, base)
                if config:
                    _log(window, f"[削除] {wname} をアーカイブ中...")
                    archive_ok = archive_world(config)
                    if archive_ok:
                        if delete_world(gas_url, wname):
                            _log(window, f"[削除] {wname} を削除しました。")
                        else:
                            _log(window, f"[エラー] GAS削除に失敗しました。")
                    else:
                        _log(window, f"[エラー] アーカイブに失敗しました。")
                else:
                    # コンフィグ構築失敗（インスタンスパスなし）- GASからは削除
                    if delete_world(gas_url, wname):
                        _log(window, f"[削除] {wname} をリストから削除しました。")
                    else:
                        _log(window, f"[エラー] GAS削除に失敗しました。")
                worlds = list_worlds(gas_url)
                items = [_world_display(w) for w in worlds]
                window["-WLIST-"].update(items)
                _update_detail(window, None)

        # --- 手動ドメイン設定 ---
        if event == "-SET-DOMAIN-":
            global _manual_domain_value
            manual_d = values.get("-MANUAL-DOMAIN-", "").strip()
            if manual_d:
                _manual_domain_value = manual_d
                _manual_domain_event.set()
                _log(window, f"[手動] ドメインを設定: {manual_d}")
                # ホスト中ならGASも更新
                if hosting:
                    wname = _selected_world_name(window, worlds)
                    if wname:
                        update_domain(gas_url, wname, manual_d)
            else:
                sg.popup("ドメインを入力してください。", title="情報")

        # --- ホスト ---
        if event == "-HOST-":
            if hosting:
                sg.popup("既にホスト中です。", title="情報")
                continue
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを先に選択してください。", title="情報")
                continue
            inst = _ensure_instance_path(wname, base)
            if not inst:
                continue
            config = build_config(wname, base)
            if not config:
                sg.popup_error("設定の構築に失敗しました。", title="エラー")
                continue
            hosting = True
            threading.Thread(
                target=_host_thread, args=(window, config),
                daemon=True,
            ).start()

        if event == "-HOST-DONE-":
            hosting = False
            worlds = list_worlds(gas_url)
            items = [_world_display(w) for w in worlds]
            window["-WLIST-"].update(items)

        if event == "-HOST-LOCK-EXPIRED-":
            info = values["-HOST-LOCK-EXPIRED-"]
            wn = info["world"]
            old_host = info["host"]
            ans = sg.popup_yes_no(
                f"「{wn}」のロックが期限切れです。\n"
                f"（前のホスト: {old_host}）\n\n"
                "強制的に引き継ぎますか？",
                title="ロック期限切れ",
            )
            if ans == "Yes":
                config = build_config(wn, base)
                if config:
                    set_offline(gas_url, wn)
                    hosting = True
                    threading.Thread(
                        target=_host_thread, args=(window, config),
                        daemon=True,
                    ).start()
            else:
                hosting = False

        # --- 参加 ---
        if event == "-JOIN-":
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを先に選択してください。", title="情報")
                continue
            w = _selected_world(window, worlds)
            if not w or w.get("status") != "online":
                sg.popup("このワールドはオフラインです。", title="情報")
                continue
            domain = w.get("domain", "")
            if not domain or domain == "preparing...":
                sg.popup("ドメインがまだ準備できていません。更新してからもう一度試してください。",
                         title="情報")
                continue
            inst = _ensure_instance_path(wname, base)
            if inst:
                server_label = f"MC MultiDrive - {wname}"
                update_servers_dat(inst, domain, server_label)
            _clipboard_copy(domain)
            _log(window, f"[参加] {domain} をクリップボードにコピーしました。")
            sg.popup(
                f"ドメインをコピーしました:\n{domain}\n\n"
                "Minecraftを起動 → マルチプレイ → ダイレクト接続に貼り付け",
                title="参加情報",
            )

        # --- ドメインコピー ---
        if event == "-COPY-DOMAIN-":
            w = _selected_world(window, worlds)
            if w and w.get("domain") and w["domain"] != "preparing...":
                _clipboard_copy(w["domain"])
                _log(window, f"[コピー] {w['domain']}")
            else:
                sg.popup("コピーするドメインがありません。", title="情報")

        # --- savesを開く ---
        if event == "-OPEN-SAVES-":
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを先に選択してください。", title="情報")
                continue
            inst = get_instance_path(wname, base)
            if inst:
                saves_path = os.path.join(inst, "saves")
                if os.path.isdir(saves_path):
                    _open_folder(saves_path)
                else:
                    sg.popup(f"savesフォルダが見つかりません:\n{saves_path}",
                             title="エラー")
            else:
                sg.popup("インスタンスパスが設定されていません。\n設定から構成してください。",
                         title="情報")

        # --- 手動アップロード ---
        if event == "-UPLOAD-":
            if hosting:
                sg.popup("ホスト中はアップロードできません。", title="情報")
                continue
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを先に選択してください。", title="情報")
                continue
            inst = _ensure_instance_path(wname, base)
            if not inst:
                continue
            ans = sg.popup_yes_no(
                f"ワールド「{wname}」をGoogle Driveにアップロードしますか？\n"
                "Drive上のデータは上書きされます。",
                title="アップロード確認",
            )
            if ans == "Yes":
                config = build_config(wname, base)
                if config:
                    _log(window, f"[アップロード] {wname} をアップロード中...")
                    threading.Thread(
                        target=lambda c=config: (
                            upload_world(c),
                            window.write_event_value("-REFRESH-", None),
                        ),
                        daemon=True,
                    ).start()

        # --- 手動ダウンロード ---
        if event == "-DOWNLOAD-":
            if hosting:
                sg.popup("ホスト中はダウンロードできません。", title="情報")
                continue
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを先に選択してください。", title="情報")
                continue
            inst = _ensure_instance_path(wname, base)
            if not inst:
                continue
            ans = sg.popup_yes_no(
                f"ワールド「{wname}」をGoogle Driveからダウンロードしますか？\n"
                "ローカルデータは上書きされます。",
                title="ダウンロード確認",
            )
            if ans == "Yes":
                config = build_config(wname, base)
                if config:
                    _log(window, f"[ダウンロード] {wname} をダウンロード中...")
                    threading.Thread(
                        target=lambda c=config: (
                            download_world(c),
                            window.write_event_value("-REFRESH-", None),
                        ),
                        daemon=True,
                    ).start()

        # --- 設定 ---
        if event == "-SETTINGS-":
            _show_settings(base, worlds)
            personal = load_personal(base)
            if personal:
                player_name = personal["player_name"]

    window.close()


if __name__ == "__main__":
    main()
PYTHON_EOF

# --- modules/config_mgr.py ---
mkdir -p modules
cat << 'PYTHON_EOF' > modules/config_mgr.py
"""config_mgr.py - マルチワールド設定管理"""

import json
import os
import sys

SHARED_FIELDS = [
    "gas_url", "rclone_remote_name", "rclone_drive_folder_id",
    "backup_generations", "lock_timeout_hours",
]


def _find_base() -> str:
    if getattr(sys, 'frozen', False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# -- shared_config.json（共有設定）--

def load_shared(base: str = None) -> dict:
    if base is None:
        base = _find_base()
    path = os.path.join(base, "shared_config.json")
    if not os.path.exists(path):
        raise FileNotFoundError(f"shared_config.jsonが見つかりません: {path}")
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    missing = [k for k in SHARED_FIELDS if k not in data]
    if missing:
        raise ValueError(f"shared_config.jsonに必須フィールドがありません: {', '.join(missing)}")
    return data


# -- my_settings.json（個人設定）--

def load_personal(base: str = None) -> dict | None:
    if base is None:
        base = _find_base()
    path = os.path.join(base, "my_settings.json")
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if "player_name" not in data:
        return None
    if "instance_paths" not in data:
        data["instance_paths"] = {}
    return data


def save_personal(player_name: str, instance_paths: dict = None,
                  base: str = None) -> str:
    if base is None:
        base = _find_base()
    path = os.path.join(base, "my_settings.json")
    existing = load_personal(base)
    if instance_paths is None:
        instance_paths = existing["instance_paths"] if existing else {}
    data = {
        "player_name": player_name,
        "instance_paths": instance_paths,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    return path


def set_instance_path(world_name: str, path: str, base: str = None) -> None:
    if base is None:
        base = _find_base()
    personal = load_personal(base)
    if personal is None:
        return
    personal["instance_paths"][world_name] = path
    save_personal(personal["player_name"], personal["instance_paths"], base)


def get_instance_path(world_name: str, base: str = None) -> str | None:
    if base is None:
        base = _find_base()
    personal = load_personal(base)
    if personal is None:
        return None
    return personal.get("instance_paths", {}).get(world_name)


# -- マージされた設定の構築 --

def build_config(world_name: str, base: str = None) -> dict | None:
    if base is None:
        base = _find_base()
    try:
        shared = load_shared(base)
    except (FileNotFoundError, ValueError):
        return None
    personal = load_personal(base)
    if personal is None:
        return None
    instance_path = personal.get("instance_paths", {}).get(world_name)
    config = {}
    config.update(shared)
    config["player_name"] = personal["player_name"]
    config["world_name"] = world_name
    config["curseforge_instance_path"] = instance_path or ""
    config["rclone_exe_path"] = os.path.join(base, "rclone", "rclone.exe")
    config["rclone_config_path"] = os.path.join(base, "rclone.conf")
    return config
PYTHON_EOF

# --- modules/status_mgr.py ---
cat << 'PYTHON_EOF' > modules/status_mgr.py
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
PYTHON_EOF

# --- modules/world_sync.py ---
cat << 'PYTHON_EOF' > modules/world_sync.py
"""world_sync.py - rcloneワールド同期（マルチワールド）"""

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
                print(f"[rcloneエラー] {result.stderr.strip()}")
            return False
        return True
    except FileNotFoundError:
        print(f"[エラー] rcloneが見つかりません: {rclone_exe}")
        return False
    except Exception as e:
        print(f"[エラー] rcloneエラー: {e}")
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
        print(f"[警告] バックアップのクリーンアップに失敗しました: {e}")


def archive_world(config: dict) -> bool:
    """ワールドをworlds/からbackups/{world}_archived_{timestamp}/に移動"""
    remote_name = config["rclone_remote_name"]
    world_name = config["world_name"]

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H%M%S")
    src = f"{remote_name}:worlds/{world_name}"
    dst = f"{remote_name}:backups/{world_name}_archived_{timestamp}"

    print(f"\n[アーカイブ] {world_name} → backups/{world_name}_archived_{timestamp}")

    success = _run_rclone(config, ["copy", src, dst], show_progress=False)
    if not success:
        print("[エラー] アーカイブのコピーに失敗しました。")
        return False

    success = _run_rclone(config, ["purge", src], show_progress=False)
    if not success:
        print("[警告] 元データの削除に失敗しました（バックアップは作成済み）。")
        return False

    print(f"[アーカイブ] 完了: {world_name}")
    return True
PYTHON_EOF

# --- modules/log_watcher.py ---
cat << 'PYTHON_EOF' > modules/log_watcher.py
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
PYTHON_EOF

# --- modules/process_monitor.py ---
cat << 'PYTHON_EOF' > modules/process_monitor.py
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
PYTHON_EOF

# --- modules/nbt_editor.py ---
cat << 'PYTHON_EOF' > modules/nbt_editor.py
"""nbt_editor.py - level.dat / servers.dat NBTエディタ"""

import os
import shutil

import nbtlib
from nbtlib.tag import Compound, List, String, Byte


def fix_level_dat(world_path: str) -> bool:
    level_dat_path = os.path.join(world_path, "level.dat")
    if not os.path.isfile(level_dat_path):
        print("[情報] level.datが見つかりません（新規ワールドの可能性があります）。")
        return True
    try:
        backup_path = level_dat_path + ".bak"
        shutil.copy2(level_dat_path, backup_path)
        nbt_file = nbtlib.load(level_dat_path)
        if "Data" in nbt_file:
            data = nbt_file["Data"]
            if "Player" in data:
                del data["Player"]
                nbt_file.save()
                print("[nbt] level.datからPlayerタグを削除しました。")
            else:
                print("[nbt] Playerタグは存在しません（対応不要）。")
        else:
            print("[警告] level.datにDataタグが見つかりません。")
        return True
    except Exception as e:
        print(f"[エラー] level.datの編集に失敗しました: {e}")
        return False


def update_servers_dat(instance_path: str, server_ip: str,
                       server_name: str = "MC MultiDrive Session") -> bool:
    servers_dat_path = os.path.join(instance_path, "servers.dat")
    try:
        if os.path.isfile(servers_dat_path):
            nbt_file = nbtlib.load(servers_dat_path)
        else:
            nbt_file = nbtlib.File(
                {"servers": List[Compound]()}, gzipped=False,
            )
            nbt_file.filename = servers_dat_path

        if "servers" not in nbt_file:
            nbt_file["servers"] = List[Compound]()

        servers = nbt_file["servers"]

        existing_index = None
        for i, server in enumerate(servers):
            if "name" in server and str(server["name"]) == server_name:
                existing_index = i
                break

        new_entry = Compound({
            "name": String(server_name),
            "ip": String(server_ip),
            "acceptTextures": Byte(1),
        })

        if existing_index is not None:
            servers.pop(existing_index)

        servers.insert(0, new_entry)
        nbt_file.save(servers_dat_path, gzipped=False)
        print(f"[nbt] servers.datを更新: {server_name} → {server_ip}")
        return True
    except Exception as e:
        print(f"[エラー] servers.datの編集に失敗しました: {e}")
        return False
PYTHON_EOF

# --- git操作 ---
git add -A
git commit -m "fix: 全UI・メッセージ・コメントを日本語化"
git push origin main

echo ""
echo "=== 日本語化完了 ==="
echo "全ファイルをpushしました。"
