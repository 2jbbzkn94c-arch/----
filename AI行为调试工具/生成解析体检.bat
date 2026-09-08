@echo off
cd /d "%~dp0.."
"C:\Users\79076\Desktop\Godot_v4.7.1-stable_win64.exe" --headless --path "%~dp0.." --script "res://tools/生成解析体检.gd" --log-file "%~dp0..\log\godot_check.log"
if exist "%~dp0..\log\godot_check.log" del "%~dp0..\log\godot_check.log"
echo done: 解析体检.txt
pause
