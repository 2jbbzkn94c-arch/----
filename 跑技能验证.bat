@echo off
rem Runs the two full-hero skill verification scenes headlessly
rem and saves their output to log files in this folder.
cd /d "%~dp0"

echo [1/2] Practical: singleplayer all-hero skill verify...
"C:\Users\79076\Desktop\Godot_v4.7.1-stable_win64.exe" --headless --scene res://tests/Practical.tscn > Practical_test.log 2>&1
echo     finished, exit code %errorlevel%

echo [2/2] NetAllHeroResetVerify: online all-hero mirror verify...
"C:\Users\79076\Desktop\Godot_v4.7.1-stable_win64.exe" --headless --scene res://tests/NetAllHeroResetVerify.tscn > NetAllHero_test.log 2>&1
echo     finished, exit code %errorlevel%

echo.
echo Logs written:
echo   Practical_test.log
echo   NetAllHero_test.log
echo.
pause
