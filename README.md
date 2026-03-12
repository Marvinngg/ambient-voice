# ambient-voice

**你的声音，直接变成文字。越用越准。**

不需要打开任何 App，不需要切换输入法。按住说话，松开注入——文字出现在你正在使用的任何应用里。

- **原生** — 基于 Apple SpeechAnalyzer (macOS 26)，不依赖 Whisper、不依赖云端 ASR。系统升级 = 能力升级
- **快** — 全链路端侧处理，毫秒级响应。说完即得，不等网络
- **本地** — 你的声音不离开你的设备。转写、OCR、润色均可离线完成
- **越用越好** — 每次使用自动积累数据，通过蒸馏管线持续改进端侧模型

## Demo

> *(GIF/视频占位)*

## Features

**语音听写**
- 按住右 Option 说话，松开自动注入当前应用
- 实时流式转写，说完即得
- 屏幕上下文感知——系统知道你在回复什么，同音词选择更准
- 可选 LLM 润色（口语 → 书面语）

**会议录音**
- 长时间连续录音 + 实时转录悬浮窗
- 录完自动说话人分离（FluidAudio, CoreML 端侧）
- 自动导出带时间戳 + 说话人标签的 Markdown

**数据飞轮**
- 每次转写自动记录到 `voice-history.jsonl`
- 用户纠错（可选）作为高优训练信号
- 双路线蒸馏，自动生成训练数据：
  - 路线 A：原始音频 → Whisper large 重新转写
  - 路线 B：SA 原文 + 小模型输出 → Gemini 2.5 Flash 纠正
- 蒸馏产出回灌端侧模型，形成闭环

## Requirements

- macOS 26 (Tahoe) 或更高
- Apple Silicon
- ollama 或任意 OpenAI 兼容 API（可选，用于润色）
- Gemini API key（可选，用于蒸馏）

## Install

```bash
git clone https://github.com/Marvinngg/ambient-voice.git
cd ambient-voice/client
make setup    # 首次：创建代码签名证书
make install  # 编译 + 安装到 ~/Applications + 开机自启
```

首次运行需授权：**系统设置 → 隐私与安全性** → 辅助功能 + 屏幕录制 + 麦克风

卸载：`make uninstall`

## Usage

| 操作 | 方式 |
|------|------|
| 听写 | 按住右 Option 说话，松开注入 |
| 开始会议 | 菜单栏 → 开始会议录音 (⌘M) |
| 结束会议 | 菜单栏 → 结束会议 |
| 编辑配置 | 菜单栏 → 编辑配置文件 (⌘,) |
| 手动同步 | `cd client && make sync` |

## Config

`~/.we/config.json`，修改后自动生效，无需重启。首次运行自动创建。

润色和蒸馏是两件不同的事，各自有独立的 API 配置：
- **润色** (`server` + `polish`)：每次说话实时调用，要求低延迟，适合本地小模型
- **蒸馏** (`distill`)：后台批量运行，用大模型纠正转写输出，产出训练数据

```json
{
  "server": {
    "endpoint": "http://localhost:11434",
    "api": "ollama",
    "model": "qwen3:0.6b"
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
    "server": "user@your-gpu-server",
    "remote_dir": "~/we-data"
  }
}
```

### server + polish — 实时润色

每次语音输入后实时调用，将口语转为书面语再注入。要求低延迟，推荐本地 ollama。

| 字段 | 说明 |
|------|------|
| `server.api` | `ollama` 或 `openai`（兼容任意 OpenAI 格式 API） |
| `server.endpoint` | 润色服务地址。ollama 默认 `http://localhost:11434` |
| `server.model` | 润色模型（推荐轻量模型，如 `qwen3:0.6b`） |
| `server.api_key` | API 密钥（ollama 不需要） |
| `polish.enabled` | `false` 则跳过润色，直接注入原始转写 |
| `polish.system_prompt` | 润色指令 |

### distill — 蒸馏（独立于润色）

后台批量运行，用大模型纠正 SA 转写结果，生成 `(input, output)` 训练对。与润色完全独立，有自己的 API 配置。

| 字段 | 说明 |
|------|------|
| `distill.enabled` | 是否在同步时自动运行蒸馏 |
| `distill.base_url` | 蒸馏用 API 地址（OpenAI 兼容格式） |
| `distill.api_key` | 蒸馏用 API 密钥（如 Gemini API key） |
| `distill.model` | 蒸馏模型（推荐 `gemini-2.5-flash`，准确且便宜） |

Gemini 示例：`base_url` = `https://generativelanguage.googleapis.com/v1beta/openai`

### sync — 数据同步到训练服务器

将本地数据（转写历史、音频、蒸馏结果）通过 rsync + SSH 同步到 GPU 服务器，用于路线 A (Whisper) 蒸馏和模型微调。

| 字段 | 说明 |
|------|------|
| `sync.enabled` | 是否启用同步 |
| `sync.server` | SSH 目标（如 `user@192.168.1.100`） |
| `sync.remote_dir` | 远程目录路径 |

启用后：`make install-sync` 安装自动同步（voice-history 变化时触发），或 `make sync` 手动执行。

## Data

所有数据存储在 `~/.we/`：

```
~/.we/
├── config.json            # 配置（热更新）
├── voice-history.jsonl    # 客户端采集：每次转写的完整记录
├── corrections.jsonl      # 客户端采集：用户纠错记录
├── audio/                 # 客户端采集：原始录音 WAV
├── distill-gemini.jsonl   # 蒸馏产出：路线 B（Gemini 纠正）
├── distill-whisper.jsonl  # 蒸馏产出：路线 A（Whisper 重转写）
├── merged-pairs.jsonl     # 蒸馏产出：合并后的最终训练集
└── meetings/              # 会议转录 Markdown
```

### voice-history.jsonl — 客户端采集，蒸馏输入

每次语音输入自动写入一条，是整个数据飞轮的起点。

```jsonc
{
  "timestamp": "2026-03-12T10:30:00Z",
  "rawSA": "我在试一下能不能转",          // SpeechAnalyzer 原始输出
  "l1Text": "我再试一下能不能转",          // L1 候选词纠错后
  "polishedText": "我再试一下能不能转写。", // L2 润色后（可能为 null）
  "finalText": "我再试一下能不能转写。",    // 最终注入的文本
  "words": [                              // 词级信息
    {"text": "我", "confidence": 0.98},
    {"text": "在", "confidence": 0.45},    // 低置信度 → 潜在错误点
    ...
  ],
  "audioPath": "~/.we/audio/20260312-103000.wav",
  "appBundleID": "com.tencent.xinWeChat",  // 当时的焦点应用
  "appName": "微信"
}
```

### corrections.jsonl — 用户纠错（高优训练数据）

用户手动修改注入文本后自动采集（需开启 `correction_enabled`）。人工纠错在合并时权重 x2。

```jsonc
{
  "timestamp": "2026-03-12T10:30:15Z",
  "rawText": "我在试一下",         // 注入时的文本
  "insertedText": "我在试一下",    // 注入的原文
  "userFinalText": "我再试一下",   // 用户修改后的文本
  "diffs": [                      // 语义级 diff
    {"original": "在", "corrected": "再"}
  ],
  "quality": 0.85,                // 纠正质量分
  "source": "human",
  "appBundleID": "com.tencent.xinWeChat"
}
```

### distill-gemini.jsonl — 蒸馏路线 B 产出

Gemini 2.5 Flash 对 SA 原文 + 小模型润色结果做纠正，生成训练对。

```jsonc
{
  "input": "我在试一下能不能转",    // SA 原始输出（训练输入）
  "output": "我再试一下能不能转",   // Gemini 纠正后（训练目标）
  "source": "gemini",
  "polished_0.6b": "我再试一下能不能转写。",  // 小模型的润色结果（参考）
  "edit_ratio": 0.05,             // 编辑距离比（>0.3 被过滤）
  "avg_confidence": 0.82,         // SA 词级平均置信度
  "timestamp": "2026-03-12T10:30:00Z"
}
```

### distill-whisper.jsonl — 蒸馏路线 A 产出

Whisper large 对原始音频重新转写，与 SA 输出配对。在 GPU 服务器上运行。

```jsonc
{
  "input": "我在试一下能不能转",    // SA 原始输出（训练输入）
  "output": "我再试一下能不能转",   // Whisper 转写（训练目标）
  "source": "whisper",
  "edit_ratio": 0.05,
  "avg_confidence": 0.82,
  "audio_path": "~/.we/audio/20260312-103000.wav",
  "timestamp": "2026-03-12T10:30:00Z"
}
```

### merged-pairs.jsonl — 合并后的最终训练集

`merge_pairs.py` 合并路线 A + B + 人工纠错，去重 + 冲突仲裁。

```jsonc
{
  "input": "我在试一下能不能转",
  "output": "我再试一下能不能转",
  "source": "human",              // human > gemini = whisper
  "sample_weight": 2.0,           // human=2.0, 多路一致=1.5, 默认=1.0
  "conflict": false               // true 表示路线 A/B 结果不一致
}
```

合并优先级：**人工纠错 > 多路一致 > 单路结果**。冲突条目保留但标记，供人工审查。

## Architecture

<details>
<summary>展开</summary>

```
麦克风 ──→ [G1 声音门控] ──→ start/stop
  │                              │
  └──→ [G2 流式转写] ←───── trigger
             ▲
屏幕截图 ──→ [G3 OCR] ──→ 上下文偏置
             │
             ▼
      L1 候选词纠错 → L2 LLM润色 → 注入当前App
             │
             ▼
      voice-history.jsonl ──→ 自动同步 ──→ 训练服务器
             │                                │
             │                  ┌──────────────┤
             ▼                  ▼              ▼
      corrections.jsonl   路线A: Whisper  路线B: Gemini
             │                  │              │
             └──────────────────┴──────┬───────┘
                                       ▼
                                merge_pairs.py
                                       │
                                       ▼
                                微调 → 更好的端侧模型
```

- **G1** — SpeechDetector / CoreAudio HAL VAD
- **G2** — SpeechAnalyzer + SpeechTranscriber（volatile + alternatives + 时间戳）
- **G3** — ScreenCaptureKit + Vision OCR
- **会议模式** — FluidAudio 说话人分离（CoreML 端侧）

</details>

## Development

```bash
cd client
make build      # 编译
make run        # 编译 + 运行（开发模式）
make clean      # 清理
make check-log  # 查看最近日志
make check-data # 检查数据落盘
```

## License

MIT
