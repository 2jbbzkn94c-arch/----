@echo off
chcp 936 >nul
setlocal
set "PS1="
if exist "%~dp0Source\一键更新AI选择池.ps1" set "PS1=%~dp0Source\一键更新AI选择池.ps1"
if not defined PS1 if exist "%~dp0一键更新AI选择池.ps1" set "PS1=%~dp0一键更新AI选择池.ps1"
if not defined PS1 if exist "%~dp0..\Source\一键更新AI选择池.ps1" set "PS1=%~dp0..\Source\一键更新AI选择池.ps1"
if not defined PS1 (
  echo [错误] 找不到 一键更新AI选择池.ps1
  echo 它应该在 Data\Team\Source\ 里（也就是本 bat 旁边的 Source 子文件夹）。
  pause
  exit /b 1
)
echo.
echo 一键更新 AI 选择池：Data\Team\队伍池.md  -^>  RL\weights\队伍池.json
echo （会自动备份旧池子到 RL\backups\；要点时间，请等它跑完）
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
if errorlevel 1 (
  echo.
  echo [出错] 上面有红字，生效池子没被改动。
)
echo.
pause
exit /b 0