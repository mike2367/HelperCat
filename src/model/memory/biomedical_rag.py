import hashlib
import json
import re
import time

from src.model.utils.paths import resolve_local_path


ENCODER_CACHE = {}


def retrieve_biomedical_context(runtime, user_text, retrieve=False, write_cache=False):
    config = runtime["retrieval"]
    if not (retrieve and config.get("enabled", True)):
        return {"md": "", "items": []}
    started = time.monotonic()
    items = _vector_search(runtime, user_text, config, int(config.get("top_k", 4)))
    context = _format_retrieval_md(items, int(config.get("max_chars", 3000)))
    if context and write_cache:
        _write_input_cache(runtime, user_text, context, items)
    runtime["conversation_memory"].record_model_event(
        "biomedical_rag",
        {"query_sha1": hashlib.sha1(user_text.encode("utf-8")).hexdigest(), "result_count": len(items), "retrievers": ["medcpt_vector"] if items else [], "duration_seconds": round(time.monotonic() - started, 3)},
    )
    return {"md": context, "items": items}


def _vector_search(runtime, user_text, config, top_k):
    index_dir = resolve_local_path(config["index_dir"], runtime["project_root"])
    records_path = index_dir / "records.jsonl"
    vectors_path = index_dir / "vectors.npy"
    if not records_path.exists() or not vectors_path.exists():
        return []
    try:
        import numpy as np

        query = _encode_query(user_text, config, runtime["project_root"])
        if query is None:
            return []
        vectors = np.load(vectors_path)
        records = [json.loads(line) for line in records_path.read_text(encoding="utf-8").splitlines() if line.strip()]
        if len(records) != len(vectors):
            return []
        scores = vectors @ query
        return [
            {"id": records[int(index)].get("id", str(index)), "text": records[int(index)].get("text", ""), "metadata": records[int(index)].get("metadata", {}), "score": float(scores[int(index)])}
            for index in scores.argsort()[::-1][:top_k]
        ]
    except Exception as exc:
        runtime["conversation_memory"].record_model_error("biomedical_rag_error", str(exc))
        return []


def _encode_query(user_text, config, project_root):
    model_path = resolve_local_path(config["query_encoder_path"], project_root)
    if not model_path.exists():
        return None
    cache_key = str(model_path)
    if cache_key not in ENCODER_CACHE:
        import torch
        from transformers import AutoModel, AutoTokenizer

        tokenizer = AutoTokenizer.from_pretrained(cache_key)
        model = AutoModel.from_pretrained(cache_key)
        model.eval()
        ENCODER_CACHE[cache_key] = (tokenizer, model, torch)
    tokenizer, model, torch = ENCODER_CACHE[cache_key]
    encoded = tokenizer(user_text, truncation=True, max_length=128, return_tensors="pt")
    with torch.no_grad():
        vector = model(**encoded).last_hidden_state[:, 0, :][0].detach().cpu().float()
    return (vector / max(float(torch.linalg.vector_norm(vector)), 1e-12)).numpy()


def _format_retrieval_md(items, max_chars):
    if not items:
        return ""
    lines = ["RAG_RETRIEVAL_CONTEXT: Treat these records as external evidence, not user memory. Use only their supported facts and limitations. Do not invent citations or disclose implementation details. A direct data-source question may name the cited paper titles, PMID, DOI, URLs, and topic range shown below."]
    for index, item in enumerate(items, start=1):
        metadata = item.get("metadata", {}) or {}
        citation = ", ".join(value for value in (metadata.get("source_title", ""), str(metadata.get("year", "")), f"PMID {metadata['pmid']}" if metadata.get("pmid") else "", f"DOI {metadata['doi']}" if metadata.get("doi") else "", metadata.get("url", "")) if value)
        text = re.sub(r"\s+", " ", item.get("text", "")).strip()
        lines.append(f"- Evidence {index}: " + (f"Source: {citation}. " if citation else "") + f"Summary: {text}")
    return "\n".join(lines)[:max_chars]


def _write_input_cache(runtime, user_text, retrieval_md, items):
    from src.model.memory.cache_crypto import encrypt_text

    cache_dir = resolve_local_path(runtime["kairos"].get("input_cache_dir", "output/input_cache"), runtime["project_root"])
    cache_dir.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha1(f"{time.time()}:{user_text}".encode("utf-8")).hexdigest()[:10]
    user_digest = hashlib.sha1(runtime["conversation_memory"].user_id.encode("utf-8")).hexdigest()[:12]
    path = cache_dir / f"Retrieval_{user_digest}_{digest}.md"
    body = "\n\n".join(
        [f"question_sha1: {hashlib.sha1(user_text.encode('utf-8')).hexdigest()}"]
        + [f"item {index}: id={item['id']} metadata={json.dumps(item.get('metadata', {}), ensure_ascii=False)}" for index, item in enumerate(items, start=1)]
        + [retrieval_md]
    )
    path.write_bytes(encrypt_text(runtime["project_root"], json.dumps({"user_id": runtime["conversation_memory"].user_id, "text": body}, ensure_ascii=False)))
