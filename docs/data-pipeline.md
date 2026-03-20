# Data Pipeline: Distillation & Training

## 1. Overview

The WE data pipeline continuously collects voice transcription data from the macOS client, generates improved training labels through two parallel distillation routes (Whisper re-transcription and Gemini text correction), merges the results with optional human corrections, fine-tunes a Qwen3-0.6B model via QLoRA, evaluates the fine-tuned adapter, and deploys it as a GGUF model through ollama for on-device inference.

## 2. Pipeline Stages

### a. Data Collection (client-side, automatic)

Captures every voice session and writes a structured log for downstream distillation.

- **Script:** `client/Sources/VoiceHistory.swift` (writes via `JSONLWriter`), `client/Sources/CorrectionCapture.swift` + `client/Sources/CorrectionStore.swift` (optional human corrections)
- **Input:** Live audio from `AVCaptureSession`, transcription from `SpeechAnalyzer`, polish result from `PolishClient`
- **Output:**
  - `~/.we/voice-history.jsonl` -- one entry per voice session (always written)
  - `~/.we/audio/<timestamp>.wav` -- raw audio files (always saved)
  - `~/.we/corrections.jsonl` -- human correction entries (written when `correction_enabled` is true in `config.json`)
- **Dependencies:** None (pure Swift client)

### b. Route A: Whisper Re-transcription (server)

Re-transcribes the original audio with Whisper-large to produce higher-quality labels, paired against the on-device SpeechAnalyzer output.

- **Script:** `server/gen_distill_whisper.py`
- **Input:** `voice-history.jsonl` (reads `rawSA`, `audioPath`, `words` fields), audio files from `audio/` directory
- **Output:** Distillation pairs JSONL (e.g. `pairs_whisper.jsonl`), one entry per accepted pair
- **Dependencies:** `openai-whisper` (or `faster-whisper`)
- **Key parameters:**
  - `--model-size` (default: `large-v3`)
  - `--max-edit-ratio` (default: `0.4`) -- pairs exceeding this edit distance ratio are discarded
  - `--incremental` -- processes only entries added since last run (tracks offset in `.offset` file)

### c. Route B: Gemini Text Correction (client-side)

Sends the SpeechAnalyzer raw text and 0.6B polish output to Gemini (via OpenAI-compatible proxy) for expert correction.

- **Script:** `server/gen_distill_gemini.py`
- **Input:** `voice-history.jsonl` (reads `rawSA`, `polishedText`/`finalText`, `words` fields)
- **Output:** Distillation pairs JSONL (e.g. `distill-gemini.jsonl`), one entry per accepted pair
- **Dependencies:** None (uses `urllib.request` from stdlib)
- **Key parameters:**
  - `--base-url` (default: `http://127.0.0.1:8045`, Antigravity Tools local proxy)
  - `--api-key` (required)
  - `--model` (default: `gemini-2.5-flash`)
  - `--max-edit-ratio` (default: `0.3`)
  - `--rate-limit` (default: `0.5` seconds between calls)
  - `--incremental` -- same offset-tracking mechanism as Route A

### d. Merge & Conflict Resolution

Combines outputs from both routes and optional human corrections into a single training dataset, with deduplication and conflict handling.

- **Script:** `server/merge_pairs.py`
- **Input:**
  - `pairs_whisper.jsonl` (Route A output)
  - `pairs_gemini.jsonl` or `distill-gemini.jsonl` (Route B output)
  - `corrections.jsonl` (optional, human corrections -- highest priority)
- **Output:** `training_data.jsonl` -- merged, deduplicated training pairs
- **Dependencies:** None (stdlib only)
- **Merge strategy:**
  1. Human corrections take absolute priority (`source: "human"`, `sample_weight: 2.0`)
  2. If both routes agree on the output for the same input, merge into one entry with boosted weight (up to `2.0`)
  3. If routes conflict, both entries are kept with `"conflict": true` flag

### e. QLoRA Fine-tuning

Trains a LoRA adapter on the merged training data using SFTTrainer with chat-formatted samples.

- **Script:** `server/train_qlora.py`
- **Input:** `training_data.jsonl` (from merge step; reads `input`, `output`, `sample_weight`, `source` fields)
- **Output:** LoRA adapter checkpoint at `<output-dir>/adapter/` (adapter weights + tokenizer)
- **Dependencies:** `torch`, `transformers`, `peft`, `trl`, `datasets`, `bitsandbytes`
- **Key parameters:**
  - `--base-model` (default: `Qwen/Qwen3-0.6B`)
  - `--epochs` (default: `3`)
  - `--batch-size` (default: `8`, effective batch = 32 via gradient accumulation)
  - `--lr` (default: `2e-4`)
  - `--lora-rank` (default: `16`), `--lora-alpha` (default: `32`)
  - `--max-length` (default: `256`)
  - LoRA targets: `q_proj`, `k_proj`, `v_proj`, `o_proj`, `gate_proj`, `up_proj`, `down_proj`
- **Training details:**
  - Samples with `sample_weight >= 2.0` are duplicated in the training set
  - 90/10 train/eval split (shuffled)
  - Minimum 10 samples required to start training
  - Cosine LR schedule with 10% warmup, bf16 precision

### f. Evaluation

Measures model quality by comparing predicted outputs against ground-truth labels from the training data.

- **Script:** `server/eval_model.py`
- **Input:** `training_data.jsonl` (ground truth), model adapter or merged model path
- **Output:** `eval_results.jsonl` -- per-sample predictions with category labels; console summary table
- **Dependencies:** `torch`, `transformers`, `peft`
- **Metrics (per source and overall):**
  - `fix_rate` -- model improved the input (predicted CER < original CER vs ground truth)
  - `break_rate` -- model made the input worse (predicted CER > original CER)
  - `identity_rate` -- model output is identical to input (no change)
  - `avg_cer` -- average Character Error Rate against ground truth

### g. Deployment (GGUF + ollama)

Merges the LoRA adapter back into the base model, converts to GGUF format, quantizes, and registers with ollama.

- **Script:** `server/scripts/deploy_model.sh`
- **Input:** LoRA adapter directory, base model name
- **Output:** Quantized GGUF file (`<model-name>-Q4_K_M.gguf`), ollama model registration
- **Dependencies:** `transformers`, `peft`, `torch` (for merge); `llama.cpp` (for GGUF conversion + quantization); `ollama` CLI
- **Steps:**
  1. Merge LoRA adapter into base model (Python, in-script)
  2. Convert merged HF model to GGUF via `llama.cpp/convert_hf_to_gguf.py`
  3. Quantize to Q4_K_M (configurable via `--quant`) using `llama-quantize`
  4. Generate `Modelfile` with system prompt and create ollama model via `ollama create`

## 3. Automation

### Client-side: launchd file watcher

A launchd agent watches `~/.we/voice-history.jsonl` for changes and triggers the sync script.

- **Plist:** `client/scripts/com.antigravity.we.sync.plist`
  - `WatchPaths`: `~/.we/voice-history.jsonl`
  - `ThrottleInterval`: 30 seconds (debounce)
- **Script:** `client/scripts/sync-to-server.sh`
  - Runs Route B Gemini distillation incrementally on the client (reads `distill` config from `~/.we/config.json`)
  - Syncs `voice-history.jsonl`, `corrections.jsonl`, `distill-gemini.jsonl`, and `audio/` to the server via rsync
  - Sync target configured in `config.json` under `sync.server` and `sync.remote_dir`

### Server-side: cron every 10 minutes

A cron job runs Route A Whisper distillation incrementally on the GPU server.

- **Script:** `server/scripts/run_whisper_distill.sh`
  - Reads `~/we-data/voice-history.jsonl` (synced from client)
  - Outputs to `~/we-data/distill-whisper.jsonl` (incremental append)
  - Logs to `~/we-data/distill.log`
  - Installed by `server/scripts/deploy_server.sh`: `*/10 * * * * bash ~/antigravity/we/server/scripts/run_whisper_distill.sh`

### Full pipeline: manual trigger

- **Script:** `server/scripts/run_pipeline.sh`
  - Runs all stages end-to-end: distill (A+B in parallel) -> merge -> train -> eval -> deploy
  - Usage: `./run_pipeline.sh --gemini-key <key> [--skip-distill] [--skip-train] [--deploy]`
  - Creates a timestamped work directory under `server/workdir/`
  - Data directory default: `~/we-data`

## 4. Data Formats

### voice-history.jsonl entry

Written by the client after each voice session.

```jsonl
{
  "timestamp": "2026-03-19T14:30:00Z",
  "rawSA": "哈喽我再试一下能不能转",
  "l1Text": "哈喽我再试一下能不能转",
  "polishedText": "哈喽，我再试一下能不能转。",
  "finalText": "哈喽，我再试一下能不能转。",
  "words": [
    {"text": "哈喽", "confidence": 0.92, "alternatives": ["哈楼"], "startTime": 0.0, "duration": 0.5},
    {"text": "我", "confidence": 0.98, "alternatives": [], "startTime": 0.5, "duration": 0.2}
  ],
  "audioPath": "~/.we/audio/20260319-143000.wav",
  "appBundleID": "com.apple.dt.Xcode",
  "appName": "Xcode"
}
```

### Distill output entry (Route A -- Whisper)

```jsonl
{
  "input": "哈喽我再试一下能不能转",
  "output": "哈喽，我再试一下能不能转。",
  "source": "whisper",
  "edit_ratio": 0.0833,
  "avg_confidence": 0.95,
  "audio_path": "/Users/user/.we/audio/20260319-143000.wav",
  "timestamp": "2026-03-19T14:30:00Z"
}
```

### Distill output entry (Route B -- Gemini)

```jsonl
{
  "input": "哈喽我再试一下能不能转",
  "output": "哈喽，我再试一下能不能转。",
  "source": "gemini",
  "polished_0.6b": "哈喽我再试一下能不能转。",
  "edit_ratio": 0.0833,
  "avg_confidence": 0.95,
  "timestamp": "2026-03-19T14:30:00Z"
}
```

### training_data.jsonl entry (after merge)

```jsonl
{
  "input": "哈喽我再试一下能不能转",
  "output": "哈喽，我再试一下能不能转。",
  "source": "whisper",
  "edit_ratio": 0.0833,
  "avg_confidence": 0.95,
  "sample_weight": 2.0,
  "conflict": false
}
```

When sourced from human corrections:

```jsonl
{
  "input": "哈喽我再试一下能不能转",
  "output": "哈喽，我再试一下能不能转。",
  "source": "human",
  "quality": 0.91,
  "sample_weight": 2.0
}
```

### corrections.jsonl entry (human corrections)

Written by `CorrectionCapture` on the client when enabled.

```jsonl
{
  "timestamp": "2026-03-19T14:31:00Z",
  "rawText": "哈喽我再试一下能不能转",
  "insertedText": "哈喽我再试一下能不能转。",
  "userFinalText": "哈喽，我再试一下能不能转。",
  "diffs": [{"original": "哈喽我再试一下能不能转。", "corrected": "哈喽，我再试一下能不能转。"}],
  "quality": 0.91,
  "source": "human",
  "appBundleID": "com.apple.dt.Xcode"
}
```

## 5. Data Flow Diagram

```
 CLIENT (macOS)                              SERVER (4090 GPU)
 ==============                              ==================

 Microphone
     |
     v
 AVCaptureSession
     |
     v
 SpeechAnalyzer -----> rawSA
     |                   |
     v                   v
 AlternativeSwap      VoiceHistory.save()
     |                   |
     v                   +---> ~/.we/voice-history.jsonl
 PolishClient                  ~/.we/audio/*.wav
 (ollama 0.6B)                       |
     |                               |  launchd watches
     v                               |  voice-history.jsonl
 TextInjector                        v
     |                 +-----> sync-to-server.sh
     v                 |             |
 CorrectionCapture     |     +-------+-------+
 (if enabled)          |     |               |
     |                 |     v               v
     v                 | Route B:         rsync to
 ~/.we/corrections     | Gemini distill   ~/we-data/
     .jsonl            | (incremental)        |
                       |     |                |
                       |     v                v
                       | distill-         voice-history.jsonl
                       | gemini.jsonl     audio/
                       |     |            corrections.jsonl
                       |     |                |
                       +-----|--- rsync ----->|
                             |                |
                             |                v
                             |          Route A: Whisper distill
                             |          (cron, every 10 min,
                             |           incremental)
                             |                |
                             |                v
                             |          distill-whisper.jsonl
                             |                |
                             v                v
                       +---------------------------+
                       |     merge_pairs.py        |
                       |  (human > agree > conflict)|
                       +---------------------------+
                                    |
                                    v
                            training_data.jsonl
                                    |
                                    v
                       +---------------------------+
                       |    train_qlora.py          |
                       |  Qwen3-0.6B + LoRA r=16   |
                       +---------------------------+
                                    |
                                    v
                              LoRA adapter
                                    |
                          +---------+---------+
                          |                   |
                          v                   v
                    eval_model.py       deploy_model.sh
                    (fix/break/CER)     merge -> GGUF -> Q4_K_M
                                              |
                                              v
                                        ollama create
                                        "we-polish"
                                              |
                                              v
                                    Client PolishClient
                                    connects to ollama
```
