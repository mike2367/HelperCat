@echo off
chcp 65001 >nul
setlocal

set "TEST_MODE=ui"
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%\..\..") do set "PROJECT_ROOT=%%~fI"
for /f "usebackq delims=" %%P in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = '%PROJECT_ROOT%'; $drive = $p.Substring(0, 1).ToLowerInvariant(); '/mnt/' + $drive + $p.Substring(2).Replace('\', '/')"`) do set "WSL_PROJECT_ROOT=%%P"

echo [start_UI_testing.bat] Project: %PROJECT_ROOT%
echo [start_UI_testing.bat] Preparing isolated WebUI QA on http://127.0.0.1:18201
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
  set "TEST_REDIS_NAME=HelperCat WebUI QA"
  if not defined CAT_TEST_WEBUI_PORT set "CAT_TEST_WEBUI_PORT=18201"
) else (
  set "TEST_REDIS_PORT=12678"
  set "TEST_KEY_PREFIX=cat_qa_terminal"
  set "TEST_REDIS_NAME=terminal QA"
)

if /I "%TEST_MODE%"=="ui" (
  where docker >nul 2>nul
  if errorlevel 1 (
    echo [WebUI QA] Windows Docker command not found. No test resources were started.
    exit /b 1
  )
  docker info >nul 2>nul
  if errorlevel 1 (
    echo [WebUI QA] Docker engine is unavailable to this process. No test resources were started.
    exit /b 1
  )
)

set "TEST_LOCK_DIR=%LOCALAPPDATA%\HelperCat\locks\test-ui-launcher.lock"
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
  powershell -NoProfile -Command "$owner=Get-Content -LiteralPath '%TEST_LOCK_DIR%\owner.pid' -ErrorAction SilentlyContinue; $creation=Get-Content -LiteralPath '%TEST_LOCK_DIR%\owner.creation' -ErrorAction SilentlyContinue; $p=$null; if ($owner -match '^\d+$') { $p=Get-Process -Id ([int]$owner) -ErrorAction SilentlyContinue }; $active=$false; if ($p -and $creation -and [string]$p.StartTime.ToUniversalTime().ToFileTimeUtc() -eq $creation) { $active=$true }; if ($active) { exit 0 }; exit 1"
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

set "CAT_TEST_RESET_MEMORY=1"
if not "%~1"=="" if /I not "%~1"=="reset-memory" (
  echo Unknown option: %~1
  echo Supported option: reset-memory
  rmdir /s /q "%TEST_LOCK_DIR%" >nul 2>nul
  exit /b 2
)

for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "Get-Date -Format 'yyyyMMdd-HHmmss'"`) do set "TEST_RUN_STAMP=%%P"
set "TEST_RUN_ID=%TEST_RUN_STAMP%-%LAUNCHER_PID%"
set "TEST_LOG_DIR=%PROJECT_ROOT%\src\server\logs\test\%TEST_RUN_ID%"
set "TEST_RUNTIME_DIR=%TEST_LOG_DIR%\runtime"
set "TEST_REDIS_LOG_DIR=%TEST_LOG_DIR%\services\redis"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_ROOT%\src\server\scripts\launch_wsl_parent_watcher.ps1" -WatcherPath "%PROJECT_ROOT%\src\server\scripts\watch_wsl_parent.ps1" -Distro "%WSL_PROJECT_DISTRO%" -ParentPid %LAUNCHER_PID% -OwnerScript "%~f0" -OwnerCreation "%LAUNCHER_CREATION%" -DockerContainer helpercat_test_ui -DockerVolume helpercat_test_ui_data -RedisPort %TEST_REDIS_PORT% -RedisDataDir "%TEST_RUNTIME_DIR%\redis" -RuntimeDir "%TEST_RUNTIME_DIR%" -LockDir "%TEST_LOCK_DIR%" >nul 2>nul

set "TEST_REDIS_EXE=C:\Program Files\Redis-x64-5.0.14.1\redis-server.exe"
set "TEST_REDIS_CLI=C:\Program Files\Redis-x64-5.0.14.1\redis-cli.exe"
set "TEST_REDIS_DIR=%TEST_RUNTIME_DIR%\redis"
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

if /I "%TEST_MODE%"=="ui" (
  echo [WebUI QA] Starting the memory proxy before opening the browser.
  if /I "%WSL_LAUNCHER_KIND%"=="wsl" (
    start "" /b "%WSL_LAUNCHER%" --distribution %WSL_PROJECT_DISTRO% --cd "%WSL_PROJECT_ROOT%" -- bash -lc "test -f ./src/server/scripts/start_testing.sh && PAUSE_ON_EXIT=0 CAT_TEST_MODE='%TEST_MODE%' CAT_TEST_RUN_ID='%TEST_RUN_ID%' TEST_KEY_PREFIX='%TEST_KEY_PREFIX%' CAT_TEST_EXTERNAL_REDIS_PORT='%TEST_REDIS_PORT%' CAT_TEST_MEMORY_PORT='18204' CAT_TEST_WEBUI_PORT='18201' CAT_TEST_WEBUI_MANAGED_EXTERNALLY='1' CAT_TEST_RESET_MEMORY='%CAT_TEST_RESET_MEMORY%' bash ./src/server/scripts/start_testing.sh"
  ) else (
    start "" /b "%WSL_LAUNCHER%" run bash -lc "cd '%WSL_PROJECT_ROOT%' && test -f ./src/server/scripts/start_testing.sh && PAUSE_ON_EXIT=0 CAT_TEST_MODE='%TEST_MODE%' CAT_TEST_RUN_ID='%TEST_RUN_ID%' TEST_KEY_PREFIX='%TEST_KEY_PREFIX%' CAT_TEST_EXTERNAL_REDIS_PORT='%TEST_REDIS_PORT%' CAT_TEST_MEMORY_PORT='18204' CAT_TEST_WEBUI_PORT='18201' CAT_TEST_WEBUI_MANAGED_EXTERNALLY='1' CAT_TEST_RESET_MEMORY='%CAT_TEST_RESET_MEMORY%' bash ./src/server/scripts/start_testing.sh"
  )
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$deadline=(Get-Date).AddMinutes(8); do { try { $response=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18204/v1/models' -Headers @{Authorization='Bearer your_own_local_api_key'} -TimeoutSec 5; if ($response.StatusCode -eq 200) { exit 0 } } catch {}; Start-Sleep -Seconds 2 } while ((Get-Date) -lt $deadline); exit 1"
  if errorlevel 1 (
    echo [WebUI QA] Memory proxy did not publish HelperCat before the startup deadline.
    set "STATUS=1"
    goto runtime_exit
  )
)

set "WINDOWS_TEST_WEBUI_STARTED=1"
if /I "%TEST_MODE%"=="ui" (
  docker rm -f helpercat_test_ui >nul 2>nul
  docker volume rm -f helpercat_test_ui_data >nul 2>nul
  docker volume create helpercat_test_ui_data >nul
  > "%TEST_RUNTIME_DIR%\webui.env" echo DEFAULT_MODEL_METADATA={"capabilities":{"file_context":false,"vision":false,"file_upload":false,"web_search":false,"image_generation":false,"code_interpreter":false,"terminal":false,"citations":false,"status_updates":true,"builtin_tools":false,"memory":false}}
  set "OPENAI_API_CONFIGS={"0":{"headers":{"X-Cat-WebUI-Chat-Id":"{{CHAT_ID}}","X-Cat-WebUI-Message-Id":"{{MESSAGE_ID}}"}}}"
  docker run -d --restart=no --env-file "%TEST_RUNTIME_DIR%\webui.env" --name helpercat_test_ui --add-host host.docker.internal:host-gateway -e WEBUI_NAME="HelperCat" -e WEBUI_AUTH=True -e ENABLE_SIGNUP=True -e ENABLE_PERSISTENT_CONFIG=False -e DEFAULT_USER_ROLE=user -e ENABLE_FORWARD_USER_INFO_HEADERS=True -e ENABLE_OPENAI_API=True -e OPENAI_API_BASE_URLS=http://host.docker.internal:18204/v1 -e OPENAI_API_KEYS=your_own_local_api_key -e OPENAI_API_CONFIGS -e DEFAULT_MODELS=HelperCat -e ENABLE_CODE_EXECUTION=False -e ENABLE_CODE_INTERPRETER=False -e ENABLE_IMAGE_GENERATION=False -e ENABLE_IMAGE_EDIT=False -e USER_PERMISSIONS_CHAT_FILE_UPLOAD=False -e RAG_EMBEDDING_ENGINE=openai -e RAG_OPENAI_API_BASE_URL=http://host.docker.internal:18204/v1 -e RAG_OPENAI_API_KEY=your_own_local_api_key -e RAG_EMBEDDING_MODEL=HelperCat -e ENABLE_RAG_HYBRID_SEARCH=False -e ENABLE_WEB_SEARCH=False -e ENABLE_SEARCH_QUERY_GENERATION=False -e ENABLE_FOLLOW_UP_GENERATION=False -e ENABLE_AUTOCOMPLETE_GENERATION=False -e ENABLE_TAGS_GENERATION=False -e ENABLE_TITLE_GENERATION=False -v helpercat_test_ui_data:/app/backend/data -v "%PROJECT_ROOT%\src\server\resources\cat-avatar.png:/app/backend/open_webui/static/logo.png:ro" -v "%PROJECT_ROOT%\src\server\resources\cat-avatar.png:/app/backend/open_webui/static/favicon.png:ro" -p 127.0.0.1:18201:8080 ghcr.io/open-webui/open-webui:v0.10.2 >nul
  if errorlevel 1 (
    set "STATUS=1"
    goto runtime_exit
  )
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$deadline=(Get-Date).AddMinutes(7); do { try { $response=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18201' -TimeoutSec 3; if ($response.StatusCode -eq 200) { exit 0 } } catch {}; Start-Sleep -Seconds 2 } while ((Get-Date) -lt $deadline); exit 1"
  if errorlevel 1 (
    docker rm -f helpercat_test_ui >nul 2>nul
    set "STATUS=1"
    goto runtime_exit
  )
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$credentials = @{email='qa-user@example.invalid'; password='your_own_qa_password'}; $signin = $credentials | ConvertTo-Json; try { Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18201/api/v1/auths/signin' -Method Post -ContentType 'application/json' -Body $signin -TimeoutSec 20 | Out-Null } catch { $signup = @{name='QA User'; email=$credentials.email; password=$credentials.password} | ConvertTo-Json; try { Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18201/api/v1/auths/signup' -Method Post -ContentType 'application/json' -Body $signup -TimeoutSec 20 | Out-Null; Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18201/api/v1/auths/signin' -Method Post -ContentType 'application/json' -Body $signin -TimeoutSec 20 | Out-Null } catch { exit 1 } }"
  if errorlevel 1 (
    docker rm -f helpercat_test_ui >nul 2>nul
    set "STATUS=1"
    goto runtime_exit
  )
  set "WINDOWS_TEST_WEBUI_STARTED=1"
)

set "WSLENV=CLOUD_BACKBONE_BASE_URL/u:CLOUD_BACKBONE_API_KEY/u:CLOUD_BACKBONE_MODEL/u:CLOUD_BACKBONE_PROVIDER/u:CLOUD_BACKBONE_EXTRA_BODY_JSON/u:CAT_TEST_WEBUI_PORT/u:CAT_TEST_EXTERNAL_VLLM_URL/u:CAT_TEST_RUN_VALIDATION/u:%WSLENV%"

echo [%TEST_REDIS_NAME%] Project: %PROJECT_ROOT%
echo [%TEST_REDIS_NAME%] Redis: 127.0.0.1:%TEST_REDIS_PORT% DB1, prefix %TEST_KEY_PREFIX%
echo [%TEST_REDIS_NAME%] DB1 and disposable WebUI state will be cleared when this launcher exits.
echo.

if /I "%TEST_MODE%"=="terminal" if /I "%WSL_LAUNCHER_KIND%"=="wsl" (
  "%WSL_LAUNCHER%" --distribution %WSL_PROJECT_DISTRO% --cd "%WSL_PROJECT_ROOT%" -- bash -lc "test -f ./src/server/scripts/start_testing.sh && PAUSE_ON_EXIT=0 CAT_TEST_MODE='%TEST_MODE%' TEST_KEY_PREFIX='%TEST_KEY_PREFIX%' CAT_TEST_EXTERNAL_REDIS_PORT='%TEST_REDIS_PORT%' CAT_TEST_MEMORY_PORT='18204' CAT_TEST_WEBUI_PORT='18201' CAT_TEST_WEBUI_MANAGED_EXTERNALLY='0' CAT_TEST_RESET_MEMORY='%CAT_TEST_RESET_MEMORY%' bash ./src/server/scripts/start_testing.sh"
) else if /I "%TEST_MODE%"=="terminal" (
  "%WSL_LAUNCHER%" run bash -lc "cd '%WSL_PROJECT_ROOT%' && test -f ./src/server/scripts/start_testing.sh && PAUSE_ON_EXIT=0 CAT_TEST_MODE='%TEST_MODE%' TEST_KEY_PREFIX='%TEST_KEY_PREFIX%' CAT_TEST_EXTERNAL_REDIS_PORT='%TEST_REDIS_PORT%' CAT_TEST_MEMORY_PORT='18204' CAT_TEST_WEBUI_PORT='18201' CAT_TEST_WEBUI_MANAGED_EXTERNALLY='0' CAT_TEST_RESET_MEMORY='%CAT_TEST_RESET_MEMORY%' bash ./src/server/scripts/start_testing.sh"
)

if /I "%TEST_MODE%"=="ui" goto ui_runtime_wait

set "STATUS=%ERRORLEVEL%"
if /I "%TEST_MODE%"=="ui" docker rm -f helpercat_test_ui >nul 2>nul
if /I "%TEST_MODE%"=="terminal" (
  echo [terminal QA] Clearing Redis DB1 after test runtime exit.
  "%TEST_REDIS_CLI%" -p %TEST_REDIS_PORT% -n 1 FLUSHDB >nul
  if errorlevel 1 if "%STATUS%"=="0" set "STATUS=1"
)
echo.
echo [%TEST_REDIS_NAME%] Test runtime exited with code %STATUS%.
wsl.exe --terminate "%WSL_PROJECT_DISTRO%" >nul 2>nul
"%TEST_REDIS_CLI%" -p %TEST_REDIS_PORT% shutdown nosave >nul 2>nul
rmdir /s /q "%TEST_LOCK_DIR%" >nul 2>nul
if "%CAT_NO_PAUSE%"=="1" exit /b %STATUS%
pause
exit /b %STATUS%

:ui_runtime_wait
set "WEBUI_RUNNING="
for /f "usebackq delims=" %%S in (`docker inspect -f "{{.State.Running}}" helpercat_test_ui 2^>nul`) do set "WEBUI_RUNNING=%%S"
if /I not "%WEBUI_RUNNING%"=="true" (
  echo [WebUI QA] Open WebUI container exited unexpectedly.
  set "STATUS=1"
  goto runtime_exit
)
"%TEST_REDIS_CLI%" -h 127.0.0.1 -p %TEST_REDIS_PORT% PING >nul 2>nul
if errorlevel 1 (
  echo [WebUI QA] Dedicated Redis exited unexpectedly.
  set "STATUS=1"
  goto runtime_exit
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$urls=@('http://127.0.0.1:18204/health','http://127.0.0.1:18201'); foreach($url in $urls){try{$response=Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 5; if($response.StatusCode -ne 200){exit 1}}catch{exit 1}}; exit 0"
if errorlevel 1 (
  set "STATUS=1"
  goto runtime_exit
)
powershell -NoProfile -Command "Start-Sleep -Seconds 30"
goto ui_runtime_wait

:runtime_exit
if not defined STATUS set "STATUS=1"
docker rm -f helpercat_test_ui >nul 2>nul
docker volume rm -f helpercat_test_ui_data >nul 2>nul
wsl.exe --terminate "%WSL_PROJECT_DISTRO%" >nul 2>nul
powershell -NoProfile -Command "Start-Sleep -Seconds 2"
"%TEST_REDIS_CLI%" -p %TEST_REDIS_PORT% -n 1 FLUSHDB >nul 2>nul
"%TEST_REDIS_CLI%" -p %TEST_REDIS_PORT% shutdown nosave >nul 2>nul
rmdir /s /q "%TEST_REDIS_DIR%" >nul 2>nul
rmdir /s /q "%TEST_RUNTIME_DIR%" >nul 2>nul
rmdir /s /q "%TEST_LOCK_DIR%" >nul 2>nul
if "%CAT_NO_PAUSE%"=="1" exit /b %STATUS%
pause
exit /b %STATUS%
