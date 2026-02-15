@echo off
chcp 65001 >nul 2>&1
echo === MC MultiDrive Build ===
echo.

pip install pyinstaller FreeSimpleGUI requests nbtlib psutil pyperclip

pyinstaller --onefile --noconsole --name MCMultiDrive main.py --hidden-import=nbtlib --hidden-import=FreeSimpleGUI

echo.
echo === Build Complete ===
echo.

if not exist "dist\release" mkdir "dist\release"
copy dist\MCMultiDrive.exe dist\release\
if exist shared_config.json copy shared_config.json dist\release\
if not exist "dist\release\rclone" mkdir "dist\release\rclone"
if exist "rclone\rclone.exe" copy rclone\rclone.exe dist\release\rclone\
if exist "rclone.conf" copy rclone.conf dist\release\

echo.
echo === dist\release folder is ready to distribute ===
pause
