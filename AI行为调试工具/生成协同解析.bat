@echo off
cd /d "%~dp0.."
"C:\Users\79076\Desktop\Godot_v4.7.1-stable_win64.exe" --headless --path "%~dp0.." --script "res://tools/生成协同解析.gd" --log-file "%~dp0..\.godot_syn.log"
if exist "%~dp0..\.godot_syn.log" del "%~dp0..\.godot_syn.log"
echo done: 角色协同解析.txt
pause
