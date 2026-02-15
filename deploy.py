#!/usr/bin/env python3
"""
deploy_v2_patch.py
- e4mc自動検出強化（実環境ログに基づく正規表現）+ 手動ドメイン入力
- 定期アップロード（10分間隔）
- ワールド削除機能（backup移動）
各ファイルに対してdiff的にパッチを当てる。
"""

import os

BASEDIR = os.path.dirname(os.path.abspath(__file__))


def patch_file(filepath, patches):
    """
    patches: list of (old_str, new_str)
    old_str を new_str に置換する。見つからなければ警告。
    """
    fullpath = os.path.join(BASEDIR, filepath)
    with open(fullpath, "r", encoding="utf-8") as f:
        content = f.read()

    for old_str, new_str in patches:
        if old_str not in content:
            print(f"  [警告] パッチ対象が見つかりません: {filepath}")
            print(f"         検索文字列の先頭: {old_str[:80]}...")
            continue
        content = content.replace(old_str, new_str, 1)
        print(f"  [OK] パッチ適用: {filepath}")

    with open(fullpath, "w", encoding="utf-8") as f:
        f.write(content)


def append_to_file(filepath, text):
    """ファイル末尾に追加"""
    fullpath = os.path.join(BASEDIR, filepath)
    with open(fullpath, "r", encoding="utf-8") as f:
        content = f.read()
    if text.strip() in content:
        print(f"  [スキップ] 既に追加済み: {filepath}")
        return
    with open(fullpath, "a", encoding="utf-8") as f:
        f.write(text)
    print(f"  [OK] 末尾追加: {filepath}")


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. modules/log_watcher.py — 実環境に基づくe4mc検出
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print("\n[1/6] modules/log_watcher.py — e4mc検出を実環境に基づき修正")

patch_file("modules/log_watcher.py", [
    (
        '''E4MC_DOMAIN_PATTERN = re.compile(
    r"Local game hosted on domain \\[([^\\]]+\\.e4mc\\.link)\\]"
)''',
        '''# 実環境での確認済みパターン（優先度順）:
# 1. "[e4mc] Domain assigned: xxx.e4mc.link"
# 2. "Domain assigned: xxx.e4mc.link"
# 3. "Local game hosted on domain [xxx.e4mc.link]"
# 4. フォールバック: xxx.e4mc.link を含む任意の行
E4MC_DOMAIN_PATTERNS = [
    # 実環境で確認: [System]: [Chat] [e4mc] Domain assigned: xxx.e4mc.link
    re.compile(r"Domain assigned:\\s*([\\w.-]+\\.e4mc\\.link)"),
    # チャット出力: Local game hosted on domain [xxx.e4mc.link]
    re.compile(r"Local game hosted on domain \\[([^\\]]+\\.e4mc\\.link)\\]"),
    # フォールバック: e4mc.link ドメインを含む任意の行
    re.compile(r"([a-zA-Z0-9-]+(?:\\.[a-zA-Z0-9-]+)*\\.e4mc\\.link)"),
]'''
    ),
    (
        '''            for line in new_content.splitlines():
                match = E4MC_DOMAIN_PATTERN.search(line)
                if match:
                    domain = match.group(1)
                    print(f"[ログ監視] e4mc ドメインを検出: {domain}")
                    return domain''',
        '''            for line in new_content.splitlines():
                for pattern in E4MC_DOMAIN_PATTERNS:
                    match = pattern.search(line)
                    if match:
                        domain = match.group(1)
                        print(f"[ログ監視] e4mc ドメインを検出: {domain}")
                        return domain'''
    ),
])


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. modules/status_mgr.py — delete_world 追加
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print("\n[2/6] modules/status_mgr.py — delete_world 追加")

append_to_file("modules/status_mgr.py", '''

def delete_world(gas_url: str, world_name: str) -> bool:
    """ワールドをGASから削除（ステータスシートから行を消す）"""
    payload = {"action": "delete_world", "world": world_name}
    data = _post(gas_url, payload)
    return data.get("success", False)
''')


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. modules/world_sync.py — archive_world 追加
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print("\n[3/6] modules/world_sync.py — archive_world 追加")

append_to_file("modules/world_sync.py", '''

def archive_world(config: dict) -> bool:
    """ワールドをworlds/からbackups/{world_name}_archived/に移動"""
    remote_name = config["rclone_remote_name"]
    world_name = config["world_name"]

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H%M%S")
    src = f"{remote_name}:worlds/{world_name}"
    dst = f"{remote_name}:backups/{world_name}_archived_{timestamp}"

    print(f"\\n[アーカイブ] {world_name} を backups に移動中...")

    # まずコピー
    success = _run_rclone(config, ["copy", src, dst], show_progress=False)
    if not success:
        print("[エラー] アーカイブのコピーに失敗しました。")
        return False

    # 元を削除
    success = _run_rclone(config, ["purge", src], show_progress=False)
    if not success:
        print("[警告] 元フォルダの削除に失敗しました。手動で削除してください。")

    print(f"[アーカイブ] 完了: backups/{world_name}_archived_{timestamp}")
    return True
''')


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. gas/code.gs — deleteWorld 追加
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print("\n[4/6] gas/code.gs — deleteWorld 追加")

patch_file("gas/code.gs", [
    (
        '''    case "add_world":
      return addWorld(sheet, data);
    default:''',
        '''    case "add_world":
      return addWorld(sheet, data);
    case "delete_world":
      return deleteWorld(sheet, data);
    default:'''
    ),
])

append_to_file("gas/code.gs", '''

function deleteWorld(sheet, data) {
  var world = data.world || "";
  if (!world) {
    return jsonResponse({success: false, error: "missing world"});
  }

  var row = findRow(sheet, world);
  if (row === -1) {
    return jsonResponse({success: false, error: "world not found"});
  }

  // ステータスがオンラインなら削除不可
  var status = sheet.getRange(row, 2).getValue();
  if (status === "online") {
    return jsonResponse({success: false, error: "cannot delete online world"});
  }

  sheet.deleteRow(row);
  return jsonResponse({success: true});
}
''')


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 5. main.py — ドメイン手動入力 / 定期アップロード / 削除機能
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
print("\n[5/6] main.py — ドメイン手動入力 / 定期アップロード / 削除機能")

# 5-a: import に delete_world, archive_world を追加
patch_file("main.py", [
    (
        '''from modules.status_mgr import (
    list_worlds, get_status, set_online, update_domain,
    set_offline, add_world, is_lock_expired,
)''',
        '''from modules.status_mgr import (
    list_worlds, get_status, set_online, update_domain,
    set_offline, add_world, is_lock_expired, delete_world,
)'''
    ),
    (
        '''from modules.world_sync import (
    download_world, upload_world, create_backup, check_remote_world_exists,
)''',
        '''from modules.world_sync import (
    download_world, upload_world, create_backup, check_remote_world_exists,
    archive_world,
)'''
    ),
])

# 5-b: ドメイン手動入力ダイアログ関数を追加
patch_file("main.py", [
    (
        '''# ─── 設定画面 ────────────────────────────────────''',
        '''# ─── ドメイン手動入力ダイアログ ────────────────────

def _ask_domain_manual(world_name: str) -> str | None:
    layout = [
        [sg.Text(f"ワールド「{world_name}」のドメインを入力",
                 font=("Helvetica", 12, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("e4mcドメインの自動検出に失敗しました。\\n"
                 "Minecraftのチャット欄に表示されたドメインを\\n"
                 "コピーして貼り付けてください。\\n"
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


# ─── 設定画面 ────────────────────────────────────'''
    ),
])

# 5-c: _host_thread内のドメイン検出失敗時に手動入力を追加
patch_file("main.py", [
    (
        '''        if domain:
            send(f"[ドメイン検出] {domain}")
            update_domain(gas_url, world_name, domain)
            _clipboard_copy(domain)
            send(f"ドメインをクリップボードにコピーしました。")
        else:
            send("[警告] e4mc ドメインが検出できませんでした。")''',
        '''        if domain:
            send(f"[ドメイン検出] {domain}")
            update_domain(gas_url, world_name, domain)
            _clipboard_copy(domain)
            send(f"ドメインをクリップボードにコピーしました。")
        else:
            send("[警告] e4mc ドメインが自動検出できませんでした。")
            send("手動入力ダイアログを表示します...")
            window.write_event_value("-ASK-DOMAIN-", world_name)
            # メインスレッドからの応答を待つ（最大120秒）
            import time as _t_wait
            _deadline = _t_wait.time() + 120
            domain = None
            while _t_wait.time() < _deadline:
                if hasattr(_host_thread, '_manual_domain'):
                    domain = _host_thread._manual_domain
                    del _host_thread._manual_domain
                    break
                _t_wait.sleep(0.5)
            if domain:
                send(f"[手動入力] ドメイン: {domain}")
                update_domain(gas_url, world_name, domain)
                _clipboard_copy(domain)
                send(f"ドメインをクリップボードにコピーしました。")
            else:
                send("[警告] ドメインが設定されませんでした。")'''
    ),
])

# 5-d: _host_thread内の終了待機を定期アップロード付きに変更
patch_file("main.py", [
    (
        '''        send("Minecraft の終了を待機中...")
        pid = find_minecraft_process()
        if pid:
            wait_for_exit(pid)
        else:
            send("[情報] Minecraft プロセスが見つかりません。手動ULしてください。")
            window.write_event_value("-HOST-DONE-", True)
            return''',
        '''        send("Minecraft の終了を待機中（10分ごとに自動保存）...")
        pid = find_minecraft_process()
        if pid:
            import time as _t_auto
            import psutil as _ps_auto
            AUTOSAVE_INTERVAL = 600  # 10分
            last_save = _t_auto.time()
            while True:
                try:
                    proc = _ps_auto.Process(pid)
                    if not proc.is_running() or proc.status() == _ps_auto.STATUS_ZOMBIE:
                        break
                except _ps_auto.NoSuchProcess:
                    break
                except Exception:
                    break

                if _t_auto.time() - last_save >= AUTOSAVE_INTERVAL:
                    send(f"[自動保存] {world_name} をアップロード中...")
                    upload_world(config)
                    last_save = _t_auto.time()
                    send(f"[自動保存] 完了")

                _t_auto.sleep(3)

            send("[プロセス] Minecraft が終了しました。")
            _t_auto.sleep(3)
        else:
            send("[情報] Minecraft プロセスが見つかりません。手動ULしてください。")
            window.write_event_value("-HOST-DONE-", True)
            return'''
    ),
])

# 5-e: GUIに削除ボタンを追加
patch_file("main.py", [
    (
        '''        [sg.Button("手動UL", key="-UPLOAD-", size=(12, 1)),
         sg.Button("手動DL", key="-DOWNLOAD-", size=(12, 1))],''',
        '''        [sg.Button("手動UL", key="-UPLOAD-", size=(12, 1)),
         sg.Button("手動DL", key="-DOWNLOAD-", size=(12, 1))],
        [sg.Button("削除", key="-DELETE-WORLD-", size=(12, 1),
                   button_color=("white", "firebrick"))],'''
    ),
])

# 5-f: メインループに -ASK-DOMAIN- イベントハンドラを追加
patch_file("main.py", [
    (
        '''        if event == "-HOST-LOCK-EXPIRED-":''',
        '''        if event == "-ASK-DOMAIN-":
            wn = values["-ASK-DOMAIN-"]
            manual_domain = _ask_domain_manual(wn)
            _host_thread._manual_domain = manual_domain

        if event == "-HOST-LOCK-EXPIRED-":'''
    ),
])

# 5-g: メインループに削除イベントハンドラを追加
patch_file("main.py", [
    (
        '''        # ─── 設定 ────────────────────────────────
        if event == "-SETTINGS-":''',
        '''        # ─── ワールド削除 ─────────────────────────
        if event == "-DELETE-WORLD-":
            if hosting:
                sg.popup("ホスト処理中は削除できません。", title="情報")
                continue
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("ワールドを選択してください。", title="情報")
                continue
            w = _selected_world(window, worlds)
            if w and w.get("status") == "online":
                sg.popup("オンラインのワールドは削除できません。",
                         title="情報")
                continue
            ans = sg.popup_yes_no(
                f"ワールド「{wname}」を削除しますか？\\n\\n"
                "Google Drive上のデータは backups フォルダに移動されます。\\n"
                "完全に消えるわけではありません。",
                title="ワールド削除確認",
            )
            if ans == "Yes":
                config = build_config(wname, base)
                if config:
                    _log(window, f"[削除] {wname} をアーカイブ中...")
                    if archive_world(config):
                        delete_world(gas_url, wname)
                        _log(window, f"[削除] {wname} を削除しました。")
                    else:
                        _log(window, f"[削除] アーカイブに失敗しました。")
                worlds = list_worlds(gas_url)
                items = [_world_display(w) for w in worlds]
                window["-WLIST-"].update(items)
                _update_detail(window, None)

        # ─── 設定 ────────────────────────────────
        if event == "-SETTINGS-":'''
    ),
])

print("\n[6/6] 全パッチ完了")
print()
print("=== デプロイ完了 ===")
print()
print("変更点:")
print("  1. e4mc ドメイン検出: 実環境で確認済みの3パターンに対応")
print("     - 'Domain assigned: xxx.e4mc.link' (ログ出力)")
print("     - 'Local game hosted on domain [xxx.e4mc.link]' (チャット出力)")
print("     - フォールバック: xxx.e4mc.link を含む任意の行")
print("  2. 自動検出失敗時: 手動ドメイン入力ダイアログを表示")
print("  3. 定期アップロード: Minecraft実行中、10分ごとに自動保存")
print("  4. ワールド削除: backupsにアーカイブ → ステータスシートから行削除")
print()
print("次のステップ:")
print("  1. python main.py でテスト")
print("  2. GASを再デプロイ (gas/code.gs にdeleteWorld追加済み)")
print("  3. build.bat でexe化")
