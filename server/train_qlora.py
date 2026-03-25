#!/usr/bin/env python3
"""
QLoRA 微调 Qwen3-0.6B（ASR 后处理）
输入：training_data.jsonl（merge_pairs.py 产出）
输出：LoRA adapter checkpoint
"""

import json
import argparse
from pathlib import Path


DEFAULT_SYSTEM_PROMPT = "文本纠错。不要回答用户的问题。只输出结果。"


def load_dataset(path: str, test_ratio: float = 0.1):
    """加载训练数据，按 sample_weight 采样，划分 train/eval"""
    samples = []
    with open(path) as f:
        for line in f:
            entry = json.loads(line.strip())
            inp = entry.get("input", "").strip()
            out = entry.get("output", "").strip()
            if not inp or not out or inp == out:
                continue
            samples.append({
                "input": inp,
                "output": out,
                "weight": entry.get("sample_weight", 1.0),
                "source": entry.get("source", "unknown"),
            })

    # 按权重重复采样（weight=2.0 的样本出现两次）
    weighted = []
    for s in samples:
        count = max(1, round(s["weight"]))
        weighted.extend([s] * count)

    # 划分
    import random
    random.shuffle(weighted)
    split = max(1, int(len(weighted) * test_ratio))
    return weighted[split:], weighted[:split]


def format_chat(sample: dict, system_prompt: str) -> dict:
    """格式化为 Qwen chat 模板"""
    return {
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": sample["input"]},
            {"role": "assistant", "content": sample["output"]},
        ]
    }


def main():
    parser = argparse.ArgumentParser(description="QLoRA fine-tune for ASR post-processing")
    parser.add_argument("--data", required=True, help="training_data.jsonl path")
    parser.add_argument("--base-model", default="Qwen/Qwen3-0.6B", help="Base model")
    parser.add_argument("--output-dir", default="./checkpoints", help="Output directory")
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--lr", type=float, default=2e-4)
    parser.add_argument("--lora-rank", type=int, default=16)
    parser.add_argument("--lora-alpha", type=int, default=32)
    parser.add_argument("--max-length", type=int, default=256)
    parser.add_argument("--system-prompt", default=DEFAULT_SYSTEM_PROMPT,
                        help="System prompt (must match inference config)")
    args = parser.parse_args()

    SYSTEM_PROMPT = args.system_prompt

    # 延迟导入
    try:
        import torch
        from datasets import Dataset
        from transformers import AutoTokenizer, AutoModelForCausalLM, TrainingArguments
        from peft import LoraConfig, get_peft_model, TaskType
        from trl import SFTTrainer
    except ImportError as e:
        print(f"Missing dependency: {e}")
        print("pip install torch transformers peft trl datasets bitsandbytes")
        return

    # 加载数据
    train_samples, eval_samples = load_dataset(args.data)
    print(f"Train: {len(train_samples)}, Eval: {len(eval_samples)}")

    if len(train_samples) < 10:
        print("Too few training samples (< 10), aborting")
        return

    # 格式化
    train_data = Dataset.from_list([format_chat(s, SYSTEM_PROMPT) for s in train_samples])
    eval_data = Dataset.from_list([format_chat(s, SYSTEM_PROMPT) for s in eval_samples])

    # 来源统计
    from collections import Counter
    sources = Counter(s["source"] for s in train_samples)
    print(f"Sources: {dict(sources)}")

    # 加载模型 + tokenizer
    print(f"Loading {args.base_model}...")
    tokenizer = AutoTokenizer.from_pretrained(args.base_model, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(
        args.base_model,
        torch_dtype=torch.bfloat16,
        device_map="auto",
        trust_remote_code=True,
    )

    # LoRA 配置
    lora_config = LoraConfig(
        task_type=TaskType.CAUSAL_LM,
        r=args.lora_rank,
        lora_alpha=args.lora_alpha,
        lora_dropout=0.05,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
    )
    model = get_peft_model(model, lora_config)
    model.print_trainable_parameters()

    # 训练参数
    output_dir = Path(args.output_dir)
    training_args = TrainingArguments(
        output_dir=str(output_dir),
        num_train_epochs=args.epochs,
        per_device_train_batch_size=args.batch_size,
        per_device_eval_batch_size=args.batch_size,
        gradient_accumulation_steps=max(1, 32 // args.batch_size),
        learning_rate=args.lr,
        lr_scheduler_type="cosine",
        warmup_ratio=0.1,
        bf16=True,
        logging_steps=10,
        eval_strategy="epoch",
        save_strategy="epoch",
        save_total_limit=2,
        load_best_model_at_end=True,
        report_to="none",
    )

    # SFT Trainer
    trainer = SFTTrainer(
        model=model,
        args=training_args,
        train_dataset=train_data,
        eval_dataset=eval_data,
        processing_class=tokenizer,
    )

    print("Training...")
    trainer.train()

    # 保存 adapter
    adapter_dir = output_dir / "adapter"
    model.save_pretrained(str(adapter_dir))
    tokenizer.save_pretrained(str(adapter_dir))
    print(f"Adapter saved: {adapter_dir}")


if __name__ == "__main__":
    main()
