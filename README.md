# WE Lite

Stripped-down macOS voice input. Speak into any app, fully on-device, no server required.

Built on Apple SpeechAnalyzer (macOS 26). No LLM polish, no fine-tuning pipeline — just pure transcription.

## Install

```bash
cd client
make setup      # Code signing certificate (one-time)
make install    # Build + install + auto-start
```

Grant: **System Settings > Privacy & Security** > Accessibility, Screen Recording, Microphone.

## Usage

**Dictation** — Press `Right Option`, speak, press again. Text is pasted into the focused app.

**Meeting** — Menu bar `WE` > Start Meeting. Floating transcript, speaker diarization, Markdown export to `~/.we-lite/meetings/`.

## Architecture

```
Press Right Option
  -> Screen OCR (focus area) -> contextualStrings -> SpeechAnalyzer
  -> Transcription (rawSA)
  -> Inject into active app
  -> voice-history.jsonl saved
```

## Config

`~/.we-lite/config.json` — hot-reloads on save.

```json
{
  "ambient_enabled": false
}
```

## Development

```bash
cd client
make build          # Compile
make run            # Dev mode
make install        # Install to ~/Applications
make uninstall      # Remove
```

## Data

All data stored in `~/.we-lite/`:
- `voice-history.jsonl` — transcription history
- `audio/` — recorded audio files
- `config.json` — runtime config
- `debug.log` — application log

## License

MIT
