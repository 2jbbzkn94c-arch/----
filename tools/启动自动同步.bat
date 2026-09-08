@echo off
chcp 65001>nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0自动同步Excel.ps1"
