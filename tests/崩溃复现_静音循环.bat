@echo off
setlocal
title Crash Repro - Dummy Audio x3
set "GODOT=C:\Users\79076\Desktop\Godot_v4.7.1-stable_win64.exe"
if not exist "%GODOT%" set "GODOT=godot"
set "PROJ=%~dp0.."
set "LOG=%TEMP%\godot_dummy3.log"
if exist "%LOG%" del "%LOG%"
for /L %%i in (1,1,3) do (
	echo === run %%i (dummy audio) === >> "%LOG%"
	"%GODOT%" --audio-driver Dummy --path "%PROJ%" --verbose >> "%LOG%" 2>&1
	echo RUN%%i_EXIT=%ERRORLEVEL% >> "%LOG%"
)
echo.
echo ---------- summary ----------
findstr /C:"RUN1_EXIT" /C:"RUN2_EXIT" /C:"RUN3_EXIT" /C:"ERROR:" /C:"FATAL" "%LOG%"
echo -----------------------------
echo Full log: %LOG%
pause
