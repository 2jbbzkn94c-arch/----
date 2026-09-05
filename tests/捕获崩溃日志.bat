@echo off
setlocal
title Godot Crash Capture
cd /d "%~dp0.."
set "LOGFILE=%TEMP%\godot_crash_output.log"
set "GODOT=C:\Users\79076\Desktop\Godot_v4.7.1-stable_win64.exe"
if not exist "%GODOT%" set "GODOT=godot"

echo === START %date% %time% === > "%LOGFILE%"
echo cmd: "%GODOT%" --path "%~dp0.." --verbose >> "%LOGFILE%"

"%GODOT%" --path "%~dp0.." --verbose >> "%LOGFILE%" 2>&1
set "CODE=%ERRORLEVEL%"
echo === EXIT_CODE=%CODE% === >> "%LOGFILE%"
echo.

echo === Windows Application Event (Godot, last 20 min) === >> "%LOGFILE%"
powershell -NoProfile -Command "$d=(Get-Date).AddMinutes(-20); $ev=Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$d} -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -match 'Windows Error Reporting|Application Error|.NET Runtime' -and $_.Message -match 'Godot' }; if ($ev) { $ev | Select-Object -First 3 TimeCreated, Id, ProviderName | Format-List | Out-String } else { 'no Godot crash event found in last 20 min' }" >> "%LOGFILE%" 2>&1

echo === Godot user:// logs (recent) === >> "%LOGFILE%"
powershell -NoProfile -Command "Get-ChildItem \"$env:APPDATA\Godot\app_userdata\" -Recurse -Filter *.log -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 6 FullName, LastWriteTime | Out-String" >> "%LOGFILE%" 2>&1

echo.
echo Log written to: %LOGFILE%
start notepad "%LOGFILE%"
pause
