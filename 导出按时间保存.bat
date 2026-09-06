@echo off
cd /d "%~dp0"
set GODOT=C:\Users\79076\Desktop\Godot_v4.7.1-stable_win64.exe
if not exist "%GODOT%" set GODOT=godot

for /f "delims=" %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set TS=%%i
if "%TS%"=='' set TS=%date:~0,4%%date:~5,2%%date:~8,2%-%time:~0,2%%time:~3,2%%time:~6,2%

set OUTDIR=export\·¢²¼
if not exist "%OUTDIR%" mkdir "%OUTDIR%"
set OUT=%OUTDIR%\¾Æ¹Ý·×Õù-%TS%.exe
echo exporting: %OUT%
echo.
"%GODOT%" --headless --path "%CD%" --export-release "Windows Desktop" "%CD%\%OUT%"
echo.
echo export finished, exit code %errorlevel%
echo new file: %OUT%
pause
