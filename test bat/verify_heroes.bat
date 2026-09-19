@echo off
chcp 936 >nul
echo ===========================================================================
echo   【用途】同 核对英雄.bat（英文名版，给命令行/脚本调）：核对 AI 预测 vs 真实战斗。
echo   【用法】双击 = 默认（hero_26，12 招）。带参数示例：
echo           verify_heroes.bat -All -Acts 24 -Seed 7      全 49 英雄
echo           verify_heroes.bat -Heroes hero_16 -SkipMatrix 只跑 sweep
echo           verify_heroes.bat -Heroes hero_43 -BothSides  敌我各扫一遍
echo           退出码：0=全绿 1=有真实 DIFF 2=预检失败；日志 RL\reports\verify_*.log
echo   【详细说明】见本文件开头的 rem 注释（第 3 行起）
echo ===========================================================================

echo.
rem ===========================================================================
rem  【用途】一键核对「AI 预测」与「真实战斗」是否一致 —— RL 候选 AI 的验收工具。
rem          每个英雄跑两层：① 矩阵对拍（场景级，一个技能一个场景）
rem                          ② 检视器 sweep（真实对局里逐招比对预测）
rem          判定口径：出现「判定 DIFF」= 模拟与真实不一致；「判定 不可比」不计入 DIFF。
rem  【用法】双击 = 跑默认（hero_26，12 招）。带参数示例：
rem            verify_heroes.bat -All -Acts 24 -Seed 7        全 49 英雄（约 30~60 分钟）
rem            verify_heroes.bat -Heroes hero_16 -Acts 24     只查一个英雄
rem            verify_heroes.bat -Heroes hero_40 -SkipMatrix   只跑检视器 sweep（跳过矩阵）
rem            verify_heroes.bat -Heroes hero_43 -BothSides    敌我两侧各扫一遍
rem            verify_heroes.bat -Beam 800                    用大搜索宽度（默认 50，扫 DIFF 不必大）
rem          退出码：0=全绿；1=有真实 DIFF；2=预检失败（harness 场景加载不了）
rem          完整日志：RL\reports\verify_<时间戳>*.log（失败时窗口里也会提示）
rem  【依赖】RL\verify_heroes.ps1 —— 本脚本会自动到 同目录 / ..\RL\ / 项目根 三处找它
rem ===========================================================================
rem ---------------------------------------------------------------------------
rem  RL\verify_heroes.bat  --  double-click wrapper for RL\verify_heroes.ps1
rem
rem  Pure ASCII on purpose (cmd reads .bat as ANSI). Forwards every argument.
rem  Prefers PowerShell 7+ (pwsh) because it reads .ps1/UTF-8 correctly; falls back
rem  to Windows PowerShell (the .ps1 itself is pure ASCII, so 5.1 is safe too).
rem
rem  Examples:
rem    verify_heroes.bat                        (double-click = defaults below)
rem    verify_heroes.bat -Heroes hero_26,hero_22
rem    verify_heroes.bat -All -Acts 16 -Seed 7
rem    verify_heroes.bat -Heroes hero_50 -SkipMatrix -SkipSweep
rem ---------------------------------------------------------------------------
setlocal
set "PS1="
if exist "%~dp0verify_heroes.ps1" set "PS1=%~dp0verify_heroes.ps1"
if not defined PS1 if exist "%~dp0..\RL\verify_heroes.ps1" set "PS1=%~dp0..\RL\verify_heroes.ps1"
if not defined PS1 if exist "%~dp0..\verify_heroes.ps1" set "PS1=%~dp0..\verify_heroes.ps1"
if not defined PS1 (
	echo  [ERROR] verify_heroes.ps1 not found - looked in: this folder / ..\RL\ / project root
	pause
	exit /b 2
)
set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

if "%~1"=="" (
	echo.
	echo  No arguments given - running the default self-check: hero_26 with 12 actions.
	echo  Pass your own flags, e.g.:  verify_heroes.bat -Heroes hero_50,hero_25 -Acts 16
	echo.
	"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Heroes hero_26 -Acts 12
) else (
	"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
)
set "RC=%ERRORLEVEL%"
echo.
echo  exit code = %RC%   (0 = all green, 1 = DIFF found, 2 = preflight failed)
if not "%RC%"=="0" (
	echo  Full log: look at RL\reports\verify_*.log
)
echo.
pause
endlocal
exit /b %RC%
