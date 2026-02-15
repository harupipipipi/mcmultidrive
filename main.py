"""MC MultiDrive — multi-world session manager (GUI)"""

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


# --- domain sharing between threads ---
_manual_domain_event = threading.Event()
_manual_domain_value = ""

# --- theme ---
sg.theme("DarkBlue3")


# --- utilities ---

def _clipboard_copy(text: str) -> None:
    if pyperclip:
        try:
            pyperclip.copy(text)
        except Exception:
            pass


def _open_folder(path: str) -> None:
    if not os.path.isdir(path):
        sg.popup_error(f"Folder not found:\n{path}", title="Error")
        return
    if platform.system() == "Windows":
        os.startfile(path)
    elif platform.system() == "Darwin":
        subprocess.Popen(["open", path])
    else:
        subprocess.Popen(["xdg-open", path])


# --- stdout -> GUI ---

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


# --- first-time setup ---

def _run_setup(base: str) -> dict | None:
    personal = load_personal(base)
    default_name = personal["player_name"] if personal else ""

    layout = [
        [sg.Text("MC MultiDrive - Setup",
                 font=("Helvetica", 16, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("Enter your Minecraft player name:")],
        [sg.Input(default_name, key="-NAME-", size=(40, 1))],
        [sg.Text("")],
        [sg.Button("Start", key="-SAVE-", size=(15, 1)),
         sg.Button("Cancel", key="-CANCEL-", size=(10, 1))],
    ]

    win = sg.Window("MC MultiDrive - Setup", layout,
                    finalize=True, modal=True)

    result = None
    while True:
        event, values = win.read()
        if event in (sg.WIN_CLOSED, "-CANCEL-"):
            break
        if event == "-SAVE-":
            name = values["-NAME-"].strip()
            if not name:
                sg.popup_error("Please enter a player name.", title="Error")
                continue
            save_personal(name, base=base)
            result = {"player_name": name}
            break

    win.close()
    return result


# --- instance path dialog ---

def _ask_instance_path(world_name: str) -> str | None:
    layout = [
        [sg.Text(f"Select instance folder for \"{world_name}\"",
                 font=("Helvetica", 12, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("CurseForge: right-click modpack -> Open Folder",
                 font=("Helvetica", 9))],
        [sg.Text("")],
        [sg.Input(key="-PATH-", size=(45, 1)),
         sg.FolderBrowse("Browse", target="-PATH-")],
        [sg.Text("")],
        [sg.Button("OK", key="-OK-", size=(10, 1)),
         sg.Button("Cancel", key="-CANCEL-", size=(10, 1))],
    ]
    win = sg.Window(f"Instance Folder - {world_name}", layout,
                    finalize=True, modal=True)
    result = None
    while True:
        event, values = win.read()
        if event in (sg.WIN_CLOSED, "-CANCEL-"):
            break
        if event == "-OK-":
            p = values["-PATH-"].strip()
            if not p or not os.path.isdir(p):
                sg.popup_error("Please select a valid folder.", title="Error")
                continue
            result = p
            break
    win.close()
    return result


# --- add world dialog (2-step: pick instance -> pick saves folder) ---

def _ask_new_world(gas_url: str, base: str) -> str | None:
    # Step 1: pick instance folder
    layout1 = [
        [sg.Text("Add New World (1/2)",
                 font=("Helvetica", 12, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("")],
        [sg.Text("Select instance folder containing the world:")],
        [sg.Text("CurseForge: right-click modpack -> Open Folder",
                 font=("Helvetica", 9))],
        [sg.Input(key="-INST-", size=(45, 1)),
         sg.FolderBrowse("Browse", target="-INST-")],
        [sg.Text("")],
        [sg.Button("Next", key="-NEXT-", size=(10, 1)),
         sg.Button("Cancel", key="-CANCEL-", size=(10, 1))],
    ]
    win1 = sg.Window("Add World (1/2)", layout1, finalize=True, modal=True)
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
                    "Please select a valid instance folder.\n"
                    "(It must contain a 'saves' folder)",
                    title="Error")
                continue
            instance_path = p
            break
    win1.close()

    # Step 2: list worlds in saves/
    saves_dir = os.path.join(instance_path, "saves")
    world_dirs = sorted([
        d for d in os.listdir(saves_dir)
        if os.path.isdir(os.path.join(saves_dir, d))
        and not d.startswith(".")
    ])
    if not world_dirs:
        sg.popup_error("No worlds found in saves folder.\n"
                       "Create a world in Minecraft first.",
                       title="Error")
        return None

    layout2 = [
        [sg.Text("Add New World (2/2)",
                 font=("Helvetica", 12, "bold"))],
        [sg.HorizontalSeparator()],
        [sg.Text("Select the world to share:")],
        [sg.Listbox(world_dirs, size=(40, 10), key="-WSEL-",
                    select_mode=sg.LISTBOX_SELECT_MODE_SINGLE)],
        [sg.Text("")],
        [sg.Button("Add", key="-ADD-", size=(10, 1)),
         sg.Button("Cancel", key="-CANCEL-", size=(10, 1))],
    ]
    win2 = sg.Window("Add World (2/2)", layout2, finalize=True, modal=True)
    result = None
    while True:
        event, values = win2.read()
        if event in (sg.WIN_CLOSED, "-CANCEL-"):
            break
        if event == "-ADD-":
            sel = values["-WSEL-"]
            if not sel:
                sg.popup_error("Please select a world.", title="Error")
                continue
            wname = sel[0]
            if not add_world(gas_url, wname):
                sg.popup_error("Failed to add world.", title="Error")
                continue
            set_instance_path(wname, instance_path, base)
            result = wname
            break
    win2.close()
    return result


# --- settings dialog ---

def _show_settings(base: str, worlds: list[dict]) -> None:
    personal = load_personal(base)
    if not personal:
        return
    player_name = personal["player_name"]
    instance_paths = personal.get("instance_paths", {})

    rows = []
    rows.append([sg.Text("Player Name:"),
                 sg.Input(player_name, key="-SNAME-", size=(30, 1))])
    rows.append([sg.HorizontalSeparator()])
    rows.append([sg.Text("Instance paths per world:",
                         font=("Helvetica", 10, "bold"))])

    world_names = [w.get("world_name", "") for w in worlds]
    for wn in world_names:
        cur = instance_paths.get(wn, "")
        rows.append([
            sg.Text(f"  {wn}:", size=(18, 1)),
            sg.Input(cur, key=f"-SP-{wn}-", size=(30, 1)),
            sg.FolderBrowse("Browse", target=f"-SP-{wn}-"),
        ])

    layout = [
        [sg.Text("Settings", font=("Helvetica", 14, "bold"))],
        [sg.HorizontalSeparator()],
        *rows,
        [sg.Text("")],
        [sg.Button("Save", key="-SSAVE-", size=(10, 1)),
         sg.Button("Close", key="-SCLOSE-", size=(10, 1))],
    ]

    win = sg.Window("Settings", layout, finalize=True, modal=True)
    while True:
        event, values = win.read()
        if event in (sg.WIN_CLOSED, "-SCLOSE-"):
            break
        if event == "-SSAVE-":
            new_name = values["-SNAME-"].strip()
            if not new_name:
                sg.popup_error("Please enter a player name.", title="Error")
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
            sg.popup("Settings saved.", title="Done")
            break
    win.close()


# --- world display string ---

def _world_display(w: dict) -> str:
    name = w.get("world_name", "???")
    st = w.get("status", "offline")
    if st == "online":
        host = w.get("host", "")
        return f"[ON]  {name}  (host: {host})"
    return f"[--]  {name}"


# --- main layout ---

def _make_layout(worlds: list[dict], player_name: str) -> list:
    world_items = [_world_display(w) for w in worlds]

    left_col = [
        [sg.Text("Worlds", font=("Helvetica", 10, "bold"))],
        [sg.Listbox(world_items, size=(32, 12), key="-WLIST-",
                    enable_events=True, font=("Consolas", 10))],
        [sg.Button("+ Add World", key="-ADD-WORLD-", size=(14, 1))],
        [sg.Button("Delete", key="-DELETE-WORLD-", size=(14, 1),
                   button_color=("white", "firebrick"))],
    ]

    right_col = [
        [sg.Text("Details", font=("Helvetica", 10, "bold"))],
        [sg.Text("World:", size=(10, 1)),
         sg.Text("---", key="-D-NAME-", size=(25, 1),
                 font=("Helvetica", 10, "bold"))],
        [sg.Text("Status:", size=(10, 1)),
         sg.Text("---", key="-D-STATUS-", size=(25, 1))],
        [sg.Text("Host:", size=(10, 1)),
         sg.Text("---", key="-D-HOST-", size=(25, 1))],
        [sg.Text("Domain:", size=(10, 1)),
         sg.Text("---", key="-D-DOMAIN-", size=(25, 1))],
        [sg.Text("")],
        [sg.Button("Host", key="-HOST-", size=(12, 1)),
         sg.Button("Join", key="-JOIN-", size=(12, 1))],
        [sg.Button("Copy Domain", key="-COPY-DOMAIN-", size=(12, 1)),
         sg.Button("Open saves", key="-OPEN-SAVES-", size=(12, 1))],
        [sg.Button("Manual UL", key="-UPLOAD-", size=(12, 1)),
         sg.Button("Manual DL", key="-DOWNLOAD-", size=(12, 1))],
        [sg.Text("")],
        [sg.Text("Manual domain:", size=(14, 1)),
         sg.Input(key="-MANUAL-DOMAIN-", size=(20, 1)),
         sg.Button("Set", key="-SET-DOMAIN-", size=(5, 1))],
    ]

    layout = [
        [sg.Text("MC MultiDrive", font=("Helvetica", 18, "bold")),
         sg.Push(),
         sg.Text(f"Player: {player_name}",
                 font=("Helvetica", 10))],
        [sg.HorizontalSeparator()],
        [sg.Column(left_col, vertical_alignment="top"),
         sg.VSeperator(),
         sg.Column(right_col, vertical_alignment="top")],
        [sg.HorizontalSeparator()],
        [sg.Text("Log:", font=("Helvetica", 10, "bold"))],
        [sg.Multiline(size=(72, 10), key="-LOG-", autoscroll=True,
                      disabled=True, font=("Consolas", 9))],
        [sg.Button("Refresh", key="-REFRESH-", size=(8, 1)),
         sg.Button("Settings", key="-SETTINGS-", size=(8, 1)),
         sg.Push(),
         sg.Button("Exit", key="-EXIT-", size=(8, 1))],
    ]
    return layout


# --- log helper ---

def _log(window: sg.Window, msg: str) -> None:
    window["-LOG-"].update(msg + "\n", append=True)
    window.refresh()


# --- selected world ---

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


# --- detail panel update ---

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
        window["-D-STATUS-"].update("Online")
        window["-D-HOST-"].update(w.get("host", "---"))
        domain = w.get("domain", "")
        if domain and domain != "preparing...":
            window["-D-DOMAIN-"].update(domain)
        elif domain == "preparing...":
            window["-D-DOMAIN-"].update("Preparing...")
        else:
            window["-D-DOMAIN-"].update("---")
    else:
        window["-D-STATUS-"].update("Offline")
        window["-D-HOST-"].update("---")
        window["-D-DOMAIN-"].update("---")


# --- ensure instance path ---

def _ensure_instance_path(world_name: str, base: str) -> str | None:
    p = get_instance_path(world_name, base)
    if p and os.path.isdir(p):
        return p
    p = _ask_instance_path(world_name)
    if p:
        set_instance_path(world_name, p, base)
    return p


# --- host thread (background) ---

def _host_thread(window: sg.Window, config: dict) -> None:
    gas_url = config["gas_url"]
    player_name = config["player_name"]
    instance_path = config["curseforge_instance_path"]
    world_name = config["world_name"]
    lock_timeout = config["lock_timeout_hours"]

    def send(msg):
        window.write_event_value("-PRINT-", msg)

    try:
        send(f"[{world_name}] Checking status...")
        status_info = get_status(gas_url, world_name)
        status = status_info.get("status", "error")

        if status == "error":
            send(f"[{world_name}] Could not get status.")
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
                send(f"[{world_name}] Currently hosted by {host}.")
                window.write_event_value("-HOST-DONE-", False)
                return

        send(f"[{world_name}] Acquiring host lock...")
        if not set_online(gas_url, world_name, player_name):
            send(f"[{world_name}] Failed to acquire host lock.")
            window.write_event_value("-HOST-DONE-", False)
            return
        send(f"[{world_name}] Host acquired ({player_name})")

        if check_remote_world_exists(config):
            send(f"[{world_name}] Downloading world...")
            if not download_world(config):
                send(f"[{world_name}] Download failed.")
                set_offline(gas_url, world_name)
                window.write_event_value("-HOST-DONE-", False)
                return
            send(f"[{world_name}] Download complete!")
        else:
            send(f"[{world_name}] No world data on Drive (new world).")

        world_path = os.path.join(instance_path, "saves", world_name)
        if os.path.isdir(world_path):
            send(f"[{world_name}] Fixing level.dat...")
            fix_level_dat(world_path)

        send("=" * 50)
        send("Ready!")
        send("  1. Press Play in CurseForge")
        send(f"  2. Open world \"{world_name}\"")
        send("  3. Esc -> Open to LAN -> Start LAN World")
        send("=" * 50)
        send("Detecting e4mc domain...")
        send("If auto-detect fails, enter domain manually in the right panel and click 'Set'.")

        log_path = os.path.join(instance_path, "logs", "latest.log")

        # auto-detect in background thread
        domain_result = [None]
        def _auto_detect():
            domain_result[0] = watch_for_domain(log_path, timeout_seconds=600)
        detect_thread = threading.Thread(target=_auto_detect, daemon=True)
        detect_thread.start()

        # wait for auto-detect OR manual input
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
            send(f"[domain] {domain}")
            update_domain(gas_url, world_name, domain)
            _clipboard_copy(domain)
            send("Domain copied to clipboard.")
        else:
            send("[warning] e4mc domain not detected.")

        # -- wait for Minecraft exit + periodic autosave --
        send("Waiting for Minecraft to exit (autosave every 10 min)...")
        AUTOSAVE_INTERVAL = 600

        pid = find_minecraft_process()
        if not pid:
            send("[info] Waiting for Minecraft to start (up to 5 min)...")
            pid = wait_for_minecraft_start(timeout_seconds=300)

        if not pid:
            send("[info] Minecraft process not found. Please use Manual UL.")
            window.write_event_value("-HOST-DONE-", True)
            return

        send(f"[process] Minecraft detected (PID: {pid})")
        last_save = time.time()
        while True:
            try:
                proc = psutil.Process(pid)
                if not proc.is_running() or proc.status() == psutil.STATUS_ZOMBIE:
                    break
            except psutil.NoSuchProcess:
                break
            if time.time() - last_save >= AUTOSAVE_INTERVAL:
                send(f"[autosave] Uploading {world_name}...")
                upload_world(config)
                last_save = time.time()
                send("[autosave] Done.")
            time.sleep(3)

        send("[process] Minecraft exited.")
        time.sleep(3)

        send(f"[{world_name}] Creating backup...")
        create_backup(config)

        send(f"[{world_name}] Uploading...")
        if upload_world(config):
            send(f"[{world_name}] Upload complete!")
        else:
            send(f"[{world_name}] Upload failed.")

        set_offline(gas_url, world_name)
        send(f"[{world_name}] Session ended. Status set to offline.")
        window.write_event_value("-HOST-DONE-", True)

    except Exception as e:
        send(f"[error] Exception during host: {e}")
        try:
            set_offline(gas_url, world_name)
        except Exception:
            pass
        window.write_event_value("-HOST-DONE-", False)


# --- main loop ---

def main():
    base = _find_base()

    try:
        shared = load_shared(base)
    except (FileNotFoundError, ValueError) as e:
        sg.popup_error(
            f"Shared config error:\n{e}\n\n"
            "Make sure shared_config.json is next to the exe.",
            title="Startup Error",
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

        # --- stdout log ---
        if event == "-PRINT-":
            _log(window, values["-PRINT-"])

        # --- world selection ---
        if event == "-WLIST-":
            w = _selected_world(window, worlds)
            _update_detail(window, w)

        # --- refresh ---
        if event == "-REFRESH-":
            _log(window, "[refresh] Fetching status...")
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
            _log(window, f"[refresh] {len(worlds)} worlds found.")

        # --- add world ---
        if event == "-ADD-WORLD-":
            wname = _ask_new_world(gas_url, base)
            if wname:
                _log(window, f"[add] World \"{wname}\" added.")
                worlds = list_worlds(gas_url)
                items = [_world_display(w) for w in worlds]
                window["-WLIST-"].update(items)

        # --- delete world ---
        if event == "-DELETE-WORLD-":
            if hosting:
                sg.popup("Cannot delete while hosting.", title="Info")
                continue
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("Select a world first.", title="Info")
                continue
            w = _selected_world(window, worlds)
            if w and w.get("status") == "online":
                sg.popup("Cannot delete an online world.", title="Error")
                continue
            ans = sg.popup_yes_no(
                f"Delete world \"{wname}\"?\n\n"
                "Drive data will be moved to backups/.\n"
                "Delete from backups/ manually if needed.",
                title="Confirm Delete",
            )
            if ans == "Yes":
                config = build_config(wname, base)
                if config:
                    _log(window, f"[delete] Archiving {wname}...")
                    archive_ok = archive_world(config)
                    if archive_ok:
                        if delete_world(gas_url, wname):
                            _log(window, f"[delete] {wname} deleted.")
                        else:
                            _log(window, f"[error] GAS delete failed.")
                    else:
                        _log(window, f"[error] Archive failed.")
                else:
                    # config build failed (no instance path) - still delete from GAS
                    if delete_world(gas_url, wname):
                        _log(window, f"[delete] {wname} removed from list.")
                    else:
                        _log(window, f"[error] GAS delete failed.")
                worlds = list_worlds(gas_url)
                items = [_world_display(w) for w in worlds]
                window["-WLIST-"].update(items)
                _update_detail(window, None)

        # --- manual domain set ---
        if event == "-SET-DOMAIN-":
            global _manual_domain_value
            manual_d = values.get("-MANUAL-DOMAIN-", "").strip()
            if manual_d:
                _manual_domain_value = manual_d
                _manual_domain_event.set()
                _log(window, f"[manual] Domain set: {manual_d}")
                # Also update GAS if hosting
                if hosting:
                    wname = _selected_world_name(window, worlds)
                    if wname:
                        update_domain(gas_url, wname, manual_d)
            else:
                sg.popup("Please enter a domain.", title="Info")

        # --- host ---
        if event == "-HOST-":
            if hosting:
                sg.popup("Already hosting.", title="Info")
                continue
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("Select a world first.", title="Info")
                continue
            inst = _ensure_instance_path(wname, base)
            if not inst:
                continue
            config = build_config(wname, base)
            if not config:
                sg.popup_error("Config build failed.", title="Error")
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
                f"Lock expired for \"{wn}\".\n"
                f"(Previous host: {old_host})\n\n"
                "Force takeover?",
                title="Lock Expired",
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

        # --- join ---
        if event == "-JOIN-":
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("Select a world first.", title="Info")
                continue
            w = _selected_world(window, worlds)
            if not w or w.get("status") != "online":
                sg.popup("This world is offline.", title="Info")
                continue
            domain = w.get("domain", "")
            if not domain or domain == "preparing...":
                sg.popup("Domain not ready yet. Refresh and try again.",
                         title="Info")
                continue
            inst = _ensure_instance_path(wname, base)
            if inst:
                server_label = f"MC MultiDrive - {wname}"
                update_servers_dat(inst, domain, server_label)
            _clipboard_copy(domain)
            _log(window, f"[join] {domain} copied to clipboard.")
            sg.popup(
                f"Domain copied:\n{domain}\n\n"
                "Launch Minecraft -> Multiplayer -> Direct Connect / paste.",
                title="Join Info",
            )

        # --- copy domain ---
        if event == "-COPY-DOMAIN-":
            w = _selected_world(window, worlds)
            if w and w.get("domain") and w["domain"] != "preparing...":
                _clipboard_copy(w["domain"])
                _log(window, f"[copy] {w['domain']}")
            else:
                sg.popup("No domain to copy.", title="Info")

        # --- open saves ---
        if event == "-OPEN-SAVES-":
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("Select a world first.", title="Info")
                continue
            inst = get_instance_path(wname, base)
            if inst:
                saves_path = os.path.join(inst, "saves")
                if os.path.isdir(saves_path):
                    _open_folder(saves_path)
                else:
                    sg.popup(f"saves folder not found:\n{saves_path}",
                             title="Error")
            else:
                sg.popup("Instance path not set.\nUse Settings to configure.",
                         title="Info")

        # --- manual upload ---
        if event == "-UPLOAD-":
            if hosting:
                sg.popup("Cannot upload while hosting.", title="Info")
                continue
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("Select a world first.", title="Info")
                continue
            inst = _ensure_instance_path(wname, base)
            if not inst:
                continue
            ans = sg.popup_yes_no(
                f"Upload world \"{wname}\" to Google Drive?\n"
                "Drive data will be overwritten.",
                title="Confirm Upload",
            )
            if ans == "Yes":
                config = build_config(wname, base)
                if config:
                    _log(window, f"[upload] {wname} uploading...")
                    threading.Thread(
                        target=lambda c=config: (
                            upload_world(c),
                            window.write_event_value("-REFRESH-", None),
                        ),
                        daemon=True,
                    ).start()

        # --- manual download ---
        if event == "-DOWNLOAD-":
            if hosting:
                sg.popup("Cannot download while hosting.", title="Info")
                continue
            wname = _selected_world_name(window, worlds)
            if not wname:
                sg.popup("Select a world first.", title="Info")
                continue
            inst = _ensure_instance_path(wname, base)
            if not inst:
                continue
            ans = sg.popup_yes_no(
                f"Download world \"{wname}\" from Google Drive?\n"
                "Local data will be overwritten.",
                title="Confirm Download",
            )
            if ans == "Yes":
                config = build_config(wname, base)
                if config:
                    _log(window, f"[download] {wname} downloading...")
                    threading.Thread(
                        target=lambda c=config: (
                            download_world(c),
                            window.write_event_value("-REFRESH-", None),
                        ),
                        daemon=True,
                    ).start()

        # --- settings ---
        if event == "-SETTINGS-":
            _show_settings(base, worlds)
            personal = load_personal(base)
            if personal:
                player_name = personal["player_name"]

    window.close()


if __name__ == "__main__":
    main()
