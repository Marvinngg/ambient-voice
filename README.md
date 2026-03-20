# ambient-voice

Native macOS voice input and meeting transcription. Runs fully on-device using Apple SpeechAnalyzer (macOS 26), with optional LLM polish and speaker diarization.

<!-- TODO: add demo GIF here -->

## Features

- **Hotkey dictation** — Press Right Option, speak, press again. Text is transcribed and pasted into the active app.
- **Screen-aware transcription** — OCR captures on-screen text and feeds it to the speech recognizer as context, improving accuracy for technical terms and proper nouns.
- **LLM polish** — Optional post-processing via ollama or OpenAI-compatible API to clean up spoken language into written form.
- **Meeting recording** — Long-form continuous transcription with a floating transcript panel and automatic Markdown export.
- **Speaker diarization** — Identifies who said what using [FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML, post-recording batch processing).
- **Self-improving** — Collects transcription data for [distillation and fine-tuning](docs/data-pipeline.md), creating a feedback loop that improves the on-device model over time.

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

On first launch, grant permissions in **System Settings → Privacy & Security**:
Accessibility, Screen Recording, Microphone.

## Usage

**Dictation** — Press `Right Option` to start recording. Press again to stop. Transcribed text is pasted into the focused app.

**Meeting** — Click the menu bar icon `WE` → Start Meeting. A floating transcript panel appears. Click Stop Meeting when done. Results are exported to `~/.we/meetings/`.

**Menu bar** — Click `WE` in the menu bar to access:
- Server status and model info
- Start/stop meeting recording
- Toggle correction capture
- Edit config, open data directory, view logs

## Configuration

Config file: `~/.we/config.json` — auto-created on first run, hot-reloads on save.

```json
{
  "server": {
    "endpoint": "http://localhost:11434",
    "model": "qwen3:0.6b"
  },
  "correction_enabled": false,
  "ambient_enabled": false
}
```

See [docs/configuration.md](docs/configuration.md) for all options.

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](docs/architecture.md) | System design, module overview, audio pipeline |
| [Data Pipeline](docs/data-pipeline.md) | Distillation → training → deployment workflow |
| [Evaluation](docs/evaluation.md) | Benchmark methodology and results |
| [Configuration](docs/configuration.md) | All config options with defaults |

## Development

```bash
cd client
make build      # Compile
make run        # Build + launch (dev mode)
make install    # Build + install to ~/Applications
make uninstall  # Remove app + auto-start
make check-log  # View recent logs
make check-data # Inspect data files
```

## Project Structure

```
client/                 macOS app (Swift, SPM)
  Sources/              30 Swift source files
  scripts/              Sync, cert setup
  Makefile              Build, install, run targets
server/                 Training pipeline (Python)
  gen_distill_*.py      Distillation scripts (Whisper + Gemini)
  merge_pairs.py        Data merging with conflict resolution
  train_qlora.py        QLoRA fine-tuning
  eval_model.py         Model evaluation
  eval/                 Benchmark framework + results
  scripts/              Automation (cron, deploy, pipeline)
docs/                   Documentation
```

## License

MIT
