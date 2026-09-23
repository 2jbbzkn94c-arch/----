@echo off
cd /d "%~dp0..\Source"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Source\自动同步Excel.ps1"
