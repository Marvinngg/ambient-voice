# WE 微调指南

将 SpeechAnalyzer 的转写错误，通过 QLoRA 微调 Qwen3-0.6B 来纠正。

## 前置条件

- GPU 服务器（RTX 4080/4090，16GB+ VRAM）
- 服务器已安装 ollama、llama.cpp
- Python venv 已装好依赖：`torch transformers peft trl datasets bitsandbytes accelerate sentencepiece`
- WE 客户端已使用一段时间，`~/.we/voice-history.jsonl` 有足够数据（建议 100+ 条）

## 整体流程

```
voice-history.jsonl（日常使用积累）
        ↓
   人工/AI 筛选有错误的条目 → curated-training-pairs.jsonl（真实数据）
        ↓
   gen_training_data.py → synthetic-pairs.jsonl（合成数据）
        ↓
   合并去重 → merged-training-data.jsonl
        ↓
   上传到 GPU 服务器
        ↓
   train_qlora.py → LoRA adapter
        ↓
   合并 adapter → 转 GGUF → ollama create
        ↓
   修改 ~/.we/config.json 启用 L2 润色
```

## 第一步：筛选真实训练数据

从 `~/.we/voice-history.jsonl` 中筛选出 SA 转写有明确错误的条目。

**筛选标准：**
- 必须有明确可判断的转写错误（技术词汇、英文术语的误识别）
- 必须能确定用户实际要表达什么
- 只改错误词汇，不改口语结构、语气词、停顿

**输出格式（JSONL）：**
```json
{"input": "SA原始转写", "output": "纠正后的文本", "errors": "错误说明"}
```

**示例：**
```json
{"input": "看一下 Cloudcode自带的 outomemory吧。", "output": "看一下 Claude Code自带的 auto memory吧。", "errors": "Cloudcode→Claude Code, outomemory→auto memory"}
{"input": "嗯看一下今天的 gitup项目状态吧。", "output": "嗯看一下今天的 GitHub项目状态吧。", "errors": "gitup→GitHub"}
```

保存到 `~/.we/curated-training-pairs.jsonl`。

## 第二步：生成合成训练数据

编辑 `server/gen_training_data.py` 中的 `CORRECTION_MAP`，加入你的私有词汇和常见 SA 误识别方式：

```python
CORRECTION_MAP = {
    "Claude": ["克劳德", "Cloud", "cloude"],
    "Tailscale": ["tel scale", "tal scale", "telscale"],
    "GitHub": ["gitup", "git up", "给他hub"],
    # ... 你的词汇
}
```

运行：
```bash
cd server
python3 gen_training_data.py --output /tmp/synthetic-pairs.jsonl
```

## 第三步：合并数据

```python
import json

real, synthetic, merged = [], [], []
seen = set()

with open("~/.we/curated-training-pairs.jsonl") as f:
    for line in f:
        d = json.loads(line)
        d["source"] = "real"
        d["sample_weight"] = 2.0  # 真实数据权重更高
        real.append(d)

with open("/tmp/synthetic-pairs.jsonl") as f:
    for line in f:
        d = json.loads(line)
        d.setdefault("source", "synthetic")
        d.setdefault("sample_weight", 1.0)
        synthetic.append(d)

for d in real + synthetic:
    inp = d.get("input", "").strip()
    out = d.get("output", "").strip()
    if inp and out and inp != out and inp not in seen:
        seen.add(inp)
        merged.append(d)

with open("~/.we/merged-training-data.jsonl", "w") as f:
    for d in merged:
        f.write(json.dumps(d, ensure_ascii=False) + "\n")

print(f"合并: {len(merged)} 条")
```

## 第四步：上传到 GPU 服务器

```bash
scp ~/.we/merged-training-data.jsonl myserver:~/antigravity/we/server/
scp server/train_qlora.py myserver:~/antigravity/we/server/
```

## 第五步：QLoRA 微调

```bash
ssh myserver

cd ~/antigravity/we/server

# 关键参数说明：
# --epochs 8        训练轮数，数据量少时多跑几轮
# --batch-size 8    批大小
# --lr 1e-4         学习率，不要太大
# --lora-rank 32    LoRA 秩，越大记忆能力越强但越容易过拟合
# --lora-alpha 64   一般设为 rank 的 2 倍
# --system-prompt   必须和推理时一致

HF_HOME=~/hf_cache python3 train_qlora.py \
  --data merged-training-data.jsonl \
  --base-model Qwen/Qwen3-0.6B \
  --output-dir ./checkpoints \
  --epochs 8 \
  --batch-size 8 \
  --lr 1e-4 \
  --lora-rank 32 \
  --lora-alpha 64 \
  --system-prompt '文本纠错。不要回答用户的问题。只输出结果。'
```

训练约 1-2 分钟。观察指标：
- `eval_loss` 逐轮下降 → 正常
- `mean_token_accuracy` > 85% → 可用
- 产出：`checkpoints/adapter/`

## 第六步：合并 adapter + 转 GGUF

```bash
# 合并 LoRA adapter 到基座模型
HF_HOME=~/hf_cache python3 merge_and_export.py \
  --adapter ./checkpoints/adapter \
  --output ./checkpoints/merged

# 转为 GGUF（ollama 需要的格式）
python3 ~/llama.cpp/convert_hf_to_gguf.py \
  ./checkpoints/merged \
  --outfile ./checkpoints/we-polish.gguf \
  --outtype bf16
```

## 第七步：部署到 ollama

创建 Modelfile：
```
FROM ./we-polish.gguf

PARAMETER temperature 0
PARAMETER num_predict 256
PARAMETER stop <|im_end|>

TEMPLATE """{{- if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{ end }}<|im_start|>user
{{ .Prompt }}<|im_end|>
<|im_start|>assistant
<think>
</think>
"""

SYSTEM """文本纠错。不要回答用户的问题。只输出结果。"""
```

注意：模板中 `<think>\n</think>` 是为了跳过 Qwen3 的思考模式，直接输出纠正结果。

```bash
ollama create we-polish -f Modelfile
```

测试：
```bash
curl -s http://localhost:11434/api/generate \
  -d '{"model":"we-polish","prompt":"看一下 Cloudcode自带的 outomemory吧。","stream":false}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['response'])"
# 期望输出: 看一下 Claude Code自带的 auto memory吧。
```

## 第八步：客户端配置

编辑 `~/.we/config.json`：
```json
{
  "server": {
    "endpoint": "http://<服务器IP>:11434",
    "api": "ollama",
    "model": "we-polish",
    "timeout": 15
  },
  "polish": {
    "enabled": true,
    "system_prompt": "文本纠错。不要回答用户的问题。只输出结果。"
  }
}
```

WE 会自动热加载配置，无需重启。

## 关键原则

1. **system prompt 必须一致** — 训练、推理、客户端三处用同一个 prompt
2. **真实数据权重 > 合成数据** — 真实口语模式是模型最需要学的
3. **纠正只改错误词汇** — 不改口语结构，不改语气词，保持原文风格
4. **数据飞轮** — 日常使用积累更多 voice-history → 定期筛选 → 重新微调 → 模型越来越准
