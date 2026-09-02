import argparse
import json
from pathlib import Path

import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

from src.model.utils.paths import resolve_local_path


def load_records(path):
    rows = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        rows.append(
            {
                "id": row["id"],
                "text": row["text"],
                "metadata": row.get("metadata", {}),
            }
        )
    return rows


def embed_texts(texts, encoder_path, batch_size=8, max_length=256, device="cpu"):
    tokenizer = AutoTokenizer.from_pretrained(str(encoder_path))
    model = AutoModel.from_pretrained(str(encoder_path)).to(device)
    model.eval()
    vectors = []
    with torch.no_grad():
        for start in range(0, len(texts), batch_size):
            batch = texts[start : start + batch_size]
            encoded = tokenizer(batch, padding=True, truncation=True, max_length=max_length, return_tensors="pt")
            encoded = {key: value.to(device) for key, value in encoded.items()}
            output = model(**encoded).last_hidden_state[:, 0, :].detach().cpu().float()
            output = output / torch.clamp(torch.linalg.vector_norm(output, dim=1, keepdim=True), min=1e-12)
            vectors.append(output.numpy())
            if start == 0 or (start // batch_size) % 100 == 0:
                print(f"embedded {min(start + len(batch), len(texts))}/{len(texts)}", flush=True)
    return np.vstack(vectors).astype("float32")


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output-dir", default="data/retrieval/biomedical_rag")
    parser.add_argument("--encoder-path", default="E:/local_models/MedCPT-Article-Encoder")
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--max-length", type=int, default=192)
    args = parser.parse_args(argv)

    records = load_records(args.input)
    output_dir = resolve_local_path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    encoder_path = resolve_local_path(args.encoder_path)
    vectors = embed_texts(
        [record["text"] for record in records],
        encoder_path,
        batch_size=args.batch_size,
        max_length=args.max_length,
        device=args.device,
    )

    (output_dir / "records.jsonl").write_text(
        "\n".join(json.dumps(record, ensure_ascii=False, separators=(",", ":")) for record in records) + "\n",
        encoding="utf-8",
    )
    np.save(output_dir / "vectors.npy", vectors)
    print(json.dumps({"records": len(records), "dim": int(vectors.shape[1]), "output_dir": str(output_dir)}, ensure_ascii=False))


if __name__ == "__main__":
    raise SystemExit(main())
