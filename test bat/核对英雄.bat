@echo off
chcp 936 >nul
echo ===========================================================================
echo   【用途】核对「AI 预测」与「真实战斗」是否一致：① 矩阵对拍 ② 检视器 sweep。
echo           出现「判定 DIFF」= 不一致；「判定 不可比」不计入 DIFF。
echo   【用法】双击 = 默认（hero_26，12 招）。带参数示例：
echo           核对英雄.bat -All -Acts 24 -Seed 7        全 49 英雄（30~60 分钟）
echo           核对英雄.bat -Heroes hero_48,hero_40      只查这两个英雄
echo           核对英雄.bat -Heroes hero_50 -SkipSweep   只跑矩阵
echo           退出码：0=全绿 1=有真实 DIFF 2=预检失败；日志 RL\reports\verify_*.log
echo   【详细说明】见本文件开头的 rem 注释（第 3 行起）
echo ===========================================================================

echo.
rem ===========================================================================
rem  【用途】同 verify_heroes.bat，只是文件名是中文的（双击更好认，便于日常用）。
rem          两层的含义：① 矩阵对拍（技能×场景）② 检视器 sweep（真实对局逐招预测）。
rem  【用法】双击 = 默认（hero_26，12 招）。常见用法：
rem            核对英雄.bat -All -Acts 24 -Seed 7      全 49 英雄一轮验收
rem            核对英雄.bat -Heroes hero_48,hero_40    只查这两个英雄
rem            核对英雄.bat -Heroes hero_50 -SkipSweep 只跑矩阵（跳过真实对局）
rem          退出码：0=全绿；1=有真实 DIFF；2=预检失败；日志在 RL\reports\verify_*.log
rem  【注意】可执行行刻意保持纯 ASCII；中文只出现在这些 rem 注释里。本文件存为 GBK（cmd 默认 ANSI），
rem          cmd 只按字节读"非注释"内容，所以注释的编码不影响执行 —— 但**别在可执行行/echo 里写中文**。
rem ===========================================================================
rem ---------------------------------------------------------------------------
rem  RL\hero-check.bat  --  double-click entry (Chinese-named on purpose).
rem
rem  Content is deliberately PURE ASCII: cmd.exe reads .bat/.ps1 as ANSI, so a
rem  Chinese literal inside a script is the exact hazard that once truncated
rem  hero files. The real logic lives in RL\verify_heroes.ps1 (also pure ASCII)
rem  and is located by ASCII name, so nothing here needs a non-ASCII byte.
rem
rem  Usage (double-click = defaults below):
rem    -Heroes hero_26,hero_22
rem    -All -Acts 16 -Seed 7
rem    -Heroes hero_50 -SkipMatrix -SkipSweep
rem    -BothSides
rem  Exit code: 0 = all green, 1 = real DIFF found, 2 = preflight failed.
rem ---------------------------------------------------------------------------
setlocal
set "PS1="
if exist "%~dp0verify_heroes.ps1" set "PS1=%~dp0verify_heroes.ps1"
if not defined PS1 if exist "%~dp0..\RL\verify_heroes.ps1" set "PS1=%~dp0..\RL\verify_heroes.ps1"
if not defined PS1 if exist "%~dp0..\verify_heroes.ps1" set "PS1=%~dp0..\verify_heroes.ps1"
set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

if not exist "%PS1%" (
	echo  [ERROR] verify_heroes.ps1 not found next to this .bat.
	echo          expected: %PS1%
	echo.
	pause
	endlocal
	exit /b 2
)

if "%~1"=="" (
	"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Heroes hero_26 -Acts 12
) else (
	"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
)
set "RC=%ERRORLEVEL%"
echo.
echo  exit code = %RC%   (0 = all green, 1 = DIFF found, 2 = preflight failed)
echo.
pause
endlocal
exit /b %RC%
