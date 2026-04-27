#!/bin/bash
set -euo pipefail

# 部署微调模型：merge LoRA → GGUF 量化 → ollama create
# 用法: ./deploy_model.sh --adapter <path> [--base-model Qwen/Qwen3-0.6B] [--model-name we-polish]

ADAPTER_PATH=""
BASE_MODEL="Qwen/Qwen3-0.6B"
MODEL_NAME="we-polish"
QUANT="Q4_K_M"
WORK_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --adapter) ADAPTER_PATH="$2"; shift 2 ;;
        --base-model) BASE_MODEL="$2"; shift 2 ;;
        --model-name) MODEL_NAME="$2"; shift 2 ;;
        --quant) QUANT="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [ -z "$ADAPTER_PATH" ]; then
    echo "Error: --adapter <path> required"
    exit 1
fi

WORK_DIR="$(dirname "$ADAPTER_PATH")/deploy"
mkdir -p "$WORK_DIR"

echo "=== Step 1: Merge LoRA adapter ==="
python3 - <<'PYTHON' "$BASE_MODEL" "$ADAPTER_PATH" "$WORK_DIR/merged"
import sys
from transformers import AutoTokenizer, AutoModelForCausalLM
from peft import PeftModel
import torch

base_model, adapter_path, output_path = sys.argv[1], sys.argv[2], sys.argv[3]
print(f"Loading base: {base_model}")
model = AutoModelForCausalLM.from_pretrained(base_model, torch_dtype=torch.bfloat16, trust_remote_code=True)
print(f"Loading adapter: {adapter_path}")
model = PeftModel.from_pretrained(model, adapter_path)
model = model.merge_and_unload()
print(f"Saving merged model: {output_path}")
model.save_pretrained(output_path)
AutoTokenizer.from_pretrained(base_model, trust_remote_code=True).save_pretrained(output_path)
print("Done")
PYTHON

echo ""
echo "=== Step 2: Convert to GGUF ==="
# 需要 llama.cpp 的 convert 脚本
LLAMA_CPP="${LLAMA_CPP_DIR:-$HOME/llama.cpp}"
if [ ! -f "$LLAMA_CPP/convert_hf_to_gguf.py" ]; then
    echo "llama.cpp not found at $LLAMA_CPP"
    echo "Set LLAMA_CPP_DIR or clone: git clone https://github.com/ggerganov/llama.cpp ~/llama.cpp"
    exit 1
fi

python3 "$LLAMA_CPP/convert_hf_to_gguf.py" "$WORK_DIR/merged" \
    --outfile "$WORK_DIR/${MODEL_NAME}-f16.gguf" \
    --outtype f16

echo ""
echo "=== Step 3: Quantize ==="
if [ ! -f "$LLAMA_CPP/build/bin/llama-quantize" ]; then
    echo "llama-quantize not found, building..."
    (cd "$LLAMA_CPP" && cmake -B build -DGGML_CUDA=ON && cmake --build build --target llama-quantize -j)
fi

"$LLAMA_CPP/build/bin/llama-quantize" \
    "$WORK_DIR/${MODEL_NAME}-f16.gguf" \
    "$WORK_DIR/${MODEL_NAME}-${QUANT}.gguf" \
    "$QUANT"

echo ""
echo "=== Step 4: Create ollama model ==="
GGUF_PATH="$WORK_DIR/${MODEL_NAME}-${QUANT}.gguf"

cat > "$WORK_DIR/Modelfile" <<EOF
FROM $GGUF_PATH

SYSTEM "你是语音识别纠错助手。格式要求：修正语音识别错误，只输出修正后的最终文本，不要回答问题，不要改变原意，去掉语气词，修正标点符号。"

PARAMETER temperature 0
PARAMETER num_predict 256
EOF

ollama create "$MODEL_NAME" -f "$WORK_DIR/Modelfile"

echo ""
echo "=== Done ==="
echo "Model: $MODEL_NAME"
echo "GGUF:  $GGUF_PATH"
echo ""
echo "Test:  ollama run $MODEL_NAME '哈喽我再试一下能不能转'"
echo "Update client config: model -> $MODEL_NAME"
