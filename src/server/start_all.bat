@echo off
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%\..\..") do set "PROJECT_ROOT=%%~fI"

for /f "usebackq delims=" %%P in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = '%PROJECT_ROOT%'; $drive = $p.Substring(0, 1).ToLowerInvariant(); '/mnt/' + $drive + $p.Substring(2).Replace('\', '/')"`) do set "WSL_PROJECT_ROOT=%%P"

set "WSL_LAUNCHER="
set "WSL_LAUNCHER_KIND="
set "WSL_PROJECT_DISTRO=Ubuntu-24.04"
set "UBUNTU_2404=%LOCALAPPDATA%\Microsoft\WindowsApps\ubuntu2404.exe"
set "WINDOWS_WSL=%SystemRoot%\System32\wsl.exe"
set "HELPERCAT_DATA_DIR=%LOCALAPPDATA%\HelperCat"
set "CLOUDFLARED_EXE=%LOCALAPPDATA%\HelperCat\bin\cloudflared.exe"
set "TUNNEL_PID_FILE=%HELPERCAT_DATA_DIR%\cloudflared-start_all.pid"
echo [start_all.bat] Cloudflared executable: !CLOUDFLARED_EXE!
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "Get-Date -Format 'yyyyMMdd-HHmmss'"`) do set "OFFICIAL_RUN_ID=%%P"
set "OFFICIAL_LOG_DIR=%PROJECT_ROOT%\src\server\logs\official\%OFFICIAL_RUN_ID%"
set "TUNNEL_LOG_PREFIX=%OFFICIAL_LOG_DIR%\services\cloudflared\cloudflared"
set "WSLENV=CONFIG_FILE/u:CLOUD_BACKBONE_BASE_URL/u:CLOUD_BACKBONE_API_KEY/u:CLOUD_BACKBONE_MODEL/u:CLOUD_BACKBONE_PROVIDER/u:CLOUD_BACKBONE_EXTRA_BODY_JSON/u:HELPERCAT_DATA_DIR/p/u:HELPERCAT_RUN_ID/u:%WSLENV%"
set "HELPERCAT_RUN_ID=%OFFICIAL_RUN_ID%"
if exist "%WINDOWS_WSL%" (
  set "WSL_LAUNCHER=%WINDOWS_WSL%"
  set "WSL_LAUNCHER_KIND=wsl"
)
if not defined WSL_LAUNCHER (
  where wsl.exe >nul 2>nul
  if "%ERRORLEVEL%"=="0" (
    set "WSL_LAUNCHER=wsl.exe"
    set "WSL_LAUNCHER_KIND=wsl"
  )
)
if not defined WSL_LAUNCHER (
  if exist "%UBUNTU_2404%" (
    set "WSL_LAUNCHER=%UBUNTU_2404%"
    set "WSL_LAUNCHER_KIND=ubuntu2404"
  )
)
if not defined WSL_LAUNCHER (
  where ubuntu2404.exe >nul 2>nul
  if "%ERRORLEVEL%"=="0" (
    set "WSL_LAUNCHER=ubuntu2404.exe"
    set "WSL_LAUNCHER_KIND=ubuntu2404"
  )
)

if not defined WSL_LAUNCHER (
  echo No WSL launcher found. Install Ubuntu 24.04 or enable wsl.exe.
  pause
  exit /b 1
)

set "MODE=%~1"
if not defined MODE set "MODE=local"
if /I "%MODE%"=="full" set "MODE=full-debug"
set "WINDOWS_DOCKER_STARTED=0"
set "REDIS_EXE=C:\Program Files\Redis-x64-5.0.14.1\redis-server.exe"
set "REDIS_CLI=C:\Program Files\Redis-x64-5.0.14.1\redis-cli.exe"
set "REDIS_DIR=%HELPERCAT_DATA_DIR%\redis"
set "OFFICIAL_REDIS_LOG_DIR=%OFFICIAL_LOG_DIR%\services\redis"

if /I not "%MODE%"=="stop" (
  if not exist "%OFFICIAL_REDIS_LOG_DIR%" mkdir "%OFFICIAL_REDIS_LOG_DIR%"
  if exist "%REDIS_EXE%" (
    if not exist "%REDIS_DIR%" mkdir "%REDIS_DIR%"
    "%REDIS_CLI%" -h 127.0.0.1 -p 6379 PING >nul 2>nul
    if errorlevel 1 (
      echo [start_all.bat] Starting official Redis on 127.0.0.1:6379.
      start "" /b "%REDIS_EXE%" --port 6379 --dir "%REDIS_DIR%" --bind 0.0.0.0 --protected-mode no --appendonly yes --logfile "%OFFICIAL_REDIS_LOG_DIR%\redis.log"
      powershell -NoProfile -ExecutionPolicy Bypass -Command "$deadline=(Get-Date).AddSeconds(10); do { & '%REDIS_CLI%' -h 127.0.0.1 -p 6379 PING *> $null; if ($LASTEXITCODE -eq 0) { exit 0 }; Start-Sleep -Milliseconds 200 } while ((Get-Date) -lt $deadline); exit 1"
      if errorlevel 1 (
        echo [start_all.bat] Official Redis did not become ready.
        exit /b 1
      )
    )
  ) else (
    echo [start_all.bat] Redis server not found: %REDIS_EXE%
    exit /b 1
  )
)

if /I "%MODE%"=="stop" goto stop_tunnel
set "LAUNCHER_LOCK_DIR=%HELPERCAT_DATA_DIR%\locks\server-launcher.lock"
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$self=Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID); $commandShell=Get-CimInstance Win32_Process -Filter ('ProcessId=' + $self.ParentProcessId); $commandShell.ParentProcessId"`) do set "LAUNCHER_PID=%%P"
if exist "%LAUNCHER_LOCK_DIR%" (
  powershell -NoProfile -Command "$owner=Get-Content -LiteralPath '%LAUNCHER_LOCK_DIR%\owner.pid' -ErrorAction SilentlyContinue; if ($owner -match '^\d+$' -and (Get-Process -Id ([int]$owner) -ErrorAction SilentlyContinue)) { exit 0 }; exit 1"
  if not errorlevel 1 (
    echo [start_all.bat] Another server launcher is already running.
    pause
    exit /b 1
  )
  echo [start_all.bat] Removing stale launcher lock.
  rmdir /s /q "%LAUNCHER_LOCK_DIR%" >nul 2>nul
)
mkdir "%LAUNCHER_LOCK_DIR%" >nul 2>nul
if errorlevel 1 (
  echo [start_all.bat] Could not create launcher lock.
  exit /b 1
)
> "%LAUNCHER_LOCK_DIR%\owner.pid" echo %LAUNCHER_PID%
> "%LAUNCHER_LOCK_DIR%\owner.txt" echo official-%MODE%
goto launcher_lock_ready

:stop_tunnel
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f='%TUNNEL_PID_FILE%'; $tunnelPid=Get-Content -LiteralPath $f -ErrorAction SilentlyContinue; if ($tunnelPid -match '^\d+$') { Stop-Process -Id ([int]$tunnelPid) -Force -ErrorAction SilentlyContinue }; Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue"
:launcher_lock_ready

echo [start_all.bat] Project: %PROJECT_ROOT%
echo [start_all.bat] WSL path: %WSL_PROJECT_ROOT%
echo [start_all.bat] Launcher: %WSL_LAUNCHER%
echo [start_all.bat] Mode: %MODE%
for /f "usebackq delims=" %%I in (`powershell -NoProfile -Command "$ip = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } | Select-Object -First 1 -ExpandProperty IPv4Address | Select-Object -First 1 -ExpandProperty IPAddress; if ($ip) { $ip + ':18201' }"`) do set "LAN_URL=%%I"
if defined LAN_URL echo [start_all.bat] WebUI URL for LAN testers: http://%LAN_URL%
echo [start_all.bat] WebUI is also available at: http://localhost:18201
echo [start_all.bat] Keep this PowerShell window open. Press Ctrl-C to stop the server stack.
echo.

if /I not "%MODE%"=="stop" powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%scripts\launch_wsl_parent_watcher.ps1" -WatcherPath "%SCRIPT_DIR%scripts\watch_wsl_parent.ps1" -Distro "%WSL_PROJECT_DISTRO%" -ParentPid %LAUNCHER_PID% -ComposeFile "%SCRIPT_DIR%docker-compose.yml" -StopDockerServices -LockDir "%LAUNCHER_LOCK_DIR%" >nul 2>nul

if defined CONFIG_FILE (
  echo [start_all.bat] Custom CONFIG_FILE selected; WSL will start its configured Docker services.
) else (
  where docker >nul 2>nul
  if "%ERRORLEVEL%"=="0" (
    if /I "%MODE%"=="stop" (
      echo [start_all.bat] Stopping Open WebUI from Windows Docker Desktop.
      docker compose -f "%SCRIPT_DIR%docker-compose.yml" stop open-webui
    ) else (
      echo [start_all.bat] Starting Open WebUI from Windows Docker Desktop.
      docker compose -f "%SCRIPT_DIR%docker-compose.yml" up -d open-webui
      if not errorlevel 1 set "WINDOWS_DOCKER_STARTED=1"
    )
  ) else (
    echo [start_all.bat] Windows docker command not found; WSL script will try its own Docker path.
  )
)
echo.

if /I not "%MODE%"=="stop" if exist "%CLOUDFLARED_EXE%" (
  echo [start_all.bat] Starting Cloudflare Quick Tunnel for WebUI.
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$f='%TUNNEL_PID_FILE%'; $old=Get-Content -LiteralPath $f -ErrorAction SilentlyContinue; if ($old -match '^\d+$') { Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue }; New-Item -ItemType Directory -Path (Split-Path -Parent '%TUNNEL_LOG_PREFIX%') -Force | Out-Null; $p=Start-Process -FilePath '%CLOUDFLARED_EXE%' -ArgumentList @('tunnel','--no-autoupdate','--url','http://127.0.0.1:18201') -RedirectStandardOutput '%TUNNEL_LOG_PREFIX%.out.log' -RedirectStandardError '%TUNNEL_LOG_PREFIX%.err.log' -PassThru; Set-Content -LiteralPath $f -Value $p.Id"
  for /f "usebackq delims=" %%U in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$files=@('%TUNNEL_LOG_PREFIX%.out.log','%TUNNEL_LOG_PREFIX%.err.log'); $deadline=(Get-Date).AddSeconds(25); do { $text=($files | ForEach-Object { Get-Content -LiteralPath $_ -Raw -ErrorAction SilentlyContinue }) -join [Environment]::NewLine; $m=[regex]::Match($text,'https://[a-z0-9-]+\.trycloudflare\.com'); if ($m.Success) { $m.Value; exit 0 }; Start-Sleep -Milliseconds 250 } while ((Get-Date) -lt $deadline); exit 1"`) do set "PUBLIC_URL=%%U"
  if defined PUBLIC_URL echo [start_all.bat] Public WebUI URL: !PUBLIC_URL!
  if not defined PUBLIC_URL echo [start_all.bat] Tunnel URL not available yet; see %TUNNEL_LOG_PREFIX%.*.log
) else if /I not "%MODE%"=="stop" (
  echo [start_all.bat] cloudflared not found at "%CLOUDFLARED_EXE%"; public tunnel skipped.
)
echo.

if /I not "%MODE%"=="stop" (
  if /I "%WSL_LAUNCHER_KIND%"=="wsl" (
    "%WSL_LAUNCHER%" --distribution %WSL_PROJECT_DISTRO% --user root -- bash -lc "ip link set dev eth0 mtu 1350" >nul 2>nul
  )
)

if /I "%WSL_LAUNCHER_KIND%"=="wsl" (
    "%WSL_LAUNCHER%" --distribution %WSL_PROJECT_DISTRO% --cd "%WSL_PROJECT_ROOT%" -- bash -lc "test -f ./src/server/scripts/start_all.sh && WINDOWS_DOCKER_STARTED='%WINDOWS_DOCKER_STARTED%' bash ./src/server/scripts/start_all.sh '%MODE%'"
) else (
  "%WSL_LAUNCHER%" run bash -lc "cd '%WSL_PROJECT_ROOT%' && test -f ./src/server/scripts/start_all.sh && WINDOWS_DOCKER_STARTED='%WINDOWS_DOCKER_STARTED%' bash ./src/server/scripts/start_all.sh '%MODE%'"
)

set "STATUS=%ERRORLEVEL%"
echo.
echo [start_all.bat] scripts/start_all.sh exited with code %STATUS%.
if /I not "%MODE%"=="stop" (
  echo [start_all.bat] Releasing project WSL distro: %WSL_PROJECT_DISTRO%.
  wsl.exe --terminate "%WSL_PROJECT_DISTRO%" >nul 2>nul
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$running = @(& wsl.exe -l -q --running | ForEach-Object { ($_ -replace [char]0, '').Trim() } | Where-Object { $_ }); if (-not ($running | Where-Object { $_ -ne '%WSL_PROJECT_DISTRO%' })) { & wsl.exe --shutdown | Out-Null }"
  rmdir /s /q "%LAUNCHER_LOCK_DIR%" >nul 2>nul
)
if /I "%MODE%"=="stop" exit /b %STATUS%
if "%CAT_NO_PAUSE%"=="1" exit /b %STATUS%
pause
exit /b %STATUS%
