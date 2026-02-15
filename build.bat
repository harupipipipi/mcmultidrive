@echo off
echo === MC MultiDrive ビルド ===
echo.

pip install pyinstaller FreeSimpleGUI requests nbtlib psutil pyperclip

pyinstaller --onefile --noconsole --name MCMultiDrive main.py --hidden-import=nbtlib --hidden-import=FreeSimpleGUI

echo.
echo === ビルド完了 ===
echo dist\MCMultiDrive.exe が生成されました。
echo.
echo 配布フォルダを作成します...

if not exist "dist\release" mkdir "dist\release"
copy dist\MCMultiDrive.exe dist\release\
copy shared_config.json dist\release\
if not exist "dist\release\rclone" mkdir "dist\release\rclone"
if exist "rclone\rclone.exe" copy rclone\rclone.exe dist\release\rclone\
if exist "rclone.conf" copy rclone.conf dist\release\

echo.
echo === dist\release フォルダの中身を配布してください ===
echo 各自が rclone.conf を追加する必要はありません（同梱済み）。
pause
