@echo off
setlocal DisableDelayedExpansion
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-VSCodePortable.ps1"
set "result=%errorlevel%"
echo.
echo Press any key to close this window...
pause >nul
exit /b %result%
