@echo off
chcp 65001 >nul
setlocal EnableExtensions
cd /d "%~dp0"

echo ============================================
echo   酒馆纷争 - 一键发布(自动写入发布日期并导出)
echo ============================================
echo.

set "GODOT=C:\Users\79076\Desktop\Godot_v4.7.1-stable_win64.exe"
if not exist "%GODOT%" (
    set /p "GODOT=未找到默认 Godot,请输入 Godot 可执行文件完整路径: "
)

echo 选择导出目标:
echo   1 = Android APK
echo   2 = Windows 桌面版
echo   3 = 两者都要
set /p "TGT=输入 1 / 2 / 3 (回车=Android): "
if "%TGT%"=="" set TGT=1

if not exist "build" mkdir build

echo.
echo 正在写入发布日期(精确到分)...
for /f %%T in ('powershell -NoProfile -Command "(Get-Date).ToString('yyyy-MM-dd HH:mm')"') do set "STAMP=%%T"
if "%STAMP%"=="" (
    echo [失败] 无法取得当前时间
    pause
    exit /b 1
)
echo 本版发布日期: %STAMP%

powershell -NoProfile -Command "$q=[char]34; $p='project.godot'; $s=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8); $s=[regex]::Replace($s, 'config/version_date='+$q+'[^'+$q+']*'+$q, 'config/version_date='+$q+'%STAMP%'+$q); [IO.File]::WriteAllText($p,$s,(New-Object Text.UTF8Encoding $false))"
if errorlevel 1 (
    echo [失败] 写入 project.godot 失败
    pause
    exit /b 1
)
echo [完成] 已更新 project.godot 中的 config/version_date = %STAMP%
echo.

if "%TGT%"=="2" goto win
if "%TGT%"=="3" goto both

:android
echo 正在导出 Android APK(可能需要几分钟)...
"%GODOT%" --headless --path "%CD%" --export-release "Android" "build\TavernBattle.apk"
echo.
echo APK 输出: %CD%\build\TavernBattle.apk
if "%TGT%"=="1" goto end

:both
echo.
echo 正在导出 Android APK(可能需要几分钟)...
"%GODOT%" --headless --path "%CD%" --export-release "Android" "build\TavernBattle.apk"
echo APK 输出: %CD%\build\TavernBattle.apk

:win
echo.
echo 正在导出 Windows 桌面版...
"%GODOT%" --headless --path "%CD%" --export-release "Windows Desktop" "build\TavernBattle_win.exe"
echo Windows 输出: %CD%\build\TavernBattle_win.exe

:end
echo.
echo 发布完成!产物在 build 目录。记得把 config/version_date 一起提交(如需)。
pause
