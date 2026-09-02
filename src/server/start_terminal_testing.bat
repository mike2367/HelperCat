@echo off
chcp 65001 >nul
setlocal

set "TEST_MODE=terminal"
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%\..\..") do set "PROJECT_ROOT=%%~fI"
for /f "usebackq delims=" %%P in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = '%PROJECT_ROOT%'; $drive = $p.Substring(0, 1).ToLowerInvariant(); '/mnt/' + $drive + $p.Substring(2).Replace('\', '/')"`) do set "WSL_PROJECT_ROOT=%%P"

echo [start_terminal_testing.bat] Project: %PROJECT_ROOT%
echo [start_terminal_testing.bat] Preparing isolated terminal QA.
echo.

set "WSL_PROJECT_DISTRO=Ubuntu-24.04"
set "WINDOWS_WSL=%SystemRoot%\System32\wsl.exe"
set "UBUNTU_2404=%LOCALAPPDATA%\Microsoft\WindowsApps\ubuntu2404.exe"
set "WSL_LAUNCHER="
set "WSL_LAUNCHER_KIND="
if exist "%WINDOWS_WSL%" (
  set "WSL_LAUNCHER=%WINDOWS_WSL%"
  set "WSL_LAUNCHER_KIND=wsl"
)
if not defined WSL_LAUNCHER if exist "%UBUNTU_2404%" (
  set "WSL_LAUNCHER=%UBUNTU_2404%"
  set "WSL_LAUNCHER_KIND=ubuntu2404"
)
if not defined WSL_LAUNCHER (
  echo No WSL launcher found. Install Ubuntu 24.04 or enable wsl.exe.
  exit /b 1
)

if /I "%TEST_MODE%"=="ui" (
  set "TEST_REDIS_PORT=12677"
  set "TEST_KEY_PREFIX=cat_qa_ui"
  set "TEST_REDIS_NAME=WebUI QA"
  if not defined CAT_TEST_WEBUI_PORT set "CAT_TEST_WEBUI_PORT=18201"
) else (
  set "TEST_REDIS_PORT=12678"
  set "TEST_KEY_PREFIX=cat_qa_terminal"
  set "TEST_REDIS_NAME=terminal QA"
)

set "TEST_LOCK_DIR=%LOCALAPPDATA%\HelperCat\locks\test-terminal-launcher.lock"
for /f "usebackq delims=" %%P in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_ROOT%\src\server\scripts\watch_wsl_parent.ps1" -PrintParentPid`) do set "LAUNCHER_PID=%%P"
if not defined LAUNCHER_PID (
  echo [%TEST_REDIS_NAME%] Could not determine the launcher process. No test resources were started.
  exit /b 1
)
for /f "usebackq delims=" %%P in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=Get-Process -Id %LAUNCHER_PID% -ErrorAction SilentlyContinue; if ($p) { $p.StartTime.ToUniversalTime().ToFileTimeUtc() }"`) do set "LAUNCHER_CREATION=%%P"
if not defined LAUNCHER_CREATION (
  echo [%TEST_REDIS_NAME%] Could not determine launcher ownership. No test resources were started.
  exit /b 1
)
if exist "%TEST_LOCK_DIR%" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$owner=Get-Content -LiteralPath '%TEST_LOCK_DIR%\owner.pid' -ErrorAction SilentlyContinue; $creation=Get-Content -LiteralPath '%TEST_LOCK_DIR%\owner.creation' -ErrorAction SilentlyContinue; $p=$null; if ($owner -match '^\d+$') { $p=Get-Process -Id ([int]$owner) -ErrorAction SilentlyContinue }; $active=$false; if ($p -and $creation -and [string]$p.StartTime.ToUniversalTime().ToFileTimeUtc() -eq $creation) { $active=$true }; if ($active) { exit 0 }; exit 1"
  if not errorlevel 1 (
    echo [%TEST_REDIS_NAME%] Another server launcher is already running.
    pause
    exit /b 1
  )
  echo [%TEST_REDIS_NAME%] Removing stale launcher lock.
  rmdir /s /q "%TEST_LOCK_DIR%" >nul 2>nul
)
mkdir "%TEST_LOCK_DIR%" >nul 2>nul
if errorlevel 1 (
  echo [%TEST_REDIS_NAME%] Could not create launcher lock.
  exit /b 1
)
> "%TEST_LOCK_DIR%\owner.pid" echo %LAUNCHER_PID%
> "%TEST_LOCK_DIR%\owner.creation" echo %LAUNCHER_CREATION%
> "%TEST_LOCK_DIR%\owner.script" echo %~f0
> "%TEST_LOCK_DIR%\owner.txt" echo %TEST_MODE%

set "CAT_TEST_RESET_MEMORY=0"
if /I "%~1"=="reset-memory" set "CAT_TEST_RESET_MEMORY=1"
if not "%~1"=="" if /I not "%~1"=="reset-memory" (
  echo Unknown option: %~1
  echo Supported option: reset-memory
  rmdir /s /q "%TEST_LOCK_DIR%" >nul 2>nul
  exit /b 2
)

set "TEST_REDIS_EXE=C:\Program Files\Redis-x64-5.0.14.1\redis-server.exe"
set "TEST_REDIS_CLI=C:\Program Files\Redis-x64-5.0.14.1\redis-cli.exe"
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "Get-Date -Format 'yyyyMMdd-HHmmss'"`) do set "TEST_RUN_STAMP=%%P"
set "TEST_RUN_ID=%TEST_RUN_STAMP%-%LAUNCHER_PID%"
set "TEST_LOG_DIR=%PROJECT_ROOT%\src\server\logs\test\%TEST_RUN_ID%"
set "TEST_RUNTIME_DIR=%TEST_LOG_DIR%\runtime"
set "TEST_REDIS_DIR=%TEST_RUNTIME_DIR%\redis"
set "TEST_REDIS_LOG_DIR=%TEST_LOG_DIR%\services\redis"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_ROOT%\src\server\scripts\launch_wsl_parent_watcher.ps1" -WatcherPath "%PROJECT_ROOT%\src\server\scripts\watch_wsl_parent.ps1" -Distro "%WSL_PROJECT_DISTRO%" -ParentPid %LAUNCHER_PID% -OwnerScript "%~f0" -OwnerCreation "%LAUNCHER_CREATION%" -RedisPort %TEST_REDIS_PORT% -RedisDataDir "%TEST_REDIS_DIR%" -RuntimeDir "%TEST_RUNTIME_DIR%" -LockDir "%TEST_LOCK_DIR%" >nul 2>nul
if not exist "%TEST_REDIS_EXE%" (
  echo Redis server not found: %TEST_REDIS_EXE%
  set "STATUS=1"
  goto runtime_exit
)
if not exist "%TEST_REDIS_DIR%" mkdir "%TEST_REDIS_DIR%"
if not exist "%TEST_REDIS_LOG_DIR%" mkdir "%TEST_REDIS_LOG_DIR%"

"%TEST_REDIS_CLI%" -h 127.0.0.1 -p %TEST_REDIS_PORT% PING >nul 2>nul
if errorlevel 1 (
  echo [%TEST_REDIS_NAME%] Starting dedicated Redis on 127.0.0.1:%TEST_REDIS_PORT%.
  "%TEST_REDIS_CLI%" -h 127.0.0.1 -p %TEST_REDIS_PORT% shutdown nosave >nul 2>nul
  start "" /b "%TEST_REDIS_EXE%" --port %TEST_REDIS_PORT% --dir "%TEST_REDIS_DIR%" --bind 0.0.0.0 --protected-mode no --appendonly yes --logfile "%TEST_REDIS_LOG_DIR%\redis.log"
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$deadline = (Get-Date).AddSeconds(10); do { & '%TEST_REDIS_CLI%' -h 127.0.0.1 -p %TEST_REDIS_PORT% PING *> $null; if ($LASTEXITCODE -eq 0) { exit 0 }; Start-Sleep -Milliseconds 200 } while ((Get-Date) -lt $deadline); exit 1"
  if errorlevel 1 (
    echo [%TEST_REDIS_NAME%] Redis failed to start on port %TEST_REDIS_PORT%.
    set "STATUS=1"
    goto runtime_exit
  )
)

if "%CAT_TEST_RESET_MEMORY%"=="1" (
  echo [%TEST_REDIS_NAME%] Clearing Redis DB1 before startup.
  "%TEST_REDIS_CLI%" -p %TEST_REDIS_PORT% -n 1 FLUSHDB >nul
  if errorlevel 1 (
    set "STATUS=1"
    goto runtime_exit
  )
)

set "WINDOWS_TEST_WEBUI_STARTED=0"

set "WSLENV=CLOUD_BACKBONE_BASE_URL/u:CLOUD_BACKBONE_API_KEY/u:CLOUD_BACKBONE_MODEL/u:CLOUD_BACKBONE_PROVIDER/u:CLOUD_BACKBONE_EXTRA_BODY_JSON/u:CAT_TEST_WEBUI_PORT/u:CAT_TEST_EXTERNAL_VLLM_URL/u:CAT_TEST_RUN_VALIDATION/u:%WSLENV%"

echo [%TEST_REDIS_NAME%] Project: %PROJECT_ROOT%
echo [%TEST_REDIS_NAME%] Redis: 127.0.0.1:%TEST_REDIS_PORT% DB1, prefix %TEST_KEY_PREFIX%
if /I "%TEST_MODE%"=="terminal" echo [%TEST_REDIS_NAME%] DB1 will be cleared when this launcher exits.
if /I "%TEST_MODE%"=="ui" echo [%TEST_REDIS_NAME%] Use start_UI_testing.bat reset-memory to clear DB1.
echo.

if /I "%WSL_LAUNCHER_KIND%"=="wsl" "%WSL_LAUNCHER%" --distribution %WSL_PROJECT_DISTRO% --user root -- bash -lc "if [[ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ]]; then printf '%%s' ':WSLInterop:M::MZ::/init:PF' ^> /proc/sys/fs/binfmt_misc/register; fi; ip link set dev eth0 mtu 1350" >nul 2>nul

if /I "%WSL_LAUNCHER_KIND%"=="wsl" (
  "%WSL_LAUNCHER%" --distribution %WSL_PROJECT_DISTRO% --cd "%WSL_PROJECT_ROOT%" -- bash -lc "test -f ./src/server/scripts/start_testing.sh && PAUSE_ON_EXIT=0 CAT_TEST_MODE='%TEST_MODE%' CAT_TEST_RUN_ID='%TEST_RUN_ID%' TEST_KEY_PREFIX='%TEST_KEY_PREFIX%' CAT_TEST_EXTERNAL_REDIS_PORT='%TEST_REDIS_PORT%' CAT_TEST_MEMORY_PORT='18204' CAT_TEST_WEBUI_PORT='18201' CAT_TEST_WEBUI_MANAGED_EXTERNALLY='%WINDOWS_TEST_WEBUI_STARTED%' CAT_TEST_RESET_MEMORY='%CAT_TEST_RESET_MEMORY%' bash ./src/server/scripts/start_testing.sh"
) else (
  "%WSL_LAUNCHER%" run bash -lc "cd '%WSL_PROJECT_ROOT%' && test -f ./src/server/scripts/start_testing.sh && PAUSE_ON_EXIT=0 CAT_TEST_MODE='%TEST_MODE%' CAT_TEST_RUN_ID='%TEST_RUN_ID%' TEST_KEY_PREFIX='%TEST_KEY_PREFIX%' CAT_TEST_EXTERNAL_REDIS_PORT='%TEST_REDIS_PORT%' CAT_TEST_MEMORY_PORT='18204' CAT_TEST_WEBUI_PORT='18201' CAT_TEST_WEBUI_MANAGED_EXTERNALLY='%WINDOWS_TEST_WEBUI_STARTED%' CAT_TEST_RESET_MEMORY='%CAT_TEST_RESET_MEMORY%' bash ./src/server/scripts/start_testing.sh"
)

set "STATUS=%ERRORLEVEL%"
if /I "%TEST_MODE%"=="terminal" (
  echo [terminal QA] Clearing Redis DB1 after test runtime exit.
  "%TEST_REDIS_CLI%" -p %TEST_REDIS_PORT% -n 1 FLUSHDB >nul
  if errorlevel 1 if "%STATUS%"=="0" set "STATUS=1"
)
echo.
echo [%TEST_REDIS_NAME%] Test runtime exited with code %STATUS%.
wsl.exe --terminate "%WSL_PROJECT_DISTRO%" >nul 2>nul
"%TEST_REDIS_CLI%" -p %TEST_REDIS_PORT% shutdown nosave >nul 2>nul
rmdir /s /q "%TEST_RUNTIME_DIR%" >nul 2>nul
rmdir /s /q "%TEST_LOCK_DIR%" >nul 2>nul
if "%CAT_NO_PAUSE%"=="1" exit /b %STATUS%
pause
exit /b %STATUS%

:runtime_exit
if not defined STATUS set "STATUS=1"
wsl.exe --terminate "%WSL_PROJECT_DISTRO%" >nul 2>nul
"%TEST_REDIS_CLI%" -p %TEST_REDIS_PORT% shutdown nosave >nul 2>nul
rmdir /s /q "%TEST_RUNTIME_DIR%" >nul 2>nul
rmdir /s /q "%TEST_LOCK_DIR%" >nul 2>nul
if "%CAT_NO_PAUSE%"=="1" exit /b %STATUS%
pause
exit /b %STATUS%
