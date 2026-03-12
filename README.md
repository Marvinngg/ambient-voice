# ambient-voice

**你的声音，直接变成文字。越用越准。**

不需要打开任何 App，不需要切换输入法。按住说话，松开注入——文字出现在你正在使用的任何应用里。

- **原生** — 基于 Apple SpeechAnalyzer (macOS 26)，不依赖 Whisper、不依赖云端 ASR。系统升级 = 能力升级
- **快** — 全链路端侧处理，毫秒级响应。说完即得，不等网络
- **本地** — 你的声音不离开你的设备。转写、OCR、润色均可离线完成
- **越用越好** — 每次使用自动积累数据，通过蒸馏管线持续改进端侧模型

## Demo

> *(GIF/视频占位)*

## Architecture

```
麦克风 ──→ [G1 声音门控] ──→ start/stop
  │                              │
  └──→ [G2 流式转写] ←───── trigger
             ▲
屏幕截图 ──→ [G3 OCR] ──→ 上下文偏置
             │
             ▼
      L1 候选词纠错 → L2 LLM润色 → 注入当前App
             │                        │
             ▼                        ▼
      voice-history.jsonl      纠错自动采集（30s 窗口）
             │                        │
             ▼                        ▼
      ┌──────┴──────┐          corrections.jsonl
      ▼             ▼                 │
 路线A: Whisper  路线B: Gemini        │
      │             │                 │
      └──────┬──────┘                 │
             ▼                        │
      merge_pairs.py ←────────────────┘
             │         (人工纠错权重 x2)
             ▼
      微调 → 更好的端侧模型 → 替换 L2
```

| 模块 | 实现 |
|------|------|
| G1 声音门控 | SpeechDetector / CoreAudio HAL VAD |
| G2 流式转写 | SpeechAnalyzer + SpeechTranscriber（volatile + alternatives + 时间戳）|
| G3 屏幕上下文 | ScreenCaptureKit + Vision OCR |
| L1 候选词纠错 | AlternativeSwap（基于历史纠错数据） |
| L2 实时润色 | ollama / OpenAI 兼容 API（本地小模型） |
| 纠错采集 | 注入后 30s 窗口，AX 读取用户修改，自动生成训练对 |
| 会议模式 | FluidAudio 说话人分离（CoreML 端侧） |
| 蒸馏路线 A | 原始音频 → Whisper large 重转写（GPU 服务器） |
| 蒸馏路线 B | SA 原文 + 小模型输出 → Gemini 2.5 Flash 纠正 |

## Features

**语音听写**
- 按住右 Option 说话，松开自动注入当前应用
- 实时流式转写，说完即得
- 屏幕上下文感知——系统知道你在回复什么，同音词选择更准
- 可选 LLM 润色（口语 → 书面语）
- 自动纠错采集——注入后如果你改了文字，系统自动学习

**会议录音**
- 长时间连续录音 + 实时转录悬浮窗
- 录完自动说话人分离（FluidAudio, CoreML 端侧）
- 自动导出带时间戳 + 说话人标签的 Markdown

**数据飞轮**
- 每次转写自动积累训练数据
- 双路线蒸馏 + 人工纠错，三路合并生成训练集
- 蒸馏产出回灌端侧模型，形成闭环

## Requirements

- macOS 26 (Tahoe) 或更高
- Apple Silicon

## Install

推荐用 [Claude Code](https://claude.ai/claude-code) 协助安装和开发——本项目基于 macOS 26 新框架，遇到编译或权限问题时 Claude Code 可以直接帮你诊断和修复。

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

## Config

`~/.we/config.json`，修改后自动生效。首次运行自动创建。

润色和蒸馏是独立的，各有自己的 API 配置：

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

| 段 | 用途 | 说明 |
|---|---|---|
| `server` + `polish` | 实时润色 | 每次说话调用，要求低延迟。推荐本地 ollama |
| `distill` | 批量蒸馏 | 后台运行，用大模型纠正转写。独立的 `base_url` / `api_key` / `model` |
| `sync` | 数据同步 | rsync + SSH 推送到 GPU 服务器。`make install-sync` 安装自动触发 |

## Training Data

所有数据存储在 `~/.we/`，训练集格式统一为 `{"input": ..., "output": ...}` 的 JSONL：

```
~/.we/
├── voice-history.jsonl    ← 客户端每次转写自动写入（蒸馏输入源）
├── corrections.jsonl      ← 用户纠错自动采集（人工标注，权重 x2）
├── audio/                 ← 原始录音 WAV（路线 A 输入）
├── distill-gemini.jsonl   ← 路线 B 产出
├── distill-whisper.jsonl  ← 路线 A 产出
└── merged-pairs.jsonl     ← 最终训练集（merge_pairs.py 合并三路）
```

训练对格式：

```jsonc
// 蒸馏产出（路线 A / B）
{"input": "SA原始转写", "output": "纠正后文本", "source": "gemini|whisper", "edit_ratio": 0.05}

// 合并后训练集
{"input": "...", "output": "...", "source": "human|gemini|whisper", "sample_weight": 2.0}
```

合并优先级：**人工纠错 (x2) > 多路一致 (x1.5) > 单路 (x1)**

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
