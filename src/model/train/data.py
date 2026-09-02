import json
import random
from collections import defaultdict
from pathlib import Path

def read_jsonl(path):
    with Path(path).open("r", encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def load_sft_rows(data_path, system_path):
    system_content = Path(system_path).read_text(encoding="utf-8").strip()
    rows = read_jsonl(data_path)
    for row in rows:
        source_messages = row["messages"]
        user_message = next(message for message in reversed(source_messages) if message["role"] == "user")
        assistant_message = next(message for message in reversed(source_messages) if message["role"] == "assistant")
        renderer_system = (
            f"{system_content}\n\n"
            "DEEPSEEK CONTENT DRAFT:\n"
            f"{assistant_message['content']}\n\n"
            "Render this complete draft in the required cat tone. Preserve all substantive content exactly."
        )
        row["messages"] = [
            {"role": "system", "content": renderer_system},
            {"role": "user", "content": user_message["content"]},
            assistant_message,
        ]
    return rows


def stratified_split(rows, train_fraction, seed):
    by_task = defaultdict(list)
    for row in rows:
        by_task[row["task"]].append(row)

    train_rows = []
    eval_rows = []
    rng = random.Random(seed)
    for task_rows in by_task.values():
        rng.shuffle(task_rows)
        eval_count = min(len(task_rows) - 1, max(1, round(len(task_rows) * (1 - train_fraction))))
        eval_rows.extend(task_rows[:eval_count])
        train_rows.extend(task_rows[eval_count:])
    rng.shuffle(train_rows)
    rng.shuffle(eval_rows)
    return train_rows, eval_rows


def tokenize_sft_rows(rows, tokenizer, max_length):
    samples = []
    for row in rows:
        messages = row["messages"]
        input_ids = tokenizer.apply_chat_template(
            messages,
            tokenize=True,
            add_generation_prompt=False,
            return_dict=False,
        )
        labels = [-100] * len(input_ids)

        for i, message in enumerate(messages):
            if message["role"] != "assistant":
                continue
            prefix = tokenizer.apply_chat_template(
                messages[:i],
                tokenize=True,
                add_generation_prompt=False,
                return_dict=False,
            )
            chunk = tokenizer.apply_chat_template(
                messages[: i + 1],
                tokenize=True,
                add_generation_prompt=False,
                return_dict=False,
            )
            labels[len(prefix) : len(chunk)] = input_ids[len(prefix) : len(chunk)]

        samples.append(
            {
                "input_ids": input_ids[:max_length],
                "labels": labels[:max_length],
                "task": row["task"],
            }
        )
    return samples


def collate_sft(batch, pad_token_id):
    import torch

    max_len = max(len(x["input_ids"]) for x in batch)
    input_ids = []
    labels = []
    attention_mask = []
    for sample in batch:
        pad_len = max_len - len(sample["input_ids"])
        input_ids.append(sample["input_ids"] + [pad_token_id] * pad_len)
        labels.append(sample["labels"] + [-100] * pad_len)
        attention_mask.append([1] * len(sample["input_ids"]) + [0] * pad_len)
    return {
        "input_ids": torch.tensor(input_ids, dtype=torch.long),
        "labels": torch.tensor(labels, dtype=torch.long),
        "attention_mask": torch.tensor(attention_mask, dtype=torch.long),
    }
