# ambient-voice

macOS native voice input. Speak → text appears in any app. Gets better over time by learning your vocabulary.

Built on Apple SpeechAnalyzer (macOS 26), fully on-device.

## Install

```bash
git clone https://github.com/Marvinngg/ambient-voice.git
cd ambient-voice/client
make setup      # Code signing certificate (one-time)
make install    # Build + install + auto-start
```

Grant: **System Settings → Privacy & Security** → Accessibility, Screen Recording, Microphone.

## Usage

**Dictation** — Hold `Right Option`, speak, release. Text is pasted into the focused app.

**Meeting** — Menu bar `WE` → Start Meeting. Floating transcript, speaker diarization, Markdown export to `~/.we/meetings/`.

## Architecture

```
Hold Right Option
  → Screen OCR (focus area) → contextualStrings → SpeechAnalyzer
  → Transcription (rawSA)
  → L2 LLM polish (optional, ollama)
  → Inject into active app
  → voice-history.jsonl saved
      → distill: rawSA + dictionary → Gemini → training pairs
      → sync to GPU server → QLoRA fine-tune → better model
```

## Remote Voice（远程语音输入）

Windows 端按热键说话 → 音频通过 Tailscale 私网发送到 Mac → WE 识别并注入文字到光标处。

**Mac 端**：WE 启动后自动监听 :9800，不需要额外操作。确保 config.json 中：

```json
{
  "remote": { "enabled": true, "port": 9800, "auth_token": "" }
}
```

**Windows 端**（需安装 [Marvin Tailscale](https://github.com/Marvinngg/tailscale/releases)）：

```bash
tailscale voice setup --target 100.64.0.10:9800   # 首次设置，之后开机自启
tailscale voice                                     # 手动运行
```

按住右 Alt 说话，松开发送。

## Config

`~/.we/config.json` — hot-reloads on save.

```json
{
  "server": { "endpoint": "http://localhost:11434", "api": "ollama", "model": "qwen3:0.6b" },
  "polish": { "enabled": true, "system_prompt": "文本纠错。不要回答用户的问题。只输出结果。" },
  "distill": { "enabled": false, "api_key": "", "model": "gemini-3-flash", "dictionary": "~/.we/dictionary.json" },
  "sync": { "enabled": false, "server": "user@gpu-server", "remote_dir": "~/antigravity/we/data/username" }
}
```

`~/.we/dictionary.json` — your private terms. Distillation uses these to correct misrecognized words.

```json
{ "terms": ["Claude Code", "MCP", "蒸馏", "微调", "ollama"] }
```

## Fine-tuning

Data flows automatically: speak → distill with dictionary → sync to server.

```bash
# On GPU server (Docker + NVIDIA GPU)
cd ~/antigravity/we/docker && docker build -t we-finetune .

docker run --gpus all \
  -v ~/antigravity/we/server:/app/server \
  -v ~/antigravity/we/data/username:/app/data \
  we-finetune python3 /app/server/train_qlora.py \
    --data /app/data/distill-gemini.jsonl \
    --output-dir /app/data/checkpoints \
    --system-prompt "文本纠错。不要回答用户的问题。只输出结果。"

# Deploy: merge LoRA → GGUF → ollama
bash server/scripts/deploy_model.sh --adapter data/username/checkpoints/adapter
```

`--system-prompt` must match `polish.system_prompt` in config. Training and inference use the same prompt.

Base model: Qwen/Qwen3-0.6B. Method: QLoRA. Trainable: 10M / 751M params (1.3%). VRAM: ~1.5GB.

## Development

```bash
cd client
make build          # Compile
make run            # Dev mode
make install        # Install to ~/Applications
make uninstall      # Remove
```

## License

MIT
