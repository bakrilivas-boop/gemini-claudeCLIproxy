@echo off
setlocal
if /i "%~1"=="--service" goto :service
if /i "%~1"=="--login" goto :login
set "HELPER=%~dp0CLIProxyAPI-Helper.ps1"

if not exist "%HELPER%" (
  echo Launcher panel script not found: "%HELPER%"
  pause
  exit /b 1
)

start "" powershell.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -File "%HELPER%"
endlocal
exit /b 0

:service
set "CLI_DIR=%USERPROFILE%\Downloads\CLIProxyAPI_7.3.17_windows_amd64"
set "CLI_EXE=%CLI_DIR%\cli-proxy-api.exe"
set "CLI_CONFIG=%CLI_DIR%\config.yaml"
if not exist "%CLI_EXE%" exit /b 2
if not exist "%CLI_CONFIG%" exit /b 3
start "CLIProxyAPI Service" /D "%CLI_DIR%" "%CLI_EXE%" -config "%CLI_CONFIG%"
exit /b %errorlevel%

:login
set "CLI_DIR=%USERPROFILE%\Downloads\CLIProxyAPI_7.3.17_windows_amd64"
set "CLI_EXE=%CLI_DIR%\cli-proxy-api.exe"
set "CLI_CONFIG=%CLI_DIR%\config.yaml"
if not exist "%CLI_EXE%" exit /b 2
if not exist "%CLI_CONFIG%" exit /b 3
pushd "%CLI_DIR%" || exit /b 4
"%CLI_EXE%" -antigravity-login -config "%CLI_CONFIG%"
set "LOGIN_RESULT=%errorlevel%"
if not "%LOGIN_RESULT%"=="0" (
  echo.
  echo Authorization command failed with exit code %LOGIN_RESULT%.
  echo Check any Windows security prompt or message above.
  timeout /t 10 /nobreak >nul
)
popd
exit /b %LOGIN_RESULT%
