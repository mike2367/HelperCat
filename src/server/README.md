# Server

This folder starts the three runtime pieces:

- Open WebUI on host port `18201`.
- The OpenAI-compatible memory proxy on `18202`.
- Optional local vLLM support on `18203`.

The WebUI calls the memory proxy. The proxy owns user isolation, memory writes, boundary classification, retrieval context, and the configured cloud generation call.

## Prerequisites

- Windows 10/11 with Docker Desktop.
- WSL2 and a working Python environment for local mode.
- A configured cloud endpoint (e.g DeepSeek) and `CLOUD_BACKBONE_API_KEY`.
- Local model and adapter paths filled in as placeholder values in `server_config.yaml` when using local mode.

## Start and stop

```powershell
.\start_all.bat light
.\start_all.bat local
.\start_all.bat stop
```

`light` skips vLLM and is useful for cloud-only smoke checks. `local` starts the Qwen support service as well. `full` is accepted as an alias by the launcher.

## Interactive QA

```powershell
.\start_UI_testing.bat reset-memory
.\start_terminal_testing.bat
```

QA uses disposable Redis/WebUI storage and separate key prefixes. The launchers remove their runtime state on exit.

## Configuration and secrets

`server_config.yaml` is the single source for ports, service paths, and the local proxy token. Keep provider credentials in environment variables, especially `CLOUD_BACKBONE_API_KEY`. 

`resources/cat-avatar.png` is the WebUI logo and favicon. 

## Logs and runtime data

Launchers write logs under `src/server/logs/official/<run-id>/` or `src/server/logs/test/<run-id>/`. Redis data and WebUI databases live outside the repository under the operator's private runtime directory or disposable Docker volumes.
