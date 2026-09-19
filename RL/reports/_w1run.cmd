@echo off
set "APPDATA=%TEMP%\dsh_w1"
set "ZB_NO_MIRROR=1"
"%GODOT%" --headless --path "%PROJ%" --log-file "%LOGF%" --scene "%SCENE%" -- %ARGS% > "%OUT%" 2>&1
echo EXIT=%ERRORLEVEL%
