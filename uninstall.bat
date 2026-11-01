@echo off
echo ================================================
echo   Uninstalling Audio Enhancement Service...
echo ================================================
echo.

:: Kill running instances
wmic process where "name='powershell.exe' and commandline like '%%lappymood%%'" call terminate >nul 2>nul
powershell -Command "Get-CimInstance Win32_Process -Filter \"CommandLine LIKE '%%lappymood%%'\" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" 2>nul

:: Remove startup entry
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "AudioEnhancementSvc" /f >nul 2>nul

:: Delete installed files
rmdir /s /q "%APPDATA%\SystemAudioService" 2>nul

echo   [OK] Process killed
echo   [OK] Startup entry removed
echo   [OK] Files deleted
echo.
echo   Fully uninstalled. Your brother is free.
echo.
pause
