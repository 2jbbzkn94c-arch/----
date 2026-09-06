@echo off
rem Runs the remaining single-player and online verification scenes.
rem Every scene output is appended to extra_verify.log with a header.
cd /d "%~dp0"
set GODOT=C:\Users\79076\Desktop\Godot_v4.7.1-stable_win64.exe
set LOG=extra_verify.log

if exist "%LOG%" del "%LOG%"

for %%T in (
    AISmokeTest
    SkillVerify
    ArenaTest
    SubVerify
    BombVerify
    FreeDeployRegression
    NetFullMatchVerify
    NetSubVerify
    NetSubmitVerify
    NetTurnGateVerify
    NetBeginSideCorrVerify
    NetDeployTurnVerify
    NetSyncVerify
    NetCmdVerify
) do (
    echo Running %%T ...
    echo ============================================================ >> "%LOG%"
    echo ============  %%T  ============ >> "%LOG%"
    echo ============================================================ >> "%LOG%"
    "%GODOT%" --headless --scene res://tests/%%T.tscn >> "%LOG%" 2>&1
    echo     done, exit code %errorlevel%
)

echo.
echo All scenes finished. Results saved to: %LOG%
echo.
pause
