@echo off
echo === ATM10 Session Manager ビルド ===
echo.

pip install pyinstaller FreeSimpleGUI requests nbtlib psutil pyperclip

pyinstaller --onefile --noconsole --name ATM10SessionManager main.py --hidden-import=nbtlib --hidden-import=FreeSimpleGUI

echo.
echo === ビルド完了 ===
echo dist\ATM10SessionManager.exe が生成されました。
echo.
echo 配布フォルダを作成します...

if not exist "dist\release" mkdir "dist\release"
copy dist\ATM10SessionManager.exe dist\release\
copy shared_config.json dist\release\
if not exist "dist\release\rclone" mkdir "dist\release\rclone"
if exist "rclone\rclone.exe" copy rclone\rclone.exe dist\release\rclone\

echo.
echo === dist\release フォルダの中身を配布してください ===
echo 各自が rclone.conf を追加して使います。
pause
