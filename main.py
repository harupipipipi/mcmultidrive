"""ATM10 Session Manager — GUI版 (FreeSimpleGUI) / exe配布対応"""

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
    build_config, print_config,
)
from modules.status_mgr import (
    get_status, set_online, update_domain, set_offline, is_lock_expired,
)
from modules.world_sync import (
    download_world, upload_world, create_backup, check_remote_world_exists,
)
from modules.nbt_editor import fix_level_dat, update_servers_dat
from modules.log_watcher import watch_for_domain
from modules.process_monitor import find_minecraft_process, wait_for_exit


# ---------------------------------------------------------------------------
# 初回セットアップウィザード
# ---------------------------------------------------------------------------
def _run_setup(base: str) -> dict | None:
    personal = load_personal(base)
    default_name = personal["player_name"] if personal else ""
    default_path = personal["curseforge_instance_path"] if personal else ""

    layout = [
        [sg.Text("初回セットアップ", font=("Helvetica", 16, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("Minecraft のプレイヤー名を入力してください:")],
        [sg.Input(default_name, key="-NAME-", size=(40, 1))],
        [sg.Text("")],
        [sg.Text("CurseForge の ATM10 インスタンスフォルダを選択してください:")],
        [sg.Text("（CurseForge で ATM10 を右クリック → Open Folder で\n"
                  " 開くフォルダと同じものを選んでください）",
                  font=("Helvetica", 9))],
        [sg.Input(default_path, key="-PATH-", size=(40, 1)),
         sg.FolderBrowse("選択", target="-PATH-")],
        [sg.Text("")],
        [sg.Button("保存して開始", key="-SAVE-", size=(15, 1)),
         sg.Button("キャンセル", key="-CANCEL-", size=(10, 1))],
    ]

    win = sg.Window("ATM10 Session Manager - セットアップ", layout,
                     finalize=True, modal=True)

    result = None
    while True:
        event, values = win.read()

        if event in (sg.WIN_CLOSED, "-CANCEL-"):
            break

        if event == "-SAVE-":
            name = values["-NAME-"].strip()
            path = values["-PATH-"].strip()

            if not name:
                sg.popup_error("プレイヤー名を入力してください。", title="エラー")
                continue
            if not path or not os.path.isdir(path):
                sg.popup_error(
                    "有効なフォルダを選択してください。\n"
                    "CurseForge で ATM10 を右クリック →\n"
                    "Open Folder で開くフォルダを選んでください。",
                    title="エラー",
                )
                continue

            save_personal(name, path, base)
            result = build_config(base)
            break

    win.close()
    return result


def _load_or_setup() -> dict | None:
    base = _find_base()

    try:
        load_shared(base)
    except (FileNotFoundError, ValueError) as e:
        sg.popup_error(
            f"共有設定ファイルのエラー:\n{e}\n\n"
            "shared_config.json が exe と同じフォルダにあるか確認してください。",
            title="起動エラー",
        )
        return None

    config = build_config(base)
    if config is None:
        config = _run_setup(base)
    return config


# ---------------------------------------------------------------------------
# stdout → GUI ログ転送
# ---------------------------------------------------------------------------
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


# ---------------------------------------------------------------------------
# ユーティリティ
# ---------------------------------------------------------------------------
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


def _status_text(info: dict) -> str:
    st = info.get("status", "error")
    if st == "online":
        host = info.get("host", "不明")
        domain = info.get("domain", "")
        txt = f"オンライン（ホスト: {host}）"
        if domain and domain != "preparing...":
            txt += f"\nドメイン: {domain}"
        elif domain == "preparing...":
            txt += "\nドメイン: 準備中..."
        return txt
    if st == "offline":
        return "オフライン"
    return "取得失敗"


# ---------------------------------------------------------------------------
# レイアウト
# ---------------------------------------------------------------------------
def _make_layout(status_str: str) -> list:
    return [
        [sg.Text("ATM10 Session Manager", font=("Helvetica", 18, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("ステータス:", font=("Helvetica", 10, "bold")),
         sg.Text(status_str, key="-STATUS-", size=(50, 2),
                 font=("Helvetica", 10))],
        [sg.HorizontalSeparator()],
        [sg.Button("ホストとして開始", key="-HOST-", size=(20, 2)),
         sg.Button("接続する", key="-JOIN-", size=(20, 2))],
        [sg.Button("手動アップロード", key="-UPLOAD-", size=(20, 1)),
         sg.Button("手動ダウンロード", key="-DOWNLOAD-", size=(20, 1))],
        [sg.Button("saves フォルダを開く", key="-OPEN-SAVES-", size=(20, 1)),
         sg.Button("設定確認", key="-CONFIG-", size=(20, 1))],
        [sg.Button("個人設定を変更", key="-RECONFIG-", size=(20, 1)),
         sg.Push()],
        [sg.HorizontalSeparator()],
        [sg.Text("ログ:", font=("Helvetica", 10, "bold"))],
        [sg.Multiline(size=(62, 15), key="-LOG-", autoscroll=True,
                       disabled=True, font=("Consolas", 9))],
        [sg.Button("終了", key="-EXIT-", size=(10, 1))],
    ]


# ---------------------------------------------------------------------------
# ログ書き込み
# ---------------------------------------------------------------------------
def _log(window: sg.Window, msg: str) -> None:
    window["-LOG-"].update(msg + "\n", append=True)
    window.refresh()


# ---------------------------------------------------------------------------
# ホストフロー (バックグラウンドスレッド)
# ---------------------------------------------------------------------------
def _host_thread(window: sg.Window, config: dict) -> None:
    gas_url = config["gas_url"]
    player_name = config["player_name"]
    instance_path = config["curseforge_instance_path"]
    world_name = config["world_name"]
    lock_timeout = config["lock_timeout_hours"]

    def send(msg):
        window.write_event_value("-PRINT-", msg)

    try:
        send("[ステータス] 現在の状態を確認中...")
        status_info = get_status(gas_url)
        status = status_info.get("status", "error")

        if status == "error":
            send("[エラー] ステータスを取得できませんでした。")
            window.write_event_value("-HOST-DONE-", False)
            return

        if status == "online":
            host = status_info.get("host", "不明")
            lock_ts = status_info.get("lock_timestamp", "")
            if is_lock_expired(lock_ts, lock_timeout):
                window.write_event_value("-HOST-LOCK-EXPIRED-", host)
                return
            else:
                send(f"[情報] 現在 {host} がホスト中です。終了をお待ちください。")
                window.write_event_value("-HOST-DONE-", False)
                return

        send("[ロック] ホスト権限を取得中...")
        if not set_online(gas_url, player_name):
            send("[エラー] ホスト権限を取得できませんでした。")
            window.write_event_value("-HOST-DONE-", False)
            return
        send(f"[ロック] 取得成功（{player_name}）")

        if check_remote_world_exists(config):
            send("[同期] ワールドをダウンロード中...")
            if not download_world(config):
                send("[エラー] ダウンロード失敗。")
                set_offline(gas_url)
                window.write_event_value("-HOST-DONE-", False)
                return
            send("[同期] ダウンロード完了！")
        else:
            send("[情報] Drive 上にワールドデータなし（新規ワールド）。")

        world_path = os.path.join(instance_path, "saves", world_name)
        if os.path.isdir(world_path):
            send("[NBT] level.dat を修正中...")
            fix_level_dat(world_path)

        send("=" * 45)
        send("準備完了！")
        send(f"  1. CurseForge で ATM10 の Play を押す")
        send(f"  2. ワールド「{world_name}」を開く")
        send(f"  3. Esc → Open to LAN → Start LAN World")
        send("=" * 45)
        send("e4mc ドメインを自動検出中...")

        log_path = os.path.join(instance_path, "logs", "latest.log")
        domain = watch_for_domain(log_path, timeout_seconds=600)

        if domain:
            send(f"[ドメイン検出] {domain}")
            update_domain(gas_url, domain)
            _clipboard_copy(domain)
            send("（クリップボードにコピーしました）")
            send("Minecraft を閉じると自動アップロードされます。")
            window.write_event_value("-HOST-DOMAIN-", domain)
        else:
            send("[エラー] ドメイン検出失敗。終了後に手動ULしてください。")

        send("[プロセス] Minecraft を検索中...")
        pid = None
        for _ in range(60):
            pid = find_minecraft_process()
            if pid:
                break
            time.sleep(3)

        if pid:
            send(f"[プロセス] Minecraft 検出 (PID: {pid})。終了を待機中...")
            wait_for_exit(pid)
        else:
            send("[警告] Minecraft プロセスが見つかりません。10秒待機...")
            time.sleep(10)

        send("[終了処理] バックアップ作成中...")
        create_backup(config)

        send("[終了処理] アップロード中...")
        if upload_world(config):
            send("[終了処理] アップロード完了！")
        else:
            send("[エラー] アップロード失敗。手動ULしてください。")

        set_offline(gas_url)
        send("=" * 45)
        send("セッション終了。ワールドをアップロードしました。")
        send("=" * 45)
        window.write_event_value("-HOST-DONE-", True)

    except Exception as e:
        try:
            send(f"[エラー] {e}")
            send("[エラー] ステータスをオフラインに設定します...")
            set_offline(gas_url)
        except Exception:
            pass
        window.write_event_value("-HOST-DONE-", False)


# ---------------------------------------------------------------------------
# 接続フロー
# ---------------------------------------------------------------------------
def _join_flow(window: sg.Window, config: dict) -> None:
    gas_url = config["gas_url"]
    instance_path = config["curseforge_instance_path"]

    _log(window, "[ステータス] 確認中...")
    status_info = get_status(gas_url)
    status = status_info.get("status", "error")

    if status != "online":
        sg.popup("現在ホストがいません。\nホストが開始するまでお待ちください。",
                 title="情報")
        return

    domain = status_info.get("domain", "")
    host = status_info.get("host", "不明")

    if not domain or domain == "preparing...":
        sg.popup(f"{host} がホストを準備中です。\nもう少しお待ちください。",
                 title="情報")
        return

    _log(window, "[NBT] servers.dat を更新中...")
    update_servers_dat(instance_path, domain, "ATM10 Session")
    _clipboard_copy(domain)

    _log(window, f"接続準備完了！  ホスト: {host}  ドメイン: {domain}")
    sg.popup(
        f"接続準備完了！\n\n"
        f"ホスト : {host}\n"
        f"ドメイン: {domain}\n"
        f"（クリップボードにコピー済み）\n\n"
        f"1. CurseForge で ATM10 の Play を押す\n"
        f"2. マルチプレイ → ATM10 Session をクリック",
        title="接続準備完了",
    )


# ---------------------------------------------------------------------------
# 手動アップロード / ダウンロード (スレッド)
# ---------------------------------------------------------------------------
def _upload_thread(window: sg.Window, config: dict) -> None:
    def send(msg):
        window.write_event_value("-PRINT-", msg)
    try:
        send("[バックアップ] 作成中...")
        create_backup(config)
        send("[アップロード] 実行中...")
        if upload_world(config):
            send("[完了] アップロードが完了しました。")
        else:
            send("[エラー] アップロードに失敗しました。")
    except Exception as e:
        send(f"[エラー] {e}")
    window.write_event_value("-TASK-DONE-", None)


def _download_thread(window: sg.Window, config: dict) -> None:
    def send(msg):
        window.write_event_value("-PRINT-", msg)
    try:
        send("[ダウンロード] 実行中...")
        if download_world(config):
            send("[完了] ダウンロードが完了しました。")
        else:
            send("[エラー] ダウンロードに失敗しました。")
    except Exception as e:
        send(f"[エラー] {e}")
    window.write_event_value("-TASK-DONE-", None)


# ---------------------------------------------------------------------------
# ボタン有効/無効
# ---------------------------------------------------------------------------
_BUTTONS = ("-HOST-", "-JOIN-", "-UPLOAD-", "-DOWNLOAD-",
            "-OPEN-SAVES-", "-CONFIG-", "-RECONFIG-")


def _set_buttons(window: sg.Window, enabled: bool) -> None:
    for k in _BUTTONS:
        window[k].update(disabled=not enabled)


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------
REFRESH_SEC = 30


def main() -> None:
    sg.theme("DarkGrey13")

    config = _load_or_setup()
    if config is None:
        return

    status_info = get_status(config["gas_url"])
    layout = _make_layout(_status_text(status_info))

    window = sg.Window(
        "ATM10 Session Manager",
        layout,
        finalize=True,
        resizable=False,
    )

    writer = _GUIWriter(window)
    sys.stdout = writer

    busy = False
    last_refresh = time.time()

    while True:
        event, values = window.read(timeout=200)

        if event in (sg.WIN_CLOSED, "-EXIT-"):
            break

        if event == "-PRINT-":
            _log(window, values["-PRINT-"])
            continue

        if event == sg.TIMEOUT_KEY:
            now = time.time()
            if not busy and (now - last_refresh) >= REFRESH_SEC:
                last_refresh = now
                try:
                    si = get_status(config["gas_url"])
                    window["-STATUS-"].update(_status_text(si))
                except Exception:
                    pass
            continue

        # ホスト開始
        if event == "-HOST-" and not busy:
            busy = True
            _set_buttons(window, False)
            threading.Thread(
                target=_host_thread, args=(window, config), daemon=True,
            ).start()
            continue

        if event == "-HOST-LOCK-EXPIRED-":
            host = values[event]
            ans = sg.popup_yes_no(
                f"前回のセッション（ホスト: {host}）が\n"
                f"正常に終了していない可能性があります。\n\n続行しますか？",
                title="ロック期限切れ",
            )
            if ans == "Yes":
                set_offline(config["gas_url"])
                threading.Thread(
                    target=_host_thread, args=(window, config), daemon=True,
                ).start()
            else:
                _log(window, "キャンセルしました。")
                busy = False
                _set_buttons(window, True)
            continue

        if event == "-HOST-DOMAIN-":
            domain = values[event]
            window["-STATUS-"].update(
                f"オンライン（ホスト: {config['player_name']}）\n"
                f"ドメイン: {domain}"
            )
            continue

        if event == "-HOST-DONE-":
            busy = False
            _set_buttons(window, True)
            last_refresh = 0
            continue

        # 接続
        if event == "-JOIN-" and not busy:
            _join_flow(window, config)
            continue

        # 手動アップロード
        if event == "-UPLOAD-" and not busy:
            ans = sg.popup_yes_no(
                "Drive 上のワールドが上書きされます。\n続行しますか？",
                title="手動アップロード",
            )
            if ans == "Yes":
                busy = True
                _set_buttons(window, False)
                threading.Thread(
                    target=_upload_thread, args=(window, config), daemon=True,
                ).start()
            continue

        # 手動ダウンロード
        if event == "-DOWNLOAD-" and not busy:
            ans = sg.popup_yes_no(
                "ローカルのワールドが上書きされます。\n続行しますか？",
                title="手動ダウンロード",
            )
            if ans == "Yes":
                busy = True
                _set_buttons(window, False)
                threading.Thread(
                    target=_download_thread, args=(window, config), daemon=True,
                ).start()
            continue

        if event == "-TASK-DONE-":
            busy = False
            _set_buttons(window, True)
            continue

        # saves フォルダを開く
        if event == "-OPEN-SAVES-":
            saves = os.path.join(config["curseforge_instance_path"], "saves")
            _open_folder(saves)
            continue

        # 設定確認
        if event == "-CONFIG-":
            sg.popup(print_config(config),
                     title="現在の設定", font=("Consolas", 10))
            continue

        # 個人設定を変更
        if event == "-RECONFIG-" and not busy:
            base = _find_base()
            new_config = _run_setup(base)
            if new_config is not None:
                config = new_config
                _log(window, "[設定] 個人設定を更新しました。")
                try:
                    si = get_status(config["gas_url"])
                    window["-STATUS-"].update(_status_text(si))
                except Exception:
                    pass
            continue

    sys.stdout = writer._original
    window.close()


if __name__ == "__main__":
    main()
