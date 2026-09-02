# HelperCat

HelperCat is a local health conversation service with fine-tuned cat tone and behaviours for companionship. 

## Repository layout

- `src/model/`: runtime conversation, memory, prompt templates, utilities, and training code; the core model design is in `src/model/README.md`.
- `src/server/`: Docker Compose, Windows launchers, WSL scripts, and server configuration.
- `data/`: frozen SFT data, selected DeepSeek examples, and biomedical retrieval seed data.
- `tests/`: focused regression tests and QA protocol documentation.
- `docs/`: project design material.

Runtime logs, Redis/WebUI databases, credentials, caches, model checkpoints, and training outputs are intentionally excluded from this package.

## Configure

1. `uv sync` for the runtime; use `uv sync --extra train` for the local training workflow.
2. Install Docker Desktop and, for local mode, WSL2 with the required GPU stack.
3. Configurations in each main src folders.
4. Set `CLOUD_BACKBONE_API_KEY` in the shell environment.
5. Download your own local model and do SFT training if that's wanted.
6. Install `cloudflared` separately when a public tunnel is required.

The checked-in `data/deepseek_examples/` and `data/cat_tone_sft.jsonl` files are versioned input data for the DeepSeek stage and local tone training.

## Run

From PowerShell:

```powershell
.\src\server\start_all.bat light
.\src\server\start_all.bat local
.\src\server\start_all.bat stop
```

`light` runs the WebUI and memory proxy without local vLLM. `local` adds the local Qwen support service. Open WebUI is exposed on port `18201`; the memory proxy uses `18202`.

## Test

For interactive QA, use `src/server/start_UI_testing.bat`. It uses disposable WebUI and separate Redis storage.


## Data and security

Each account is isolated by its own user namespace in Redis. Official Redis data and its AES key belong under the operator's private `%LOCALAPPDATA%\HelperCat` directory. Set encryption according to `src/model/memory/config/db_config.yaml` before using production data.


> [!NOTE]
> I'm not specialized in either Large Language Models or backend development, and it's my first agent-related project, clearly could have better designs (e.g. the db encryption). Therefore, if you have any kind of opinion, suggestion, or simply want to show me the industrial way of handling certain procedures, please don't hesitate to contact me.