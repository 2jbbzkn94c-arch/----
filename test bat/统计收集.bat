@echo off
chcp 936 >nul
echo ===========================================================================
echo   【用途】对局统计收集：无头跑 N 局真实对局（3v3 或 5v5=上场3+替补2），
echo           把每局与每个单位的数据落成 CSV（做强度榜 / 组合榜 / 对位胜率矩阵用）。
echo   【用法】双击 = 默认（3v3、10 局、seed 7、beam 50）。带参数示例：
echo           统计收集.bat -Mode 5v5 -Games 20 -Seed 100    5v5 20 局
echo           统计收集.bat -Games 10 -Beam 800 -Workers 2   大宽度 + 2 并发（上限就是 2）
echo           可转交参数：-Mode -Games -Seed -Beam -Workers -Tag -Speed -WeightsA -WeightsB
echo           产物：RL\reports\stats\matches_*.csv 与 units_*.csv（含固定名 matches.csv/units.csv）
echo   【详细说明】见本文件开头的 rem 注释（第 3 行起）
echo ===========================================================================

echo.
rem ===========================================================================
rem  【用途】对局统计收集：无头跑 N 局真实对局（3v3 或 5v5=上场3+替补2），把每局与每个
rem          单位的数据落成 CSV —— 供后续做英雄强度榜 / 组合强度榜 / 对位胜率矩阵。
rem          真正的逻辑在 RL\stats\collect_stats.ps1（本 bat 只是一键外壳，转交全部参数）。
rem  【用法】双击 = 默认（3v3、10 局、seed 7、beam 50）。
rem            统计收集.bat                                     默认
rem            统计收集.bat -Mode 5v5 -Games 20 -Seed 100        5v5（上场3+替补2）20 局
rem            统计收集.bat -Games 10 -Beam 800 -Workers 2        大搜索宽度 + 2 并发（上限就是2）
rem            统计收集.bat -Mode 3v3 -Games 10 -Tag trial       自定义 tag（进文件名）
rem          可转交的参数：-Mode -Games -Seed -Beam -Workers -Tag -Speed
rem                      -WeightsA -WeightsB -Godot -Project -TimeoutSec
rem          产物：RL\reports\stats\matches_<tag>_<时间戳>.csv 与 units_<tag>_<时间戳>.csv，
rem                并各覆盖一份固定名 matches.csv / units.csv（= 最新一次合并结果）；
rem                每个 worker 的原始 CSV 与日志在 RL\reports\stats\parts\<tag>_<时间戳>\。
rem  【注意】会占用 Godot 实例（无头）。脚本自己保证总并发 <= 2，并给每个实例独立 APPDATA。
rem          本 bat 不含 pause（便于被 cmd /c 直接调用）；双击时窗口跑完即关，
rem          结果路径与每局摘要都打在窗口里，也可右键“在终端中运行”。
rem  【依赖】RL\stats\collect_stats.ps1 —— 按 同目录 / ..\RL\stats\ / ..\RL\ / 项目根 四处找它。
rem  【约定】下面所有**可执行行**一律纯 ASCII（中文只出现在这些 rem 注释里）：
rem          cmd 按 ANSI/GBK 逐字节读 .bat，中文多字节里若出现 0x28/0x29 这类半角符号字节，
rem          会把 if 的括号块解析坏（本项目实测踩过：两个分支都被执行）。
rem ===========================================================================
setlocal
set "PS1="
if exist "%~dp0collect_stats.ps1" set "PS1=%~dp0collect_stats.ps1"
if not defined PS1 if exist "%~dp0..\RL\stats\collect_stats.ps1" set "PS1=%~dp0..\RL\stats\collect_stats.ps1"
if not defined PS1 if exist "%~dp0..\RL\collect_stats.ps1" set "PS1=%~dp0..\RL\collect_stats.ps1"
if not defined PS1 if exist "%~dp0..\collect_stats.ps1" set "PS1=%~dp0..\collect_stats.ps1"
if not defined PS1 goto :nops1

set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

if "%~1"=="" goto :defaults
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
goto :done

:defaults
echo  No arguments - running the default: 3v3, 10 games, seed 7, beam 50.
echo  Pass your own flags, e.g.  -Mode 5v5 -Games 20 -Seed 100
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode 3v3 -Games 10 -Seed 7 -Beam 50
goto :done

:nops1
echo  [ERROR] collect_stats.ps1 not found.
echo          looked in: this folder / ..\RL\stats\ / ..\RL\ / project root
endlocal
exit /b 2

:done
set "RC=%ERRORLEVEL%"
echo.
echo  exit code = %RC%    [0 = ok, 1 = a worker failed or no rows, 2 = preflight failed]
echo  results   = RL\reports\stats\matches.csv  and  units.csv  plus timestamped copies
endlocal
exit /b %RC%
