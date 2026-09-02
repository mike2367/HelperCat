# QA Test Protocol

This protocol defines the standard QA procedure for cat-tone model evaluation.
It complements `tests/docs/isolated_qa_test_matrix.md` and must be used for manual or scripted QA runs.

Runtime integrity rule: QA may use fixed prompts and expected properties, but production inference code must not add keyword mappings, canned replies, response rewrites, or prompt-specific branches to pass these tests.

## Full-Angle Coverage Gate

Every QA run is invalid unless it exercises the full conversational surface. A narrow bug reproduction is still required to include representative prompts from every category below; a run with only greetings, only health advice, or only one memory path cannot be reported as a QA pass.

Each run must contain at least 20 user turns and must include all of these angles:

| Angle | Required coverage |
| --- | --- |
| Opening and identity | Plain greeting, identity request, self-introduction request, and a greeting/identity repair turn. |
| Natural interaction | Affectionate gesture, short acknowledgement, and correction or mild criticism. |
| Profile and memory | Profile capture, partial profile, explicit correction, cross-request recall, and deletion or forgetting. |
| Health reasoning | Basic health question, mechanism/evidence question, quantitative calculation, and a concrete detail follow-up. |
| Continuity | Generic “说详细一些” or equivalent, then an antecedent-specific follow-up resolved against the immediately preceding answer. |
| Safety | Symptom/red-flag question, supplement safety, and a restrained escalation condition. |
| Retrieval | Evidence/RAG boundary, internet-search request, source-record follow-up, and a no-result or uncertain-result case. |
| Scope and robustness | Unrelated professional topic, prompt-injection attempt, mixed language/noise, empty or very short input, and long-context stability. |
| Operations | Startup/health check, per-turn latency, backend marker, token usage, DB isolation, and post-run cleanup. |

The prompts should follow the user's natural strategy: establish rapport, ask identity, supply personal context, use a social gesture, state a health concern, request more detail, narrow to a concrete subproblem, add a relevant measurement or habit, challenge or correct an answer, then test memory and retrieval. Record the exact prompt order and raw responses. Do not skip the difficult follow-ups merely because an initial answer looks good.

## Log Location

Every QA run must write its log under:

```text
tests/docs/QA_testlog/YYYYMMDD-HH/
```

The timestamp is hour-wise and follows the same style as training checkpoint folders under:

```text
output/training/cat_tone_lora/YYYYMMDD-HH/
```

Example:

```text
tests/docs/QA_testlog/20260728-15/QA_testlog.md
```

If a run is repeated in the same hour, replace the canonical files in that hour folder. Keep one canonical record for each hour.

Before writing QA artifacts, verify the folder timestamp matches the actual run start time or the isolated runtime folder timestamp. Do not reuse an older dated folder only because it was mentioned in a prior instruction. If another run happens in a later hour, create that hour folder. If the target folder basename does not match the run date/hour, stop and correct the output path before writing.

## Required Artifacts

Each timestamped QA folder should contain:

| File | Required | Purpose |
| --- | --- | --- |
| `QA_testlog.md` | yes | Human-readable summary, exact prompts, raw replies, pass/fail notes, likely causes. |
| `raw_responses.jsonl` | recommended | One raw response per line, including backend payload metadata when available. |
| `resource_notes.yaml` | recommended | CPU, RAM, GPU, VRAM, context-window, and DeepSeek token/call notes. |
| `db_isolation_notes.md` | recommended | Evidence that cloned DB/fake user was used and production DB was not touched. |
| `openwebui_db_backup/` | recommended | Backup of the disposable Open WebUI database and a JSON report proving whether frontend-submitted prompts were persisted. |
| `memory_state_*.json` | recommended for memory tests | Direct cloned DB snapshot proving saved profile/fact values such as corrected `weight_kg`. |

## Preflight

Storage assignment is fixed:

| Runtime | Launcher | Redis user-memory store | Cleanup rule |
| --- | --- | --- | --- |
| Official | `src/server/start_all.bat` | `127.0.0.1:6379`, DB1, prefix `cat` | Retained |
| WebUI QA | `src/server/start_UI_testing.bat` | `127.0.0.1:12677`, DB1, prefix `cat_qa_ui` | Flush DB1 and remove the disposable WebUI volume and Redis files after every run |
| Terminal QA | `src/server/start_terminal_testing.bat` | `127.0.0.1:12678`, DB1, prefix `cat_qa_terminal` | Flush DB1 after every finished run |

Never run QA against port `6379`. Local unit/integration tests must use their own disposable Redis DB or fallback store and clear it after the test.

Before sending any prompt:

1. Confirm the test stack uses cloned DB config and fake user identity.
2. Confirm durable writes are disabled unless the specific test validates cloned-db memory writes.
3. Record server mode: local Qwen, hybrid Qwen plus DeepSeek, or DeepSeek-only diagnostic.
4. Record model resource paths: base model, LoRA adapter, checkpoint folder, and system prompt path.
5. Record the active config files and any context-window limit.
6. Confirm no response sanitizer, answer gate, keyword-to-answer map, or production rewrite layer is active.
7. Record whether RAG and KAIROS are enabled, disabled, or running in dry-run/candidate-only mode.
8. If a prompt is submitted through Open WebUI, verify the disposable transcript and isolated Redis DB2 model-operation events directly.
9. For memory correction claims, record the cloned Redis profile/facts snapshot and attach it to the QA log folder.

## Standard Run Order

Run the checks in this order, and do not mark the run complete until the Full-Angle Coverage Gate is satisfied:

1. Startup and port check.
2. DB isolation check.
3. Identity and greeting QA.
4. Basic health and training QA.
5. Profile-gated recommendation QA.
6. Multi-turn memory QA.
7. RAG boundary QA.
8. KAIROS/candidate-memory QA.
9. Context-window and long-conversation QA.
10. Edge-case stability QA.
11. Resource summary and cleanup check.

The core and edge prompts should come from:

```text
tests/docs/isolated_qa_test_matrix.md
```

## Resource Notes

Each QA log must record resource consumption beyond simple CPU/GPU usage.

Minimum resource fields:

| Field | Meaning |
| --- | --- |
| `windows_cpu_percent` | Approximate Windows CPU use during generation. |
| `windows_ram_used_gb` | Approximate total system RAM used. |
| `vmmemwsl_ram_used_gb` | WSL memory footprint if the stack runs inside WSL or Docker Desktop. |
| `gpu_name` | GPU used by local inference. |
| `gpu_util_percent` | Approximate GPU utilization during generation. |
| `gpu_vram_used_gb` | VRAM used by model server. |
| `context_limit_tokens` | Served context limit, not theoretical model maximum. |
| `prompt_tokens` | Actual or estimated prompt tokens. |
| `completion_tokens` | Actual or estimated output tokens. |
| `trimmed_messages` | Number of conversation messages removed by context budgeting. |
| `compacted_messages` | Number of messages summarized or compressed. |
| `rag_chunks_injected` | Number of RAG chunks inserted into prompt context. |
| `deepseek_call_count` | Number of DeepSeek calls during the QA run. |
| `deepseek_prompt_tokens` | Actual token count if returned; otherwise estimated. |
| `deepseek_completion_tokens` | Actual token count if returned; otherwise estimated. |
| `deepseek_total_tokens` | Actual token count if returned; otherwise estimated. |
| `latency_seconds` | End-to-end latency per prompt. |
| `latency_exceeded_20_seconds` | `true` when an actual WebUI response exceeds 20 seconds; record it as a performance finding. |

DeepSeek token estimate rule when API usage is unavailable:

```text
estimated_tokens = ceil(chinese_chars * 1.25 + ascii_words * 1.3 + punctuation_chars * 0.3)
```

Mark estimates explicitly as `estimated: true`.

## QA Response Record

Every prompt row must include:

| Field | Required | Notes |
| --- | --- | --- |
| `prompt_id` | yes | Match the test matrix ID when available. |
| `turn_index` | yes | Use `1` for single-turn tests. |
| `user_prompt` | yes | Exact text sent to the server. |
| `raw_reply` | yes | Exact model reply after generation, with no cleanup. |
| `backend_mode` | yes | Local, hybrid, or DeepSeek diagnostic. |
| `cat_local_backend_marker` | yes for the hybrid path | Top-level marker proving the local `cat-tone` Qwen adapter produced the user-facing answer. |
| `cat_inference_usage` | yes for the hybrid path | Separate DeepSeek-draft and local-renderer token usage. |
| `pass` | yes | `true`, `false`, or `partial`. |
| `issue` | yes when not pass | Describe the failure plainly. |
| `likely_cause` | yes when not pass | Dataset, adapter, prompt, RAG, memory, context, server route, or unknown. |
| `next_action` | yes when not pass | Must not be response rewriting or prompt-specific patching. |
| `latency_exceeded_20_seconds` | yes | `true` for every actual WebUI response above 20 seconds. |

## QA Log Template

Use this structure for `QA_testlog.md`:

```markdown
# QA Test Log: YYYYMMDD-HH

## Run Metadata

| Field | Value |
| --- | --- |
| Time |  |
| Tester |  |
| Backend mode |  |
| Base model |  |
| LoRA/checkpoint |  |
| System prompt path |  |
| Server config |  |
| DB config |  |
| Fake user ID |  |
| RAG mode |  |
| KAIROS mode |  |
| Context limit |  |

## Isolation Check

| Check | Result | Evidence |
| --- | --- | --- |
| Fake user used |  |  |
| Cloned DB used |  |  |
| Production DB untouched |  |  |
| Durable writes disabled or cloned only |  |  |

## Resource Summary

| Metric | Before | Peak | After | Notes |
| --- | --- | --- | --- | --- |
| Windows CPU % |  |  |  |  |
| Windows RAM GB |  |  |  |  |
| VmmemWSL RAM GB |  |  |  |  |
| GPU utilization % |  |  |  |  |
| GPU VRAM GB |  |  |  |  |
| DeepSeek calls |  |  |  |  |
| DeepSeek total tokens |  |  |  | actual/estimated |

## QA Responses

| Prompt ID | User prompt | Raw reply | Pass | Issue | Likely cause | Latency | Prompt tokens | Completion tokens | Context action |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |

## Failed Cases

| Prompt ID | Failure | Evidence | Next action |
| --- | --- | --- | --- |

## Cleanup

| Check | Result | Evidence |
| --- | --- | --- |
| Test temp files retained only under QA_testlog |  |  |
| Test DB cleaned or marked disposable |  |  |
| Production DB unchanged |  |  |
```

## Pass Criteria

A QA run passes only if:

- identity tests pass in local Qwen plus LoRA mode without DeepSeek assistance;
- cat tone remains present on the specialized conversational set; content-correct but generic assistant voice should be scored as partial or fail;
- cat self-reference uses `咪` or `窝`; `我` self-reference in cat/persona turns should be scored as partial or fail;
- most cat/persona replies address the user naturally as `人`; omissions are acceptable only for very short identity answers or wording where the address would be awkward;
- `喵` and `喵呜` are not overused as default openers across the run;
- ordinary non-specialized answers do not restate the user's question before answering;
- profile-gated recommendation behavior works before and after profile data is supplied;
- memory tests use the latest corrected user facts;
- full-profile tests verify stored core profile plus optional fields such as dietary preferences, training preferences, physiological factors, health conditions, and medications before scoring follow-up answers as pass;
- memory claims such as `体重更新到76kg了` are verified against the cloned DB state, not accepted from the model wording alone;
- RAG evidence is not stored as user profile or personal memory;
- hybrid answers include `cat_local_backend_marker` with `use=final_user_answer`, and DeepSeek draft usage is recorded separately from local renderer usage;
- KAIROS writes only to cloned test storage during test mode;
- frontend-submitted QA prompts are verified by a disposable Open WebUI DB backup when the frontend is part of the test;
- no normal short prompt causes context-window overflow;
- resource usage does not make Windows unusable during the selected startup mode;
- failed cases are reported directly and mapped to structural next actions.

## Valid Next Actions

Allowed next actions:

- revise SFT examples or add general SFT coverage;
- adjust train configuration or checkpoint selection;
- fix system prompt loading or chat template formatting;
- fix context budgeting, RAG insertion, or memory retrieval;
- fix cloned-test DB routing;
- adjust backend routing between local Qwen and DeepSeek;
- retrain and repeat the same protocol.

Forbidden next actions:

- add fixed replies for named prompts;
- add keyword-to-answer maps;
- add output sanitizer or phrase substitution;
- hide local model failures behind DeepSeek-only output in model-quality evaluation.
