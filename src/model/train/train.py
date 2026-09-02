import argparse
import csv
import json
import logging
import random
from argparse import Namespace
from datetime import datetime
from pathlib import Path

import torch
from peft import LoraConfig, PeftModel, get_peft_model, prepare_model_for_kbit_training
from torch.utils.data import DataLoader
from tqdm.auto import tqdm
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig

from src.model.train.data import collate_sft, load_sft_rows, stratified_split, tokenize_sft_rows
from src.model.utils.paths import resolve_local_path
from src.model.utils.runtime_resources import release_model_resources

logging.getLogger("torch.distributed.elastic.multiprocessing.redirects").setLevel(logging.ERROR)
logging.getLogger("transformers").setLevel(logging.ERROR)



def evaluate(model, eval_loader):
    model.eval()
    losses = []
    device = next(model.parameters()).device
    with torch.no_grad():
        for batch in eval_loader:
            batch = {k: v.to(device) for k, v in batch.items()}
            losses.append(model(**batch).loss.item())
    model.train()
    return sum(losses) / len(losses)


def save_checkpoint(model, tokenizer, optimizer, run_dir, step, epoch, batch_index):
    checkpoint_dir = run_dir / "checkpoints" / f"checkpoint-step-{step:06d}"
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(checkpoint_dir)
    tokenizer.save_pretrained(checkpoint_dir)
    torch.save(optimizer.state_dict(), checkpoint_dir / "optimizer.pt")
    torch.save(
        {"step": step, "epoch": epoch, "batch_index": batch_index},
        checkpoint_dir / "training_state.pt",
    )
    (run_dir / "latest_checkpoint.txt").write_text(str(checkpoint_dir), encoding="utf-8")


def save_best_checkpoint(model, tokenizer, optimizer, run_dir, step, epoch, batch_index, eval_loss):
    checkpoint_dir = run_dir / "checkpoints" / "best"
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(checkpoint_dir)
    tokenizer.save_pretrained(checkpoint_dir)
    torch.save(optimizer.state_dict(), checkpoint_dir / "optimizer.pt")
    torch.save(
        {"step": step, "epoch": epoch, "batch_index": batch_index, "eval_loss": eval_loss},
        checkpoint_dir / "training_state.pt",
    )
    (checkpoint_dir / "best_checkpoint.json").write_text(
        json.dumps({"step": step, "eval_loss": eval_loss}, indent=2),
        encoding="utf-8",
    )


def train_sft(args):
    required_fields = (
        "model_dir",
        "data_path",
        "system_path",
        "training_root",
        "run_name",
        "max_length",
        "batch_size",
        "grad_accum",
        "lr",
        "epochs",
        "seed",
        "max_steps",
        "eval_every_steps",
        "save_every_steps",
        "resume_dir",
    )
    if isinstance(args, dict):
        args = Namespace(**args)
    elif not isinstance(args, Namespace):
        raise TypeError("train_sft expects a config dict or argparse.Namespace")

    missing_fields = [field for field in required_fields if not hasattr(args, field)]
    if missing_fields:
        raise ValueError(f"Training config is missing required fields: {', '.join(missing_fields)}")

    project_root = Path.cwd()
    model_dir = resolve_local_path(args.model_dir, project_root)
    data_path = resolve_local_path(args.data_path, project_root)
    system_path = resolve_local_path(args.system_path, project_root)

    random.seed(args.seed)
    torch.manual_seed(args.seed)

    run_dir = resolve_local_path(args.resume_dir, project_root) if args.resume_dir else Path(args.training_root) / args.run_name / datetime.now().strftime("%Y%m%d-%H")
    run_dir.mkdir(parents=True, exist_ok=True)
    checkpoint_dir = None
    if args.resume_dir:
        checkpoint_dir = resolve_local_path((run_dir / "latest_checkpoint.txt").read_text(encoding="utf-8").strip(), project_root)

    tokenizer = AutoTokenizer.from_pretrained(str(model_dir), trust_remote_code=True)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token

    rows = load_sft_rows(data_path, system_path)
    train_rows, eval_rows = stratified_split(rows, train_fraction=0.9, seed=args.seed)
    train_samples = tokenize_sft_rows(train_rows, tokenizer, args.max_length)
    eval_samples = tokenize_sft_rows(eval_rows, tokenizer, args.max_length)

    quantization = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_compute_dtype=torch.bfloat16,
        bnb_4bit_use_double_quant=True,
    )
    model = AutoModelForCausalLM.from_pretrained(
        str(model_dir),
        trust_remote_code=True,
        device_map={"": 0},
        quantization_config=quantization,
    )
    model = prepare_model_for_kbit_training(
        model,
        gradient_checkpointing_kwargs={"use_reentrant": False},
    )
    if checkpoint_dir:
        model = PeftModel.from_pretrained(model, checkpoint_dir, is_trainable=True)
    else:
        model = get_peft_model(
            model,
            LoraConfig(
                r=8,
                lora_alpha=16,
                lora_dropout=0.05,
                bias="none",
                task_type="CAUSAL_LM",
                target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
            ),
        )
    model.train()

    train_loader = DataLoader(
        train_samples,
        batch_size=args.batch_size,
        shuffle=False,
        collate_fn=lambda batch: collate_sft(batch, tokenizer.pad_token_id),
    )
    eval_loader = DataLoader(
        eval_samples,
        batch_size=args.batch_size,
        shuffle=False,
        collate_fn=lambda batch: collate_sft(batch, tokenizer.pad_token_id),
    )
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr)
    device = next(model.parameters()).device
    resume_state = {"step": 0, "epoch": 0, "batch_index": 0}
    if checkpoint_dir:
        resume_state = torch.load(checkpoint_dir / "training_state.pt", map_location=device)
        optimizer.load_state_dict(torch.load(checkpoint_dir / "optimizer.pt", map_location=device))

    log_path = run_dir / "metrics.csv"
    append_metrics = checkpoint_dir is not None and log_path.exists()
    best_checkpoint_path = run_dir / "checkpoints" / "best" / "best_checkpoint.json"
    best_eval_loss = float("inf")
    if best_checkpoint_path.exists() and (best_checkpoint_path.parent / "optimizer.pt").exists() and (best_checkpoint_path.parent / "training_state.pt").exists():
        best_eval_loss = json.loads(best_checkpoint_path.read_text(encoding="utf-8"))["eval_loss"]
    with log_path.open("a" if append_metrics else "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["step", "train_loss", "eval_loss"])
        if not append_metrics:
            writer.writeheader()
        step = resume_state["step"]

        steps_per_epoch = (len(train_loader) + args.grad_accum - 1) // args.grad_accum
        total_steps = args.max_steps if args.max_steps else steps_per_epoch * args.epochs
        progress = tqdm(total=total_steps, initial=step, desc="training steps")

        for epoch in range(args.epochs):
            if epoch < resume_state["epoch"]:
                continue
            optimizer.zero_grad()
            for batch_index, batch in enumerate(train_loader, start=1):
                if epoch == resume_state["epoch"] and batch_index <= resume_state["batch_index"]:
                    continue
                batch = {k: v.to(device) for k, v in batch.items()}
                loss = model(**batch).loss / args.grad_accum
                loss.backward()

                if batch_index % args.grad_accum == 0:
                    optimizer.step()
                    optimizer.zero_grad()
                    step += 1
                    train_loss = loss.item() * args.grad_accum
                    final_step = step >= total_steps
                    if (args.eval_every_steps and step % args.eval_every_steps == 0) or final_step:
                        eval_loss = evaluate(model, eval_loader)
                        if eval_loss < best_eval_loss:
                            best_eval_loss = eval_loss
                            save_best_checkpoint(model, tokenizer, optimizer, run_dir, step, epoch, batch_index, eval_loss)
                    else:
                        eval_loss = ""
                    writer.writerow({"step": step, "train_loss": train_loss, "eval_loss": eval_loss})
                    f.flush()
                    progress.update(1)
                    progress.set_postfix(train_loss=train_loss, eval_loss=eval_loss)

                    if args.save_every_steps and step % args.save_every_steps == 0:
                        save_checkpoint(model, tokenizer, optimizer, run_dir, step, epoch, batch_index)

                    if args.max_steps and step >= args.max_steps:
                        model.save_pretrained(run_dir / "final")
                        tokenizer.save_pretrained(run_dir / "final")
                        progress.close()
                        del model, tokenizer, optimizer, batch, loss
                        release_model_resources()
                        return run_dir

            remainder = len(train_loader) % args.grad_accum
            if remainder and not (args.max_steps and step >= total_steps):
                for parameter in model.parameters():
                    if parameter.grad is not None:
                        parameter.grad.mul_(args.grad_accum / remainder)
                optimizer.step()
                optimizer.zero_grad()
                step += 1
                train_loss = loss.item() * args.grad_accum
                final_step = step >= total_steps
                if (args.eval_every_steps and step % args.eval_every_steps == 0) or final_step:
                    eval_loss = evaluate(model, eval_loader)
                    if eval_loss < best_eval_loss:
                        best_eval_loss = eval_loss
                        save_best_checkpoint(model, tokenizer, optimizer, run_dir, step, epoch, len(train_loader), eval_loss)
                else:
                    eval_loss = ""
                writer.writerow({"step": step, "train_loss": train_loss, "eval_loss": eval_loss})
                f.flush()
                progress.update(1)
                progress.set_postfix(train_loss=train_loss, eval_loss=eval_loss)
                if args.save_every_steps and step % args.save_every_steps == 0:
                    save_checkpoint(model, tokenizer, optimizer, run_dir, step, epoch, len(train_loader))

        progress.close()

    model.save_pretrained(run_dir / "final")
    tokenizer.save_pretrained(run_dir / "final")
    if "batch" in locals():
        del batch
    if "loss" in locals():
        del loss
    del model, tokenizer, optimizer
    release_model_resources()
    return run_dir
