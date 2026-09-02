import argparse
import hashlib
import json
import time
import uuid
from pathlib import Path

import yaml

from src.model.utils.db_operations import db_operations
from src.model.utils.paths import PROJECT_ROOT, resolve_local_path
from src.model.conversation.deepseek_client import DeepSeekClient


KAIROS_CANDIDATE_TYPES = frozenset(
    {
        "question",
        "idea",
        "goal_hypothesis",
        "memory_candidate",
        "rag_topic",
        "risk_note",
        "profile_conflict",
        "profile_update",
    }
)


def run_idle_reflection(
    project_root=PROJECT_ROOT,
    kairos_config_path="src/model/memory/config/kairos_config.yaml",
    memory_config_path="src/model/memory/config/memory_config.yaml",
    dry_run=False,
    max_files=8,
    min_idle_seconds=None,
):
    project_root = Path(project_root)
    kairos_config = yaml.safe_load(resolve_local_path(kairos_config_path, project_root).read_text(encoding="utf-8"))
    memory_config_file = resolve_local_path(memory_config_path, project_root)
    memory_config = yaml.safe_load(memory_config_file.read_text(encoding="utf-8"))
    db_config = yaml.safe_load(resolve_local_path(memory_config["db_config_path"], project_root).read_text(encoding="utf-8"))

    kairos = kairos_config.get("kairos", {})
    if not kairos.get("enabled", False):
        return {"status": "disabled", "stored": 0}

    memory = memory_config.get("memory", {})
    if min_idle_seconds is None:
        min_idle_seconds = float(kairos.get("idle_seconds", 600))
    redis_config = db_config["redis"]
    cache_files = _cache_files(project_root, kairos, int(max_files))
    if not cache_files:
        return {"status": "no_cache", "stored": 0}
    idle_for = time.time() - max(path.stat().st_mtime for path in cache_files)
    if idle_for < float(min_idle_seconds):
        return {"status": "not_idle", "stored": 0, "idle_for_seconds": int(idle_for)}
    grouped = {}
    for path in cache_files:
        user_id, text = _cache_user_text(project_root, path, memory.get("user_id", "default"))
        grouped.setdefault(user_id, []).append((path, text))
    stored = 0
    reflected = 0
    usage = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
    for user_id, records in grouped.items():
        batch_id = _cache_batch_id([path for path, _ in records])
        if _batch_seen(redis_config, user_id, batch_id):
            continue
        prompt = _reflection_prompt(records, db_operations.load_user_profile(redis_config, user_id), int(kairos.get("max_reflection_chars", 4000)), int(kairos.get("max_candidates", 6)), resolve_local_path(kairos["prompt_path"], project_root))
        if dry_run:
            text = '[{"type":"idea","text":"稍后复盘这段对话，并在写入长期档案前先征求用户确认。","confidence":0.2}]'
        else:
            response = DeepSeekClient(config_path=project_root / "src/model/conversation/config/reasoner_deepseek_config.yaml").complete(prompt, max_tokens=int(kairos.get("max_output_tokens", 1200)), include_system_prompt=False)
            text, usage = response.text, response.usage.__dict__
        candidates = _parse_candidates(text)
        if candidates is None:
            continue
        stored += _store_candidates(redis_config, user_id, candidates, batch_id=batch_id)
        _mark_batch_seen(redis_config, user_id, batch_id)
        reflected += 1
    db_operations.append_model_event(
        redis_config,
        {
            "t": int(time.time()),
            "type": "kairos_idle_reflection",
            "payload": {
                "stored": stored,
                "dry_run": bool(dry_run),
                "cache_files": len(cache_files),
                "users": reflected,
                "usage": usage,
            },
        },
    )
    return {"status": "ok" if reflected else "already_reflected", "stored": stored, "cache_files": len(cache_files), "users": reflected, "usage": usage}


def watch_idle_reflection(
    project_root=PROJECT_ROOT,
    kairos_config_path="src/model/memory/config/kairos_config.yaml",
    memory_config_path="src/model/memory/config/memory_config.yaml",
    dry_run=False,
    max_files=8,
    min_idle_seconds=None,
    interval_seconds=None,
    max_cycles=0,
):
    if min_idle_seconds is None or interval_seconds is None:
        config_path = resolve_local_path(kairos_config_path, project_root)
        kairos_config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
        kairos = kairos_config.get("kairos", {})
        min_idle_seconds = float(kairos.get("idle_seconds", 600)) if min_idle_seconds is None else min_idle_seconds
        interval_seconds = float(kairos.get("watch_interval_seconds", 300)) if interval_seconds is None else interval_seconds
    cycles = 0
    while True:
        result = run_idle_reflection(
            project_root,
            kairos_config_path,
            memory_config_path,
            dry_run=dry_run,
            max_files=max_files,
            min_idle_seconds=min_idle_seconds,
        )
        print(json.dumps(result, ensure_ascii=False), flush=True)
        cycles += 1
        if max_cycles and cycles >= max_cycles:
            return result
        time.sleep(float(interval_seconds))


def _cache_files(project_root, kairos, max_files):
    cache_dir = resolve_local_path(kairos.get("input_cache_dir", "output/input_cache"), project_root)
    if not cache_dir.exists():
        return []
    max_age = float(kairos.get("max_cache_age_hours", 168)) * 3600
    cutoff = time.time() - max_age
    files = [
        path
        for pattern in ("Retrieval_*.md", "User_*.md", "retrieval_*.md", "user_*.md")
        for path in cache_dir.glob(pattern)
        if path.name not in {"user_profile.md", "memory_schema.md"} and path.is_file() and path.stat().st_mtime >= cutoff
    ]
    return sorted(files, key=lambda path: path.stat().st_mtime, reverse=True)[:max_files]


def _cache_batch_id(cache_files):
    payload = [
        {"name": path.name, "mtime": int(path.stat().st_mtime), "size": path.stat().st_size}
        for path in cache_files
    ]
    return hashlib.sha1(json.dumps(payload, sort_keys=True).encode("utf-8")).hexdigest()


def _cache_user_text(project_root, path, legacy_user_id):
    from src.model.memory.cache_crypto import decrypt_text

    text = decrypt_text(project_root, path.read_bytes())
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return legacy_user_id, text
    if isinstance(payload, dict) and payload.get("user_id") and isinstance(payload.get("text"), str):
        return str(payload["user_id"]), payload["text"]
    return legacy_user_id, text


def _reflection_prompt(cache_records, profile, max_chars, max_candidates, prompt_path):
    user_chunks = []
    retrieval_chunks = []
    for path, text in cache_records:
        chunk = f"## {path.name}\n{text}"
        (retrieval_chunks if path.name.lower().startswith("retrieval_") else user_chunks).append(chunk)
    user_material = "\n\n".join(user_chunks)[-max_chars:]
    retrieval_material = "\n\n".join(retrieval_chunks)[-max_chars:]
    profile_summary = json.dumps(profile, ensure_ascii=False, separators=(",", ":"))
    template = prompt_path.read_text(encoding="utf-8")
    return template.replace("__MAX_CANDIDATES__", str(max_candidates)).replace(
        "__PROFILE_SUMMARY__", profile_summary
    ).replace("__USER_MATERIAL__", user_material or "(none)").replace(
        "__RETRIEVAL_MATERIAL__", retrieval_material or "(none)"
    )


def _parse_candidates(text):
    value = str(text).strip()
    if value.startswith("```"):
        value = value.split("\n", 1)[-1]
        if value.endswith("```"):
            value = value[:-3]
    try:
        obj = json.loads(value)
    except json.JSONDecodeError:
        return None
    if isinstance(obj, dict):
        obj = [obj]
    candidates = []
    for item in obj if isinstance(obj, list) else []:
        if not isinstance(item, dict):
            continue
        candidate_type = str(item.get("type", "idea")).strip()
        if candidate_type not in KAIROS_CANDIDATE_TYPES:
            continue
        value = {
            "type": candidate_type,
            "text": str(item.get("text", "")).strip(),
            "confidence": float(item.get("confidence", 0.1)),
            "created_at": int(time.time()),
            "status": "candidate",
        }
        for key in ("field", "current_value", "suggested_value", "evidence", "source", "replace_existing"):
            if item.get(key) not in (None, "", []):
                value[key] = item[key]
        if value["text"] and any("\u4e00" <= char <= "\u9fff" for char in value["text"]):
            candidates.append(value)
    return candidates[:10]


def _store_candidates(redis_config, user_id, candidates, batch_id=None):
    if not candidates:
        return 0
    recorded_at_ms = int(time.time() * 1000)
    stored = 0
    for candidate in candidates:
        if candidate.get("type") not in KAIROS_CANDIDATE_TYPES:
            continue
        candidate.update(
            {
                "id": candidate.get("id") or uuid.uuid4().hex,
                "recorded_at_ms": recorded_at_ms,
                "batch_id": batch_id,
                "source": candidate.get("source") or "kairos_idle_reflection",
                "schema_version": 4,
            }
        )
        db_operations.append_kairos_candidate(redis_config, user_id, candidate)
        stored += 1
    return stored


def _batch_seen(redis_config, user_id, batch_id):
    client = db_operations.client(redis_config, "user_memory")
    key = db_operations.user_key(redis_config, user_id, "reflected_cache_batches")
    return batch_id in {db_operations._decode(redis_config, value) for value in client.smembers(key)}


def _mark_batch_seen(redis_config, user_id, batch_id):
    client = db_operations.client(redis_config, "user_memory")
    key = db_operations.user_key(redis_config, user_id, "reflected_cache_batches")
    client.sadd(key, db_operations._encode(redis_config, batch_id))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", default=str(PROJECT_ROOT))
    parser.add_argument("--kairos-config", default="src/model/memory/config/kairos_config.yaml")
    parser.add_argument("--memory-config", default="src/model/memory/config/memory_config.yaml")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--max-files", type=int, default=8)
    parser.add_argument("--min-idle-seconds", type=int)
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--interval-seconds", type=int)
    parser.add_argument("--max-cycles", type=int, default=0)
    args = parser.parse_args()
    if args.watch:
        watch_idle_reflection(
            args.project_root,
            args.kairos_config,
            args.memory_config,
            dry_run=args.dry_run,
            max_files=args.max_files,
            min_idle_seconds=args.min_idle_seconds,
            interval_seconds=args.interval_seconds,
            max_cycles=args.max_cycles,
        )
        return
    print(
        json.dumps(
            run_idle_reflection(
                args.project_root,
                args.kairos_config,
                args.memory_config,
                args.dry_run,
                args.max_files,
                args.min_idle_seconds,
            ),
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
