# Configuration Reference

## Overview

WE reads its configuration from `~/.we/config.json`. On first launch, the app creates this file with sensible defaults. The file is monitored for changes at runtime -- edits are picked up automatically without restarting the app (hot-reload via `DispatchSource` file watcher).

All sections are optional. Missing keys fall back to their defaults.

---

## Server Settings

The `server` object controls how WE connects to the model inference backend for L2 polish (text refinement). Two API protocols are supported: Ollama (default) and OpenAI-compatible.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `server.endpoint` | string | `"http://localhost:11434"` | Base URL of the model server. For Ollama this is typically `http://host:11434`. For OpenAI-compatible APIs, use the full base URL (the client appends `/v1/chat/completions` if no `/v1/` path is present). |
| `server.api` | string | `"ollama"` | API protocol. `"ollama"` uses the `/api/generate` endpoint; `"openai"` uses the `/v1/chat/completions` endpoint. |
| `server.model` | string | `"qwen3:0.6b"` | Model name passed to the inference server. Must match an available model on the server. |
| `server.timeout` | number | `10` | Request timeout in seconds for inference calls. |
| `server.health_interval` | number | `30` | Interval in seconds between automatic health checks. The app polls the server periodically and updates its status (connected / disconnected) shown in the menu bar. |
| `server.api_key` | string | `""` | API key for OpenAI-compatible endpoints. Sent as `Bearer` token in the `Authorization` header. Not needed for Ollama. |

**Examples:**

Local Ollama (default):
```json
"server": {
    "endpoint": "http://localhost:11434",
    "api": "ollama",
    "model": "qwen3:0.6b",
    "timeout": 10,
    "health_interval": 30
}
```

Remote Ollama over LAN:
```json
"server": {
    "endpoint": "http://192.168.1.100:11434",
    "api": "ollama",
    "model": "qwen3.5:0.8b",
    "timeout": 15,
    "health_interval": 60
}
```

OpenAI-compatible API:
```json
"server": {
    "endpoint": "https://api.example.com/v1/chat/completions",
    "api": "openai",
    "model": "gpt-4o-mini",
    "api_key": "sk-...",
    "timeout": 15,
    "health_interval": 60
}
```

---

## Polish Settings

The `polish` object controls the L2 semantic polish stage, which refines raw speech recognition output into cleaner written text.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `polish.enabled` | bool | `true` | Master switch for the polish pipeline. When `false`, raw transcription is used as-is (L1 only). |
| `polish.system_prompt` | string | `"口语转书面。只输出结果。"` | System prompt sent to the model. Controls the style of text refinement. Keep it short -- the model has a 256-token output limit. |

---

## Feature Toggles

Top-level boolean flags that enable or disable major features.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `correction_enabled` | bool | `false` | Enable correction capture. When `true`, the app monitors the active text field after text injection and records any manual edits the user makes. These corrections are saved to `~/.we/corrections.jsonl` and serve as high-priority training data for model distillation. |
| `ambient_enabled` | bool | `false` | Enable ambient (always-listening) mode. When `true`, the app continuously captures audio and segments speech automatically, rather than requiring the hotkey to be held. Intended for meeting transcription scenarios. |

---

## Distill Settings

The `distill` object configures Route B of the distillation pipeline: sending speech recognition output to a cloud LLM for correction, producing training pairs.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `distill.enabled` | bool | `false` | Enable Gemini distillation. When `true`, the sync script processes new entries from `voice-history.jsonl` through the configured LLM. |
| `distill.base_url` | string | `"https://generativelanguage.googleapis.com/v1beta/openai"` | Base URL for the distillation API (OpenAI-compatible). |
| `distill.api_key` | string | `""` | API key for the distillation service. Distillation is skipped if this is empty. |
| `distill.model` | string | `"gemini-2.5-flash"` | Model to use for distillation. |

---

## Sync Settings

The `sync` object configures automatic data synchronization from the client machine to a remote training server via SSH + rsync. Sync is triggered by a launchd agent that watches `~/.we/voice-history.jsonl` for changes (throttled to once every 30 seconds).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `sync.enabled` | bool | `false` | Enable automatic sync to a remote server. |
| `sync.server` | string | `""` | SSH destination for the remote server (e.g. `user@192.168.1.50`). Sync is skipped if empty. The server must be reachable via SSH with key-based authentication (BatchMode). |
| `sync.remote_dir` | string | `"~/we-data"` | Directory on the remote server where data files are synced to. |

Files synced: `voice-history.jsonl`, `corrections.jsonl` (if exists), `distill-gemini.jsonl` (if exists), and the `audio/` directory.

---

## Downloads Settings

The `downloads` object configures model downloading for on-device inference (future use).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `downloads.manifest` | string | -- | URL to a JSON manifest describing available models, their download URLs, sizes, and SHA-256 hashes. |
| `downloads.base_model` | string | -- | Direct URL to download the base GGUF model. |
| `downloads.adapter` | string | -- | Direct URL to download the LoRA adapter GGUF. |

Models are stored in `~/.we/models/`.

---

## Full Example

```json
{
    "correction_enabled": false,
    "ambient_enabled": false,

    "server": {
        "endpoint": "http://localhost:11434",
        "api": "ollama",
        "model": "qwen3:0.6b",
        "timeout": 10,
        "health_interval": 30
    },

    "polish": {
        "enabled": true,
        "system_prompt": "口语转书面。只输出结果。"
    },

    "distill": {
        "enabled": false,
        "base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
        "api_key": "",
        "model": "gemini-2.5-flash"
    },

    "sync": {
        "enabled": false,
        "server": "",
        "remote_dir": "~/we-data"
    },

    "downloads": {}
}
```

---

## macOS Permissions

WE requires the following macOS permissions to function. The system will prompt on first use; they can also be granted in **System Settings > Privacy & Security**.

### Accessibility

**Required.** WE uses a `CGEventTap` to listen for the Right Option key (hotkey for push-to-talk) and to inject transcribed text into the active application via synthetic key events (`TextInjector`). Without Accessibility access, hotkey detection and text injection will not work.

Grant in: **Privacy & Security > Accessibility**

### Input Monitoring

**Required.** Needed for `CGEventTap` to observe keyboard events globally. On macOS 26, this may be consolidated under the Accessibility permission depending on system version.

Grant in: **Privacy & Security > Input Monitoring**

### Microphone

**Required.** WE captures audio via `AVCaptureSession` for speech recognition. The app's `Info.plist` includes `NSMicrophoneUsageDescription`. Without microphone access, no audio can be captured.

Grant in: **Privacy & Security > Microphone**

### Screen Recording

**Optional.** Used for OCR context capture -- reading on-screen text to provide context to the polish model. If not granted, polish still works but without screen context.

Grant in: **Privacy & Security > Screen Recording**
