@echo off
setlocal
echo.
echo Uninstalling Toggle Turn-Based In Combat...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall
echo.
echo Done. You can close this window.
echo.
pause
endlocal
