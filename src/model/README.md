# Model

HelperCat is a local OpenAI-compatible conversational agent. Its core model design is one local base model plus a LoRA adapter used for surface tone, with DeepSeek as the substantive answer backend.

## Core design

- DeepSeek stage: owns intent, reasoning, calculations, evidence use, safety boundaries, and answer completeness.
- Boundary stage: a local Qwen classifier labels ordinary, profile-gating, safety, legal, capability, and repair cases.
- Retrieval stage: optional local biomedical evidence is injected as context, never as durable user facts.
- Renderer stage: the local Qwen LoRA renders the final cat tone without changing the already-completed answer.
- Memory stage: per-user Redis facts and events provide day-to-day continuity; model evolution happens through memory, not online fine-tuning.

The active local base model is `Qwen/Qwen3-4B-Instruct-2507`, served through the `HelperCat` LoRA adapter. DeepSeek remains the only user-facing content model.

## Component layout

- `conversation`: OpenAI-compatible memory proxy, boundary routing, retrieval context, DeepSeek call, and Qwen renderer call.
- `memory`: per-user profile facts, recent events, audit trail, KAIROS candidates, and local biomedical retrieval.
- `prompt_templates`: all model instructions, including DeepSeek content, cat-tone rendering, boundary classification, and KAIROS reflection.
- `train`: SFT/adapter data loading, tokenization, splitting, and LoRA training.
- `utils`: project paths, resource cleanup, and Redis/JSON-fallback database operations.

## Environment

Use `uv` from the repository root.

```powershell
uv sync
uv sync --extra train
```

`uv sync` installs the runtime dependencies. The `train` extra adds PyTorch, Transformers, PEFT, and training progress output for the local adapter workflow.
