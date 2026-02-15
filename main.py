"""MC MultiDrive — 複数ワールド対応セッションマネージャ (GUI)"""

import os
import sys
import time
import threading
import subprocess
import platform

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
from modules.process_monitor import find_minecraft_process, wait_for_exit


# ─── テーマ ──────────────────────────────────────
sg.theme("DarkBlue3")

# ─── ユーティリティ ──────────────────────────────

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


# ─── stdout → GUI 転送 ──────────────────────────

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


# ─── 初回セットアップ ────────────────────────────

def _run_setup(base: str) -> dict | None:
    personal = load_personal(base)
    default_name = personal["player_name"] if personal else ""

    layout = [
        [sg.Text("MC MultiDrive - 初回セットアップ",
                 font=("Helvetica", 16, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("Minecraft のプレイヤー名を入力してください:")],
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
                sg.popup_error("プレイヤー名を入力してください。",
                               title="エラー")
                continue
            save_personal(name, base=base)
            result = {"player_name": name}
            break

    win.close()
    return result


# ─── インスタンスパス要求ダイアログ ──────────────

def _ask_instance_path(world_name: str) -> str | None:
    layout = [
        [sg.Text(f"ワールド「{world_name}」のインスタンスフォルダを選択",
                 font=("Helvetica", 12, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("CurseForge でこのModpackを右クリック →\n"
                 "Open Folder で開くフォルダと同じものを選んでください。",
                 font=("Helvetica", 9))],
        [sg.Text("")],
        [sg.Input(key="-PATH-", size=(45, 1)),
         sg.FolderBrowse("選択", target="-PATH-")],
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
                sg.popup_error("有効なフォルダを選択してください。",
                               title="エラー")
                continue
            result = p
            break
    win.close()
    return result


# ─── 新規ワールド追加ダイアログ ──────────────────

def _ask_new_world(gas_url: str, base: str) -> str | None:
    layout = [
        [sg.Text("新しいワールドを追加",
                 font=("Helvetica", 12, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("ワールド名（全員共通の名前）:")],
        [sg.Input(key="-WNAME-", size=(40, 1))],
        [sg.Text("例: ATM10, Vanilla_1.21, Create",
                 font=("Helvetica", 9))],
        [sg.Text("")],
        [sg.Button("追加", key="-ADD-", size=(10, 1)),
         sg.Button("キャンセル", key="-CANCEL-", size=(10, 1))],
    ]
    win = sg.Window("ワールド追加", layout, finalize=True, modal=True)
    result = None
    while True:
        event, values = win.read()
        if event in (sg.WIN_CLOSED, "-CANCEL-"):
            break
        if event == "-ADD-":
            wname = values["-WNAME-"].strip()
            if not wname:
                sg.popup_error("ワールド名を入力してください。",
                               title="エラー")
                continue
            if not add_world(gas_url, wname):
                sg.popup_error("ワールドの追加に失敗しました。",
                               title="エラー")
                continue
            result = wname
            break
    win.close()
    return result


# ─── ドメイン手動入力ダイアログ ────────────────────

def _ask_domain_manual(world_name: str) -> str | None:
    layout = [
        [sg.Text(f"ワールド「{world_name}」のドメインを入力",
                 font=("Helvetica", 12, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("e4mcドメインの自動検出に失敗しました。\n"
                 "Minecraftのログからドメインをコピーして貼り付けてください。\n"
                 "（例: brave-sunset.sg.e4mc.link）",
                 font=("Helvetica", 9))],
        [sg.Text("")],
        [sg.Input(key="-DOMAIN-", size=(45, 1))],
        [sg.Text("")],
        [sg.Button("OK", key="-OK-", size=(10, 1)),
         sg.Button("スキップ", key="-SKIP-", size=(10, 1))],
    ]
    win = sg.Window(f"ドメイン入力 - {world_name}", layout,
                    finalize=True, modal=True)
    result = None
    while True:
        event, values = win.read()
        if event in (sg.WIN_CLOSED, "-SKIP-"):
            break
        if event == "-OK-":
            d = values["-DOMAIN-"].strip()
            if d:
                result = d
                break
            sg.popup_error("ドメインを入力してください。", title="エラー")
    win.close()
    return result


# ─── ドメイン手動入力ダイアログ ────────────────────

def _ask_domain_manual(world_name: str) -> str | None:
    layout = [
        [sg.Text(f"ワールド「{world_name}」のドメインを入力",
                 font=("Helvetica", 12, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("e4mcドメインの自動検出に失敗しました。\n"
                 "Minecraftのチャット欄に表示されたドメインを\n"
                 "コピーして貼り付けてください。\n"
                 "（例: brave-sunset.sg.e4mc.link）",
                 font=("Helvetica", 9))],
        [sg.Text("")],
        [sg.Input(key="-DOMAIN-", size=(45, 1))],
        [sg.Text("")],
        [sg.Button("OK", key="-OK-", size=(10, 1)),
         sg.Button("スキップ", key="-SKIP-", size=(10, 1))],
    ]
    win = sg.Window(f"ドメイン入力 - {world_name}", layout,
                    finalize=True, modal=True)
    result = None
    while True:
        event, values = win.read()
        if event in (sg.WIN_CLOSED, "-SKIP-"):
            break
        if event == "-OK-":
            d = values["-DOMAIN-"].strip()
            if d:
                result = d
                break
            sg.popup_error("ドメインを入力してください。", title="エラー")
    win.close()
    return result


# ─── 設定画面 ────────────────────────────────────

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
    rows.append([sg.Text("ワールド別インスタンスパス:",
                         font=("Helvetica", 10, "bold"))])

    world_names = [w.get("world_name", "") for w in worlds]
    for wn in world_names:
        cur = instance_paths.get(wn, "")
        rows.append([
            sg.Text(f"  {wn}:", size=(18, 1)),
            sg.Input(cur, key=f"-SP-{wn}-", size=(30, 1)),
            sg.FolderBrowse("選択", target=f"-SP-{wn}-"),
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
                sg.popup_error("プレイヤー名を入力してください。",
                               title="エラー")
                continue
            new_paths = {}
            for wn in world_names:
                p = values.get(f"-SP-{wn}-", "").strip()
                if p:
                    new_paths[wn] = p
            # 既存のパス（上記リストにないワールド）を保持
            for k, v in instance_paths.items():
                if k not in new_paths and v:
                    new_paths[k] = v
            save_personal(new_name, new_paths, base)
            sg.popup("設定を保存しました。", title="保存完了")
            break
    win.close()


# ─── ワールドリスト表示文字列 ────────────────────

def _world_display(w: dict) -> str:
    name = w.get("world_name", "???")
    st = w.get("status", "offline")
    if st == "online":
        host = w.get("host", "")
        return f"[ON]  {name}  (host: {host})"
    return f"[--]  {name}"


# ─── メインレイアウト ────────────────────────────

def _make_layout(worlds: list[dict], player_name: str) -> list:
    world_items = [_world_display(w) for w in worlds]

    left_col = [
        [sg.Text("ワールド一覧", font=("Helvetica", 10, "bold"))],
        [sg.Listbox(world_items, size=(32, 12), key="-WLIST-",
                    enable_events=True, font=("Consolas", 10))],
        [sg.Button("+ 新規追加", key="-ADD-WORLD-", size=(14, 1))],
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
        [sg.Button("ホストする", key="-HOST-", size=(12, 1)),
         sg.Button("接続する", key="-JOIN-", size=(12, 1))],
        [sg.Button("ドメインコピー", key="-COPY-DOMAIN-", size=(12, 1)),
         sg.Button("savesを開く", key="-OPEN-SAVES-", size=(12, 1))],
        [sg.Button("手動UL", key="-UPLOAD-", size=(12, 1)),
         sg.Button("手動DL", key="-DOWNLOAD-", size=(12, 1))],
        [sg.Button("削除", key="-DELETE-WORLD-", size=(12, 1),
                   button_color=("white", "firebrick"))],
        [sg.Button("削除", key="-DELETE-WORLD-", size=(12, 1),
                   button_color=("white", "firebrick"))],
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


# ─── ログ書き込み ────────────────────────────────

def _log(window: sg.Window, msg: str) -> None:
    window["-LOG-"].update(msg + "\n", append=True)
    window.refresh()


# ─── 選択中ワールド取得 ──────────────────────────

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


# ─── 詳細パネル更新 ──────────────────────────────

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


# ─── インスタンスパス確保 ────────────────────────

def _ensure_instance_path(world_name: str, base: str) -> str | None:
    p = get_instance_path(world_name, base)
    if p and os.path.isdir(p):
        return p
    p = _ask_instance_path(world_name)
    if p:
        set_instance_path(world_name, p, base)
    return p


# ─── ホスト処理（バックグラウンドスレッド） ──────

def _host_thread(window: sg.Window, config: dict) -> None:
    gas_url = config["gas_url"]
    player_name = config["player_name"]
    instance_path = config["curseforge_instance_path"]
    world_name = config["world_name"]
    lock_timeout = config["lock_timeout_hours"]

    def send(msg):
        window.write_event_value("-PRINT-", msg)

    try:
        send(f"[{world_name}] ステータスを確認中...")
        status_info = get_status(gas_url, world_name)
        status = status_info.get("status", "error")

        if status == "error":
            send(f"[{world_name}] ステータスを取得できませんでした。")
            window.write_event_value("-HOST-DONE-", False)
            return

        if status == "online":
            host = status_info.get("host", "不明")
            lock_ts = status_info.get("lock_timestamp", "")
            if is_lock_expired(lock_ts, lock_timeout):
                window.write_event_value("-HOST-LOCK-EXPIRED-",
                                         {"world": world_name, "host": host})
                return
            else:
                send(f"[{world_name}] 現在 {host} がホスト中です。")
                window.write_event_value("-HOST-DONE-", False)
                return

        send(f"[{world_name}] ホスト権限を取得中...")
        if not set_online(gas_url, world_name, player_name):
            send(f"[{world_name}] ホスト権限を取得できませんでした。")
            window.write_event_value("-HOST-DONE-", False)
            return
        send(f"[{world_name}] ホスト取得成功（{player_name}）")

        if check_remote_world_exists(config):
            send(f"[{world_name}] ワールドをダウンロード中...")
            if not download_world(config):
                send(f"[{world_name}] ダウンロード失敗。")
                set_offline(gas_url, world_name)
                window.write_event_value("-HOST-DONE-", False)
                return
            send(f"[{world_name}] ダウンロード完了！")
        else:
            send(f"[{world_name}] Drive上にワールドデータなし（新規）。")

        world_path = os.path.join(instance_path, "saves", world_name)
        if os.path.isdir(world_path):
            send(f"[{world_name}] level.dat を修正中...")
            fix_level_dat(world_path)

        send("=" * 50)
        send("準備完了！")
        send(f"  1. CurseForge で Modpack の Play を押す")
        send(f"  2. ワールド「{world_name}」を開く")
        send(f"  3. Esc → Open to LAN → Start LAN World")
        send("=" * 50)
        send("e4mc ドメインを自動検出中...")

        log_path = os.path.join(instance_path, "logs", "latest.log")
        domain = watch_for_domain(log_path, timeout_seconds=600)

        if domain:
            send(f"[ドメイン検出] {domain}")
            update_domain(gas_url, world_name, domain)
            _clipboard_copy(domain)
            send(f"ドメインをクリップボードにコピーしました。")
        else:
            send("[警告] e4mc ドメインが自動検出できませんでした。")
            send("手動入力ダイアログを表示します...")
            window.write_event_value("-ASK-DOMAIN-", world_name)
            # メインスレッドからの応答を待つ（最大120秒）
            import time as _time
            _deadline = _time.time() + 120
            domain = None
            while _time.time() < _deadline:
                # _host_thread_domain に値がセットされるのを待つ
                if hasattr(_host_thread, '_manual_domain'):
                    domain = _host_thread._manual_domain
                    del _host_thread._manual_domain
                    break
                _time.sleep(0.5)
            if domain:
                send(f"[手動入力] ドメイン: {domain}")
                update_domain(gas_url, world_name, domain)
                _clipboard_copy(domain)
                send(f"ドメインをクリップボードにコピーしました。")
            else:
                send("[警告] ドメインが設定されませんでした。")

        send("Minecraft の終了を待機中（10分ごとに自動保存）...")
        pid = find_minecraft_process()
        if pid:
            import time as _time
            AUTOSAVE_INTERVAL = 600  # 10分
            last_save = _time.time()
            while True:
                try:
                    import psutil as _psutil
                    proc = _psutil.Process(pid)
                    if not proc.is_running() or proc.status() == _psutil.STATUS_ZOMBIE:
                        break
                except _psutil.NoSuchProcess:
                    break
                except Exception:
                    break

                if _time.time() - last_save >= AUTOSAVE_INTERVAL:
                    send(f"[自動保存] {world_name} をアップロード中...")
                    upload_world(config)
                    last_save = _time.time()
                    send(f"[自動保存] 完了")

                _time.sleep(3)

            send("[プロセス] Minecraft が終了しました。")
            _time.sleep(3)
        else:
            send("[情報] Minecraft プロセスが見つかりません。手動ULしてください。")
            window.write_event_value("-HOST-DONE-", True)
            return

        send(f"[{world_name}] バックアップ作成中...")
        create_backup(config)

        send(f"[{world_name}] アップロード中...")
        if upload_world(config):
            send(f"[{world_name}] アップロード完了！")
        else:
            send(f"[{world_name}] アップロード失敗。")

        set_offline(gas_url, world_name)
        send(f"[{world_name}] セッション終了。ステータスをオフラインに更新しました。")
        window.write_event_value("-HOST-DONE-", True)

    except Exception as e:
        send(f"[エラー] ホスト処理中に例外: {e}")
        try:
            set_offline(gas_url, world_name)
        except Exception:
            pass
        window.write_event_value("-HOST-DONE-", False)


# ─── メインループ ────────────────────────────────

def main():
    base = _find_base()

    # shared_config.json チェック
    try:
        shared = load_shared(base)
    except (FileNotFoundError, ValueError) as e:
        sg.popup_error(
            f"共有設定ファイルのエラー:\n{e}\n\n"
            "shared_config.json が exe と同じフォルダにあるか確認してください。",
            title="起動エラー",
        )
        return

    gas_url = shared["gas_url"]

    # 初回セットアップ
    personal = load_personal(base)
    if personal is None:
        result = _run_setup(base)
        if result is None:
            return
        personal = load_personal(base)
        if personal is None:
            return

    player_name = personal["player_name"]

    # ワールド一覧取得
    worlds = list_worlds(gas_url)
    if not worlds:
        worlds = []

    # メインウィンドウ
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

        # ─── stdout からのログ転送 ─────────────
        if event == "-PRINT-":
            _log(window, values["-PRINT-"])

        # ─── ワールド選択 ─────────────────────
        if event == "-WLIST-":
            w = _selected_world(window, worlds)
            _update_detail(window, w)

        # ─── ステータス更新 ───────────────────
        if event == "-REFRESH-":
            _log(window, "[更新] ステータスを取得中...")
            worlds = list_worlds(gas_url)
            sel_name = _selected_world_name(window, worlds)
            items = [_world_display(w) for w in worlds]
            window["-WLIST-"].update(items)
            # 選択を復元
            if sel_name:
                for i, w in enumerate(worlds):
                    if w.get("world_name") == sel_name:
                        window["-WLIST-"].update(
                            set_to_index=[i])
                        _update_detail(window, w)
                        break
            _log(window, f"[更新] {len(worlds)} 個のワールドを取得しました。")

        # ─── ワールド追加 ─────────────────────
        if event == "-ADD-WORLD-":
            wname = _ask_new_world(gas_url, base)
            if wname:
                _log(window, f"[追加] ワールド「{wname}」を追加しました。")
                worlds = list_worlds(gas_url)
                items = [_world_display(w) for w in worlds]
                window["-WLIST-"].update(items)

        # ─── ホスト ───────────────────────────
        if event == "-HOST-":
            if hosting:
                sg.popup("既にホスト処理が実行中です。", title="情報")
                continue
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを選択してください。", title="情報")
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
            # 自動で更新
            worlds = list_worlds(gas_url)
            items = [_world_display(w) for w in worlds]
            window["-WLIST-"].update(items)

        if event == "-ASK-DOMAIN-":
            wn = values["-ASK-DOMAIN-"]
            manual_domain = _ask_domain_manual(wn)
            _host_thread._manual_domain = manual_domain

        if event == "-ASK-DOMAIN-":
            wn = values["-ASK-DOMAIN-"]
            manual_domain = _ask_domain_manual(wn)
            _host_thread._manual_domain = manual_domain

        if event == "-HOST-LOCK-EXPIRED-":
            info = values["-HOST-LOCK-EXPIRED-"]
            wn = info["world"]
            old_host = info["host"]
            ans = sg.popup_yes_no(
                f"ワールド「{wn}」のロックが期限切れです。\n"
                f"（前回ホスト: {old_host}）\n\n"
                "強制的にホストを引き継ぎますか？",
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

        # ─── 接続 ────────────────────────────
        if event == "-JOIN-":
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを選択してください。", title="情報")
                continue
            w = _selected_world(window, worlds)
            if not w or w.get("status") != "online":
                sg.popup("このワールドはオフラインです。", title="情報")
                continue
            domain = w.get("domain", "")
            if not domain or domain == "preparing...":
                sg.popup("ドメインがまだ準備中です。少し待ってから更新してください。",
                         title="情報")
                continue
            inst = _ensure_instance_path(wname, base)
            if inst:
                server_label = f"MC MultiDrive - {wname}"
                update_servers_dat(inst, domain, server_label)
            _clipboard_copy(domain)
            _log(window, f"[接続] {domain} をクリップボードにコピーしました。")
            sg.popup(
                f"ドメインをコピーしました:\n{domain}\n\n"
                "CurseForge で Play → マルチプレイから接続してください。",
                title="接続情報",
            )

        # ─── ドメインコピー ───────────────────
        if event == "-COPY-DOMAIN-":
            w = _selected_world(window, worlds)
            if w and w.get("domain") and w["domain"] != "preparing...":
                _clipboard_copy(w["domain"])
                _log(window, f"[コピー] {w['domain']}")
            else:
                sg.popup("コピーできるドメインがありません。", title="情報")

        # ─── saves を開く ─────────────────────
        if event == "-OPEN-SAVES-":
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを選択してください。", title="情報")
                continue
            inst = get_instance_path(wname, base)
            if inst:
                saves_path = os.path.join(inst, "saves")
                if os.path.isdir(saves_path):
                    _open_folder(saves_path)
                else:
                    sg.popup(f"saves フォルダが見つかりません:\n{saves_path}",
                             title="エラー")
            else:
                sg.popup("インスタンスパスが未設定です。\n"
                         "設定画面で設定してください。", title="情報")

        # ─── 手動アップロード ─────────────────
        if event == "-UPLOAD-":
            if hosting:
                sg.popup("ホスト処理中はアップロードできません。",
                         title="情報")
                continue
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを選択してください。", title="情報")
                continue
            inst = _ensure_instance_path(wname, base)
            if not inst:
                continue
            ans = sg.popup_yes_no(
                f"ワールド「{wname}」を Google Drive にアップロードしますか？\n"
                "Drive 上のデータは上書きされます。",
                title="手動アップロード確認",
            )
            if ans == "Yes":
                config = build_config(wname, base)
                if config:
                    _log(window, f"[手動UL] {wname} アップロード中...")
                    threading.Thread(
                        target=lambda: (
                            upload_world(config),
                            window.write_event_value("-REFRESH-", None),
                        ),
                        daemon=True,
                    ).start()

        # ─── 手動ダウンロード ─────────────────
        if event == "-DOWNLOAD-":
            if hosting:
                sg.popup("ホスト処理中はダウンロードできません。",
                         title="情報")
                continue
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを選択してください。", title="情報")
                continue
            inst = _ensure_instance_path(wname, base)
            if not inst:
                continue
            ans = sg.popup_yes_no(
                f"ワールド「{wname}」を Google Drive からダウンロードしますか？\n"
                "ローカルのデータは上書きされます。",
                title="手動ダウンロード確認",
            )
            if ans == "Yes":
                config = build_config(wname, base)
                if config:
                    _log(window, f"[手動DL] {wname} ダウンロード中...")
                    threading.Thread(
                        target=lambda: (
                            download_world(config),
                            window.write_event_value("-REFRESH-", None),
                        ),
                        daemon=True,
                    ).start()

        # ─── 設定 ────────────────────────────
        if event == "-SETTINGS-":
            _show_settings(base, worlds)
            personal = load_personal(base)
            if personal:
                player_name = personal["player_name"]

    window.close()


if __name__ == "__main__":
    main()
