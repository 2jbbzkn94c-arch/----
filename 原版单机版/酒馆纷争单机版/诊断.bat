@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Tavern Brawl - Diagnose

echo ============================================================
echo   Diagnose: which layer is broken?
echo ============================================================
echo.

if exist "tb_start.exe" (
    tb_start.exe --doctor
    goto done
)

python doctor.py
if errorlevel 1 (
    py doctor.py
)

:done
echo.
echo ============================================================
echo  Copy everything above and send it back.
echo ============================================================
pause
