@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Tavern Brawl Offline

rem ---- self-elevate (firewall rules need admin) ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ============================================================
echo   Tavern Brawl  -  Offline Single Player
echo ============================================================
echo.

rem ---- firewall rules (once). The DNS hijack needs them. ----
netsh advfirewall firewall show rule name="jg_dns" >nul 2>&1
if %errorlevel% neq 0 (
    echo [..] Adding firewall rules...
    netsh advfirewall firewall add rule name="jg_dns" dir=in action=allow protocol=UDP localport=15353 >nul
    netsh advfirewall firewall add rule name="jg_game" dir=in action=allow protocol=TCP localport=2201 >nul
    echo [OK] Firewall rules added.
) else (
    echo [OK] Firewall rules already present.
)

echo.
echo ============================================================
echo   Starting... (keep this window open while playing)
echo ============================================================
echo.

rem ---- prefer the bundled exe (no Python needed); fall back to .py ----
if exist "tb_start.exe" (
    tb_start.exe %*
    goto done
)

set PY=
where python >nul 2>&1 && set PY=python
if "%PY%"=="" (
    where py >nul 2>&1 && set PY=py
)
if "%PY%"=="" (
    echo [X] Neither tb_start.exe nor Python was found.
    echo     The package looks incomplete - re-extract the zip.
    echo.
    pause
    exit /b 1
)
echo [i] Using Python fallback: %PY%
%PY% run_on_emulator.py %*

:done
echo.
echo ============================================================
echo  Finished.  If something went wrong, run  doctor.bat
echo  and send its full output back.
echo ============================================================
pause
