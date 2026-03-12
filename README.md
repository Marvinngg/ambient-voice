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
- ollama 或任意 OpenAI 兼容 API（可选，用于润色/蒸馏）

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

### server — 润色用的 LLM

| 字段 | 说明 |
|------|------|
| `api` | `ollama` 或 `openai`（兼容 Gemini、DeepSeek、OpenRouter 等任意 OpenAI 格式 API） |
| `endpoint` | 服务地址。ollama 默认 `http://localhost:11434`；Gemini 用 `https://generativelanguage.googleapis.com/v1beta/openai` |
| `model` | 模型名。关闭润色时此项无效 |
| `api_key` | OpenAI 兼容 API 的密钥（ollama 不需要） |

### polish — 润色开关

| 字段 | 说明 |
|------|------|
| `enabled` | `false` 则直接注入原始转写，零延迟零成本 |
| `system_prompt` | 润色指令，可按需调整 |

### distill — 蒸馏（路线 B）

用大模型纠正 SA 转写输出，生成高质量训练对。

| 字段 | 说明 |
|------|------|
| `enabled` | 是否在同步时自动运行蒸馏 |
| `base_url` | OpenAI 兼容 API 地址 |
| `api_key` | API 密钥 |
| `model` | 蒸馏用模型（推荐 `gemini-2.5-flash`，性价比最高） |

### sync — 数据同步

将本地数据（转写历史、音频、蒸馏结果）同步到训练服务器。

| 字段 | 说明 |
|------|------|
| `enabled` | 是否启用同步 |
| `server` | SSH 目标，如 `user@192.168.1.100` |
| `remote_dir` | 远程目录 |

启用后：`make install-sync` 安装自动同步（voice-history 变化时自动触发），或 `make sync` 手动执行。

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
                                            │
                              ┌──────────────┤
                              ▼              ▼
                     路线A: Whisper    路线B: Gemini
                              │              │
                              └──────┬───────┘
                                     ▼
                              合并 → 微调 → 更好的端侧模型
```

- **G1** — SpeechDetector / CoreAudio HAL VAD
- **G2** — SpeechAnalyzer + SpeechTranscriber（volatile + alternatives + 时间戳）
- **G3** — ScreenCaptureKit + Vision OCR
- **会议模式** — FluidAudio 说话人分离（CoreML 端侧）

</details>

## Data

```
~/.we/
├── config.json            # 配置（热更新）
├── voice-history.jsonl    # 转写历史（蒸馏输入）
├── corrections.jsonl      # 用户纠错（高优训练数据）
├── distill-gemini.jsonl   # 蒸馏产出（路线B）
├── audio/                 # 录音文件（路线A输入）
└── meetings/              # 会议转录 Markdown
```

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
