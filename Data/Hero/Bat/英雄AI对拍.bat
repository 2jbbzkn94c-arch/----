@echo off
chcp 936 >nul
setlocal
set "PS1="
if exist "%~dp0..\Source\英雄AI对拍.ps1" set "PS1=%~dp0..\Source\英雄AI对拍.ps1"
if not defined PS1 if exist "%~dp0英雄AI对拍.ps1" set "PS1=%~dp0英雄AI对拍.ps1"
if not defined PS1 if exist "%~dp0..\..\..\RL\train\英雄AI对拍.ps1" set "PS1=%~dp0..\..\..\RL\train\英雄AI对拍.ps1"
if not defined PS1 (
  echo [错误] 找不到 英雄AI对拍.ps1
  echo 它应该在 Data\Hero\Source\ 里（本 bat 在 Data\Hero\Bat\）。
  pause
  exit /b 2
)
echo.
echo 英雄 AI 对拍：AI 预测的结算  vs  实际打出来的结算
echo （新加英雄 / 改了技能效果之后跑一遍；跑之前请关掉游戏和其它跑批）
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" echo [结果] 退出码 0：没发现差异（若你刚才跑的是 -List / -DryRun，这只是回显）。
if "%RC%"=="1" echo [结果] 有真实差异（DIFF）—— 看上面红色的行和 RL\reports 里的日志。
if "%RC%"=="2" echo [结果] 预检/环境失败 —— 什么都没跑成，看日志开头。
echo.
pause
exit /b %RC%