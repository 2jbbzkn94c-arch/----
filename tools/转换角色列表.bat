@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0角色列表转Json.ps1"
echo.
echo done: 角色列表.json
pause
