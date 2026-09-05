@echo off
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
