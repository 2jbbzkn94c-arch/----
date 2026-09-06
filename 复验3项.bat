@echo off
rem Re-run the three fixed/affected scenes with live console output.
cd /d "%~dp0"
set GODOT=C:\Users\79076\Desktop\Godot_v4.7.1-stable_win64.exe

echo ================= SubVerify =================
"%GODOT%" --headless --scene res://tests/SubVerify.tscn
echo SubVerify exit code: %errorlevel%
echo.

echo ================= NetSubmitVerify =================
"%GODOT%" --headless --scene res://tests/NetSubmitVerify.tscn
echo NetSubmitVerify exit code: %errorlevel%
echo.

echo ================= NetFullMatchVerify (format fix check) =================
"%GODOT%" --headless --scene res://tests/NetFullMatchVerify.tscn
echo NetFullMatchVerify exit code: %errorlevel%
echo.

pause
