@echo off
chcp 936 >nul
setlocal
set "PS1="
if exist "%~dp0refresh_ai_parse.ps1" set "PS1=%~dp0refresh_ai_parse.ps1"
if not defined PS1 if exist "%~dp0..\Source\refresh_ai_parse.ps1" set "PS1=%~dp0..\Source\refresh_ai_parse.ps1"
if not defined PS1 if exist "%~dp0..\refresh_ai_parse.ps1" set "PS1=%~dp0..\refresh_ai_parse.ps1"
if not defined PS1 (
  echo [错误] 找不到 refresh_ai_parse.ps1
  echo 这个 bat 可以和 refresh_ai_parse.ps1 放在同一个文件夹，
  echo 或者放在 Data\Hero\Source / 项目根目录 里（脚本会自己找）：
  pause
  exit /b 1
)
echo 刷新 AI 解析：xlsx -^> json -^> 解析体检.txt / 角色协同解析.txt
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
echo.
pause
exit /b 0
