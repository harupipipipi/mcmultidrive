"""ATM10 Session Manager — エントリポイント"""

import os
import sys
import time

try:
    import pyperclip
except ImportError:
    pyperclip = None

from modules.config_mgr import load_config, print_config
from modules.status_mgr import get_status, set_online, update_domain, set_offline, is_lock_expired
from modules.world_sync import download_world, upload_world, create_backup, check_remote_world_exists
from modules.nbt_editor import fix_level_dat, update_servers_dat
from modules.log_watcher import watch_for_domain
from modules.process_monitor import find_minecraft_process, wait_for_exit


def clipboard_copy(text: str) -> None:
    if pyperclip:
        try:
            pyperclip.copy(text)
            print("（クリップボードにコピーしました）")
        except Exception:
            print("（クリップボードへのコピーに失敗しました）")
    else:
        print("（pyperclip 未インストールのため、クリップボードコピーはスキップ）")


def show_menu(status_info: dict) -> str:
    print("\n=== ATM10 Session Manager ===")
    status = status_info.get("status", "error")
    if status == "online":
        host = status_info.get("host", "不明")
        domain = status_info.get("domain", "")
        print(f"現在のステータス: オンライン（ホスト: {host}）")
        if domain and domain != "preparing...":
            print(f"ドメイン: {domain}")
        elif domain == "preparing...":
            print("ドメイン: 準備中...")
    elif status == "offline":
        print("現在のステータス: オフライン")
    else:
        print("現在のステータス: 取得失敗")
    print()
    print("[1] ホストとして開始（ワールドDL → LAN公開 → 自動管理）")
    print("[2] 接続する（既存セッションに参加）")
    print("[3] ワールドを手動アップロード")
    print("[4] ワールドを手動ダウンロード")
    print("[5] 設定確認")
    print("[0] 終了")
    print()
    return input("選択 > ").strip()


def host_flow(config: dict) -> None:
    gas_url = config["gas_url"]
    player_name = config["player_name"]
    instance_path = config["curseforge_instance_path"]
    world_name = config["world_name"]
    lock_timeout = config["lock_timeout_hours"]

    print("\n[ステータス] 現在の状態を確認中...")
    status_info = get_status(gas_url)
    status = status_info.get("status", "error")

    if status == "error":
        print("[エラー] ステータスを取得できませんでした。ネットワーク接続を確認してください。")
        return

    if status == "online":
        host = status_info.get("host", "不明")
        lock_ts = status_info.get("lock_timestamp", "")
        if is_lock_expired(lock_ts, lock_timeout):
            print(f"\n[警告] 前回のセッション（ホスト: {host}）が正常に終了していない可能性があります。")
            print(f"       ロックは {lock_timeout} 時間を超えて期限切れです。")
            confirm = input("続行しますか？ (y/n) > ").strip().lower()
            if confirm != "y":
                print("キャンセルしました。")
                return
        else:
            print(f"\n[情報] 現在 {host} がホスト中です。")
            print("セッションが終了するまでお待ちください。")
            return

    print("\n[ロック] ホスト権限を取得中...")
    if not set_online(gas_url, player_name):
        print("[エラー] ホスト権限を取得できませんでした。他の人が先に開始した可能性があります。")
        return

    print(f"[ロック] ホスト権限を取得しました（プレイヤー: {player_name}）")

    try:
        if check_remote_world_exists(config):
            print("\n[同期] Drive からワールドをダウンロードします...")
            if not download_world(config):
                print("[エラー] ワールドのダウンロードに失敗しました。")
                set_offline(gas_url)
                return
            print("[同期] ダウンロード完了！")
        else:
            print("\n[情報] Drive 上にワールドデータがありません（新規ワールド）。")
            print("       Minecraft でワールドを新規作成してください。")

        world_path = os.path.join(instance_path, "saves", world_name)
        if os.path.isdir(world_path):
            print("\n[NBT] level.dat を修正中...")
            fix_level_dat(world_path)

        print("\n" + "=" * 50)
        print("準備完了！")
        print("=" * 50)
        print()
        print("以下の手順を実行してください:")
        print(f"  1. CurseForge で ATM10 の「Play」を押してください")
        print(f"  2. ワールド「{world_name}」を選択して開いてください")
        print(f"  3. Esc → Open to LAN → Start LAN World を押してください")
        print()
        print("e4mc ドメインを自動検出中...")
        print()

        log_path = os.path.join(instance_path, "logs", "latest.log")
        domain = watch_for_domain(log_path, timeout_seconds=600)

        if not domain:
            print("\n[エラー] e4mc ドメインが検出できませんでした。")
            print("手動でセッションを管理してください。")
            print("Minecraft を閉じた後、メニュー [3] で手動アップロードを実行してください。")
            confirm = input("\nMinecraft の終了を待機して自動アップロードしますか？ (y/n) > ").strip().lower()
            if confirm != "y":
                set_offline(gas_url)
                return
        else:
            print("\n[ステータス] ドメインを更新中...")
            update_domain(gas_url, domain)
            print()
            print("=" * 50)
            print("セッション開始！")
            print("=" * 50)
            print(f"ドメイン: {domain}")
            clipboard_copy(domain)
            print()
            print("Minecraft を閉じると自動的にワールドがアップロードされます。")
            print("このウィンドウは閉じないでください。")
            print()

        print("[プロセス] Minecraft プロセスを検索中...")
        pid = None
        for _ in range(60):
            pid = find_minecraft_process()
            if pid:
                break
            time.sleep(3)

        if pid:
            wait_for_exit(pid)
        else:
            print("[警告] Minecraft プロセスが見つかりませんでした。")
            input("Minecraft を閉じたら Enter を押してください > ")

        print("\n[終了処理] セッション終了処理を開始します...")
        print("[終了処理] バックアップを作成中...")
        create_backup(config)

        print("[終了処理] ワールドをアップロード中...")
        if upload_world(config):
            print("[終了処理] アップロード完了！")
        else:
            print("[エラー] アップロードに失敗しました。")
            print("メニュー [3] で手動アップロードを試してください。")

        set_offline(gas_url)
        print()
        print("=" * 50)
        print("セッション終了。ワールドをアップロードしました。")
        print("=" * 50)

    except KeyboardInterrupt:
        print("\n\n[中断] Ctrl+C が押されました。")
        print("[中断] ステータスをオフラインに設定します...")
        set_offline(gas_url)
        print("[中断] 完了。ワールドはアップロードされていません。")
        print("       必要に応じてメニュー [3] で手動アップロードしてください。")

    except Exception as e:
        print(f"\n[エラー] 予期しないエラーが発生しました: {e}")
        print("[エラー] ステータスをオフラインに設定します...")
        set_offline(gas_url)


def join_flow(config: dict) -> None:
    gas_url = config["gas_url"]
    instance_path = config["curseforge_instance_path"]

    print("\n[ステータス] 現在の状態を確認中...")
    status_info = get_status(gas_url)
    status = status_info.get("status", "error")

    if status != "online":
        print("\n[情報] 現在ホストがいません。")
        print("ホストが「ホストとして開始」を実行するまでお待ちください。")
        return

    domain = status_info.get("domain", "")
    host = status_info.get("host", "不明")

    if not domain or domain == "preparing...":
        print(f"\n[情報] {host} がホストを準備中です。")
        print("もう少しお待ちください（LAN公開が完了するまで）。")
        return

    print(f"\n[NBT] servers.dat を更新中...")
    update_servers_dat(instance_path, domain, "ATM10 Session")

    print()
    print("=" * 50)
    print("接続準備完了！")
    print("=" * 50)
    print(f"ホスト  : {host}")
    print(f"ドメイン: {domain}")
    clipboard_copy(domain)
    print()
    print("以下の手順を実行してください:")
    print("  1. CurseForge で ATM10 の「Play」を押してください")
    print("  2. マルチプレイ → サーバーリスト1番目の「ATM10 Session」をクリック")
    print("     または Direct Connect にドメインを貼り付けて接続")
    print()


def manual_upload(config: dict) -> None:
    print("\n[手動アップロード] ローカルのワールドを Drive にアップロードします。")
    print("[警告] Drive 上のワールドが上書きされます。")
    confirm = input("続行しますか？ (y/n) > ").strip().lower()
    if confirm != "y":
        print("キャンセルしました。")
        return
    print("\n[バックアップ] アップロード前にバックアップを作成します...")
    create_backup(config)
    if upload_world(config):
        print("\n[完了] アップロードが完了しました。")
    else:
        print("\n[エラー] アップロードに失敗しました。")


def manual_download(config: dict) -> None:
    instance_path = config["curseforge_instance_path"]
    world_name = config["world_name"]
    local_path = os.path.join(instance_path, "saves", world_name)
    print("\n[手動ダウンロード] Drive のワールドをローカルにダウンロードします。")
    if os.path.isdir(local_path):
        print(f"[警告] ローカルのワールドフォルダが上書きされます: {local_path}")
    confirm = input("続行しますか？ (y/n) > ").strip().lower()
    if confirm != "y":
        print("キャンセルしました。")
        return
    if download_world(config):
        print("\n[完了] ダウンロードが完了しました。")
    else:
        print("\n[エラー] ダウンロードに失敗しました。")


def main() -> None:
    config = load_config()
    while True:
        status_info = get_status(config["gas_url"])
        choice = show_menu(status_info)
        if choice == "1":
            host_flow(config)
            input("\nEnter を押してメニューに戻ります > ")
        elif choice == "2":
            join_flow(config)
            input("\nEnter を押してメニューに戻ります > ")
        elif choice == "3":
            manual_upload(config)
            input("\nEnter を押してメニューに戻ります > ")
        elif choice == "4":
            manual_download(config)
            input("\nEnter を押してメニューに戻ります > ")
        elif choice == "5":
            print_config(config)
            input("\nEnter を押してメニューに戻ります > ")
        elif choice == "0":
            print("終了します。")
            break
        else:
            print("無効な選択です。")


if __name__ == "__main__":
    main()
