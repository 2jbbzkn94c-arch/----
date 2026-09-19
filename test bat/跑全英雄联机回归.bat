@echo off
chcp 936 >nul
echo ===========================================================================
echo   【用途】联机（双端同步）全英雄回归：headless 跑 tests\NetAllHeroResetVerify.tscn，
echo           逐个英雄打印 PASS/FAIL，确认联机重开 / 状态同步没被改坏。
echo   【用法】双击即可，不需要参数；跑完在本窗口看 PASS/FAIL 汇总行。
echo           完整日志：%TEMP%\net_all_hero.log
echo   【详细说明】见本文件开头的 rem 注释（第 3 行起）
echo ===========================================================================

echo.
rem ===========================================================================
rem  【用途】联机（双端同步）全英雄回归：headless 跑 tests\NetAllHeroResetVerify.tscn，
rem          逐个英雄打印 PASS/FAIL —— 用来确认「联机重开 / 状态同步」没被改坏。
rem  【用法】双击即可，**不需要参数**；跑完在本窗口看 PASS/FAIL 汇总行。
rem          完整日志：%TEMP%\net_all_hero.log
rem  【注意】会占用一个 Godot 实例（无窗口）。跑之前最好先关掉正在玩的实例/检视器，
rem          避免多个实例争用同一个 user:// 目录（那会导致启动即崩、日志为空）。
rem  【依赖】项目根目录（本脚本按 %~dp0.. 定位）；Godot 路径写在脚本里，找不到就退回 PATH 里的 godot。
rem ===========================================================================
setlocal
title Net All-Hero Regression
set "GODOT=C:\Users\79076\Desktop\Godot_v4.7.1-stable_win64.exe"
if not exist "%GODOT%" set "GODOT=godot"
cd /d "%~dp0.."
set "LOG=%TEMP%\net_all_hero.log"
if exist "%LOG%" del "%LOG%"
echo Running all-hero online regression (headless)...
"%GODOT%" --headless --scene res://tests/NetAllHeroResetVerify.tscn >> "%LOG%" 2>&1
echo.
echo ---------- result ----------
findstr /C:"PASS" /C:"FAIL" /C:"====" "%LOG%"
echo -----------------------------
echo Full log: %LOG%
pause
