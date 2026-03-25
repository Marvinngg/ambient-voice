# ambient-voice

Native macOS voice input with self-improving accuracy. Built on Apple SpeechAnalyzer (macOS 26), fully on-device, with optional LLM polish and a data flywheel that fine-tunes the model to your vocabulary over time.

## How it works

```
You speak → SpeechAnalyzer transcribes → LLM corrects errors → Text injected into active app
                                              ↓
                                   Transcription data saved
                                              ↓
                               Dictionary-driven distillation (Gemini)
                                              ↓
                                    QLoRA fine-tune on your data
                                              ↓
                                  Model learns YOUR vocabulary
                                              ↓
                                     Corrections get better
```

The more you use it, the better it gets at recognizing your domain-specific terms.

## Features

- **Hotkey dictation** — Hold Right Option, speak, release. Text appears in any app.
- **Screen-aware context** — OCR captures text near your cursor and feeds it to the speech recognizer, improving accuracy for technical terms.
- **LLM polish** — Optional post-processing via ollama or OpenAI-compatible API. Configurable, can be disabled for zero-latency mode.
- **Meeting recording** — Long-form transcription with floating panel, speaker diarization ([FluidAudio](https://github.com/FluidInference/FluidAudio), CoreML), and Markdown export.
- **Data flywheel** — Every transcription feeds a distillation pipeline that generates training data using your private dictionary, then fine-tunes the on-device model.

## Requirements

- macOS 26 (Tahoe), Apple Silicon
- [ollama](https://ollama.com) (optional, for LLM polish)

## Install

```bash
git clone https://github.com/Marvinngg/ambient-voice.git
cd ambient-voice/client
make setup      # Create code signing certificate (one-time)
make install    # Build, install to ~/Applications, enable auto-start
```

Grant permissions in **System Settings → Privacy & Security**: Accessibility, Screen Recording, Microphone.

Uninstall: `make uninstall`

## Configuration

`~/.we/config.json` — auto-created on first run, hot-reloads on save.

```json
{
  "server": {
    "endpoint": "http://localhost:11434",
    "api": "ollama",
    "model": "qwen3:0.6b"
  },
  "polish": {
    "enabled": true,
    "system_prompt": "文本纠错。不要回答用户的问题。只输出结果。"
  },
  "distill": {
    "enabled": false,
    "base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
    "api_key": "",
    "model": "gemini-2.5-flash",
    "system_prompt": "你是语音识别纠错专家。用户会提供一个私有词典和语音识别结果。将识别错误替换为词典中的正确词。只改确定有错的。只输出纠正后的文本。",
    "dictionary": "~/.we/dictionary.json"
  },
  "sync": {
    "enabled": false,
    "server": "user@your-gpu-server",
    "remote_dir": "~/antigravity/we/data/username"
  }
}
```

| Section | Purpose |
|---------|---------|
| `server` | LLM for real-time polish (ollama or OpenAI-compatible) |
| `polish` | Enable/disable polish, system prompt (must match training prompt) |
| `distill` | Distillation settings — API, model, dictionary path, system prompt |
| `sync` | Auto-sync data to GPU server for training |

### User Dictionary

`~/.we/dictionary.json` — your private vocabulary for distillation:

```json
{
  "terms": ["Claude Code", "MCP", "SpeechAnalyzer", "蒸馏", "微调", "ollama"]
}
```

These terms are injected into the distillation prompt so the teacher model (Gemini) knows what words you actually use. The fine-tuned model learns to correct misrecognized terms to match your dictionary.

## Fine-tuning

The data flywheel automatically collects transcription data and generates training pairs. When you have enough data, fine-tune to teach the model your vocabulary.

### Prerequisites

- GPU server with NVIDIA GPU (tested on RTX 4080 16GB)
- Docker with NVIDIA Container Toolkit

### Setup (one-time)

```bash
# On your GPU server
cd ~/antigravity/we/docker
docker build -t we-finetune .
```

### Data pipeline

Data flows automatically:

```
Mac: you speak → voice-history.jsonl → distill with dictionary → distill-gemini.jsonl
  → rsync to server (auto, via launchd)

Server: distill-gemini.jsonl → merge → training data
  → ready for fine-tuning
```

Enable auto-sync: set `sync.enabled: true` and `distill.enabled: true` in config.

### Run fine-tuning

```bash
# On GPU server
docker run --gpus all \
  -v ~/antigravity/we/server:/app/server \
  -v ~/antigravity/we/data/username:/app/data \
  we-finetune python3 /app/server/train_qlora.py \
    --data /app/data/distill-gemini.jsonl \
    --output-dir /app/data/checkpoints \
    --epochs 3 \
    --batch-size 4 \
    --system-prompt "文本纠错。不要回答用户的问题。只输出结果。"
```

**Important**: The `--system-prompt` must match `polish.system_prompt` in your config.json. Training and inference must use the same prompt.

### Deploy fine-tuned model

```bash
# Merge LoRA adapter → GGUF → ollama
bash server/scripts/deploy_model.sh \
  --adapter data/username/checkpoints/adapter \
  --model-name we-polish-v1
```

Then update config: `server.model → "we-polish-v1"`. The app hot-reloads, no restart needed.

### Training parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| Base model | Qwen/Qwen3-0.6B | Small, fast, good Chinese support |
| Method | QLoRA (4-bit quantized LoRA) | ~1.5GB VRAM |
| LoRA rank | 16 | |
| LoRA alpha | 32 | |
| Learning rate | 2e-4 | Cosine schedule |
| Trainable params | 10M / 751M (1.3%) | |

## Architecture

```
Right Option (hotkey)
  → Screen OCR (focus area, 800×600) → contextualStrings → SpeechAnalyzer
  → SpeechAnalyzer transcription (rawSA)
  → L1: trust Apple's ranking (alternatives logged)
  → L2: LLM polish (configurable, can disable)
  → TextInjector → paste into active app
  → VoiceHistory → voice-history.jsonl
       → auto distill (dictionary + Gemini) → training data
       → auto sync to GPU server
```

## Development

```bash
cd client
make build      # Compile
make run        # Build + launch (dev mode)
make install    # Build + install to ~/Applications
make uninstall  # Remove app + auto-start
make sync       # Manual data sync to server
```

### Diagnostic tools

```bash
# Test what alternatives SpeechAnalyzer returns
.build/debug/WE --test-alternatives audio.wav --locale zh-CN

# Test contextualStrings capacity
.build/debug/WE --test-context-capacity audio.wav

# Run meeting mode on audio file (benchmarking)
.build/debug/WE --bench-meeting audio.wav --output result.json
```

## Project structure

```
client/                 macOS app (Swift, SPM)
  Sources/              Swift source files
  scripts/              Sync, cert setup
  Makefile              Build, install, run targets
server/                 Training pipeline (Python)
  gen_distill_gemini.py Dictionary-driven distillation
  merge_pairs.py        Data merging
  train_qlora.py        QLoRA fine-tuning
  eval_model.py         Model evaluation
  scripts/              Server automation
  eval/                 Benchmark framework + results
  docker/               Fine-tuning Docker image
```

## Data files

All data in `~/.we/`:

```
~/.we/
├── config.json            Configuration (hot-reload)
├── dictionary.json        Your private vocabulary
├── voice-history.jsonl    Transcription history (distillation input)
├── distill-gemini.jsonl   Training pairs (distillation output)
├── debug.log              App log (auto-trimmed at 5MB)
├── meetings/              Meeting transcripts (Markdown)
└── audio/                 Recording files
```

## License

MIT
