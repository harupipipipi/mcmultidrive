"""nbt_editor.py - level.dat / servers.dat NBT編集"""

import os
import shutil

import nbtlib
from nbtlib.tag import Compound, List, String, Byte


def fix_level_dat(world_path: str) -> bool:
    level_dat_path = os.path.join(world_path, "level.dat")
    if not os.path.isfile(level_dat_path):
        print("[情報] level.dat が見つかりません（新規ワールドの可能性があります）。")
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
                print("[NBT] level.dat から Player タグを削除しました。")
            else:
                print("[NBT] Player タグは存在しません（削除不要）。")
        else:
            print("[警告] level.dat に Data タグが見つかりません。")
        return True
    except Exception as e:
        print(f"[エラー] level.dat の編集に失敗しました: {e}")
        return False


def update_servers_dat(instance_path: str, server_ip: str, server_name: str = "ATM10 Session") -> bool:
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
        print(f"[NBT] servers.dat を更新しました: {server_name} → {server_ip}")
        return True
    except Exception as e:
        print(f"[エラー] servers.dat の編集に失敗しました: {e}")
        return False
