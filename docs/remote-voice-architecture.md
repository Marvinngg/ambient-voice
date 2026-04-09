# WE 远程语音架构方案

## 一、问题

Windows PC 通过远程桌面操作 Mac Mini。屏幕是 Mac Mini 的，麦克风在 Windows 侧。WE 依赖 Apple SpeechAnalyzer，只能跑在 macOS。需要把 Windows 的音频传到 Mac Mini 的 WE，文字直接注入焦点窗口。

## 二、设计原则：参照 Taildrop

Taildrop（文件传输）是 Tailscale 的一等公民功能：
- `ipnext.Extension` 注册到 `tailscaled`，随 daemon 默认启用
- **PeerAPI** 做节点间传输（接收端 HTTP handler）
- **LocalAPI** 做本地客户端到 daemon 的通信（发送端）
- **CLI** `tailscale file cp` 是发送的薄客户端
- 编译开关 `ts_omit_taildrop` 可移除

VoiceRelay 完全复刻这个模式。语音就是一种特殊的"文件传输"——发送的是 WAV，接收端写到 WE 的目录里。

## 三、系统拓扑

```
Windows PC                                        Mac Mini (mac-dev)
┌────────────────────────────────┐                ┌──────────────────────────────────┐
│                                │                │                                  │
│  tailscaled (Windows Service)  │                │  tailscaled (launchd)            │
│  ┌──────────────────────────┐  │    PeerAPI     │  ┌──────────────────────────┐    │
│  │ Extension: voicerelay    │  │ ═══════════►   │  │ Extension: voicerelay    │    │
│  │                          │  │   Tailnet      │  │                          │    │
│  │ LocalAPI:                │  │   WireGuard    │  │ PeerAPI:                 │    │
│  │ POST /voice-send/{node} │  │                │  │ PUT /v0/voice/{file}     │    │
│  │  ↑ 收 WAV → 转发 PeerAPI │  │                │  │  → ~/.we/remote-inbox/   │    │
│  └──────────────────────────┘  │                │  └──────────────────────────┘    │
│           ↑ LocalAPI                            │             │ 写文件              │
│  ┌────────┴───────────────┐    │                │  ┌──────────▼─────────────────┐  │
│  │ tailscale voice        │    │                │  │ WE App                     │  │
│  │ (CLI，用户态持久进程)   │    │                │  │                            │  │
│  │                        │    │                │  │ FSEvents 监听              │  │
│  │ • 全局快捷键 (RAlt)    │    │                │  │ ~/.we/remote-inbox/        │  │
│  │ • 麦克风录音 (WASAPI)  │    │                │  │   ↓                        │  │
│  │ • WAV → LocalAPI POST  │    │                │  │ SpeechAnalyzer (文件输入)  │  │
│  └────────────────────────┘    │                │  │   ↓                        │  │
│                                │                │  │ VoicePipeline (L1+L2)      │  │
│  远程桌面客户端               │                │  │   ↓                        │  │
│  (看到 Mac Mini 屏幕)          │ ◄── 屏幕画面 ── │  │ TextInjector → 焦点窗口    │  │
│                                │                │  │   ↓                        │  │
│                                │                │  │ VoiceHistory (数据飞轮)    │  │
└────────────────────────────────┘                └──────────────────────────────────┘
```

## 四、数据流

```
1. 用户按住 RAlt（tailscale voice 进程监听 Win32 全局热键）
2. Windows 麦克风开始录音（WASAPI，16kHz/16bit/mono PCM）
3. 用户松开 RAlt
4. 录音停止，WAV 数据 POST 到 LocalAPI:
   POST /localapi/v0/voice-send/{mac-dev-stableID}
   Body: WAV binary
5. tailscaled Extension 收到 → 通过 PeerAPI 转发:
   PUT {mac-dev-PeerAPI}/v0/voice/{timestamp}.wav
   （和 Taildrop 的 PUT /v0/put/{filename} 完全对称）
6. Mac Mini tailscaled Extension 收到 → 写入 ~/.we/remote-inbox/{timestamp}.wav
7. WE App FSEvents 检测到新文件
8. SpeechAnalyzer.start(inputAudioFile:, finishAfterFile: true)
9. VoicePipeline → L1 + L2 → TextInjector → 焦点窗口出字
10. VoiceHistory 落盘（和本地语音格式一致，进蒸馏飞轮）
11. 处理完毕，删除 remote-inbox 中的 WAV
```

## 五、Tailscale 侧：voicerelay Extension

### 5.1 文件结构

```
client/feature/voicerelay/
├── ext.go                    Extension 注册 + 生命周期（参照 taildrop/ext.go）
├── peerapi.go                PeerAPI handler: PUT /v0/voice/{filename}
├── localapi.go               LocalAPI handler: POST /localapi/v0/voice-send/{stableID}
├── voicerelay.go             核心逻辑（接收存文件、发送转发）
└── paths.go                  接收目录路径（~/.we/remote-inbox/）

client/feature/buildfeatures/
├── feature_voicerelay_enabled.go     const HasVoiceRelay = true
└── feature_voicerelay_disabled.go    const HasVoiceRelay = false (ts_omit_voicerelay)

client/feature/condregister/
└── maybe_voicerelay.go               //go:build !ts_omit_voicerelay
                                      import _ "tailscale.com/feature/voicerelay"

client/cmd/tailscale/cli/
└── voice.go                          tailscale voice 子命令
```

### 5.2 Extension 核心 (ext.go)

```go
package voicerelay

import "tailscale.com/ipn/ipnext"

func init() {
    ipnext.RegisterExtension("voicerelay", newExtension)
}

type extension struct {
    host   ipnext.Host
    inboxDir string  // ~/.we/remote-inbox/ (Mac) 或空 (其他平台)
}

func newExtension(h ipnext.Host) (ipnext.Extension, error) {
    ext := &extension{host: h}
    
    // 注册 PeerAPI handler（接收端）
    h.RegisterPeerAPIHandler("/v0/voice/", ext.handlePeerVoice)
    
    // 注册 LocalAPI handler（发送端）
    h.RegisterLocalAPIHandler("voice-send/", ext.serveVoiceSend)
    
    return ext, nil
}
```

### 5.3 接收端 PeerAPI (peerapi.go)

```go
// Mac Mini 的 tailscaled 收到来自 Windows 的音频
// PUT {PeerAPI}/v0/voice/{timestamp}.wav

func (ext *extension) handlePeerVoice(w http.ResponseWriter, r *http.Request) {
    filename := path.Base(r.URL.Path)
    
    // 写入 ~/.we/remote-inbox/
    dst := filepath.Join(ext.inboxDir, filename)
    f, _ := os.Create(dst + ".partial")
    io.Copy(f, r.Body)
    f.Close()
    os.Rename(dst+".partial", dst)  // 原子重命名，WE 只看完整文件
    
    w.WriteHeader(http.StatusOK)
}
```

和 Taildrop 的 `handlePeerPut` 同样的 partial → rename 模式。

### 5.4 发送端 LocalAPI (localapi.go)

```go
// Windows 的 tailscale voice CLI 调用本地 daemon
// POST /localapi/v0/voice-send/{stableID}
// Body: WAV binary

func (ext *extension) serveVoiceSend(w http.ResponseWriter, r *http.Request) {
    stableID := extractStableID(r.URL.Path)
    
    // 查找目标节点的 PeerAPI URL
    targetURL := ext.host.PeerAPIURL(stableID)
    
    // 构造 PeerAPI 请求转发
    filename := time.Now().Format("20060102-150405") + ".wav"
    req, _ := http.NewRequest("PUT", targetURL+"/v0/voice/"+filename, r.Body)
    
    resp, _ := ext.host.DoHTTPRequest(req)  // 通过 Tailnet 发送
    w.WriteHeader(resp.StatusCode)
}
```

和 Taildrop 的 `serveFilePut` 同样的 LocalAPI → PeerAPI 转发模式。

### 5.5 CLI 命令 (voice.go)

```go
// cmd/tailscale/cli/voice.go

// tailscale voice --target mac-dev --hotkey RAlt
// 
// 持久运行，监听全局快捷键，录音后通过 LocalAPI 发送。
// 类似 tailscale file cp 但是：
//   - 持久进程（不是一次性命令）
//   - 自带录音能力（不读文件）
//   - 快捷键触发（不是命令行参数）

var voiceCmd = &cobra.Command{
    Use:   "voice",
    Short: "Voice relay to a remote node",
    Long:  "Record audio and send to a Tailscale peer for speech recognition",
}

func runVoice(ctx context.Context, args []string) error {
    target := voiceArgs.target     // mac-dev
    hotkey := voiceArgs.hotkey     // RAlt
    
    // 1. 解析目标节点
    st, _ := localClient.Status(ctx)
    peer := findPeer(st, target)
    
    // 2. 注册全局热键（平台相关）
    hk := registerHotkey(hotkey)
    
    // 3. 事件循环
    for {
        select {
        case <-hk.Down:
            recorder.Start()
        case <-hk.Up:
            wav := recorder.Stop()
            // 通过 LocalAPI 发送
            localClient.VoiceSend(ctx, peer.ID, wav)
        case <-ctx.Done():
            return nil
        }
    }
}
```

### 5.6 Windows 开机自启

Extension 在初始化时注册 Windows 计划任务或 Run 注册表项（和 Taildrop 注册 shell extension 类似）：

```go
// ext.go 中
func (ext *extension) Init(h ipnext.Host) error {
    // Windows: 注册开机自启 "tailscale voice --target mac-dev"
    if runtime.GOOS == "windows" {
        registerAutoStart("tailscale voice --target " + ext.defaultTarget)
    }
    return nil
}
```

用户首次配置 `tailscale voice --target mac-dev`，之后随系统自动启动。

---

## 六、WE 侧：目录监听

### 6.1 设计选择

| 方案 | 说明 |
|------|------|
| ~~WE 开 HTTP 端口~~ | WE 要变成网络服务器，增加攻击面和复杂度 |
| **WE 监听本地目录** | tailscaled 写文件，WE 读文件。两者通过文件系统解耦 |

目录监听方案和 Taildrop 的"中转模式"完全一致：daemon 写文件到本地目录，上层应用消费。

### 6.2 文件结构

```
client/Sources/              (WE 项目)
├── RemoteInbox.swift        (新增：FSEvents 目录监听 + SA 处理)
├── WEApp.swift              (改动：AppDelegate 启动 RemoteInbox)
├── StatusBarController.swift (改动：菜单显示远程状态)
└── ... 其他文件不动
```

只新增一个文件，改动两个文件。不需要 RemoteServer、不需要 NWListener、不需要 HTTP。

### 6.3 RemoteInbox 设计

```swift
// Sources/RemoteInbox.swift

/// 监听 ~/.we/remote-inbox/ 目录
/// tailscaled voicerelay Extension 会往这里写 WAV 文件
/// 检测到新 WAV → SpeechAnalyzer → Pipeline → TextInjector
@MainActor
final class RemoteInbox {
    private let inboxURL = WEDataDir.url.appendingPathComponent("remote-inbox")
    private var watcher: DispatchSourceFileSystemObject?
    private let pipeline = VoicePipeline()
    
    func start() {
        // 确保目录存在
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        
        // FSEvents 监听（和 RuntimeConfig 的 config.json 监听方式一致）
        let fd = open(inboxURL.path, O_EVTONLY)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in self?.processInbox() }
        source.resume()
        watcher = source
    }
    
    private func processInbox() {
        // 扫描目录，处理所有 .wav 文件（跳过 .partial）
        let files = try? FileManager.default.contentsOfDirectory(at: inboxURL, ...)
        for file in files where file.pathExtension == "wav" {
            Task { await processWAV(file) }
        }
    }
    
    private func processWAV(_ url: URL) async {
        // 复用 MeetingSession 已验证的文件输入 API
        let transcriber = SpeechTranscriber(locale: bestLocale, ...)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let inputFile = try AVAudioFile(forReading: url)
        try await analyzer.start(inputAudioFile: inputFile, finishAfterFile: true)
        
        // 收集结果 → Pipeline（L1 + L2 + TextInjector + VoiceHistory）
        let result = collectResults(from: transcriber)
        await pipeline.process(transcription: result, targetApp: .current())
        
        // 处理完毕，删除或移动到 audio/ 归档
        try? FileManager.default.moveItem(at: url, to: audioArchiveURL)
    }
}
```

### 6.4 为什么不需要 RemoteServer 了

| 之前方案 | 现在方案 |
|---------|---------|
| WE 开 NWListener HTTP 端口 | WE 不开任何端口 |
| Windows 直连 WE 的 :9800 | Windows → tailscaled → PeerAPI → tailscaled → 文件 → WE |
| WE 要自己做认证 | Tailscale 已认证（PeerAPI 有 capability 检查） |
| WE 变成网络服务 | WE 保持纯本地应用 |
| 绕过 Tailscale | 用 Tailscale 原生传输 |

**WE 唯一新增的就是一个目录监听器。** 网络传输完全交给 Tailscale。

---

## 七、整体架构位置

```
┌──────────────────────────────────────────────────────────────────┐
│                      Tailscale 私域网络 (Headscale)               │
│                                                                   │
│  ┌────────┐  ┌────────┐  ┌─────────┐  ┌───────────────────────┐ │
│  │ hs-vm  │  │  v100  │  │ jp-4080 │  │ mac-dev               │ │
│  │Headscale│  │千问3.5 │  │纠错训练 │  │                       │ │
│  │Portal  │  │Ollama  │  │QLoRA    │  │ tailscaled            │ │
│  │NanoClaw│  │        │  │         │  │  ├ taildrop (文件传输) │ │
│  │        │  │        │  │         │  │  └ voicerelay (语音)◄──┼─┼── PeerAPI
│  └────────┘  └────────┘  └─────────┘  │       ↓ 写文件         │ │
│                                        │ ~/.we/remote-inbox/   │ │
│                                        │       ↓ FSEvents      │ │
│                                        │ WE App               │ │
│                                        │  ├ 本地语音 (热键)    │ │
│                                        │  ├ 远程语音 (inbox)   │ │
│                                        │  ├ 会议录音           │ │
│                                        │  └ 数据飞轮           │ │
│                                        └───────────────────────┘ │
│                                                                   │
│  Win PC ──────────────────────────────────────────────────────── │
│  ┌─────────────────────────────────┐                             │
│  │ tailscaled (Windows Service)    │                             │
│  │  ├ taildrop (文件传输)          │ ── PeerAPI ──►              │
│  │  └ voicerelay (语音转发)        │                             │
│  │       ↑ LocalAPI                │                             │
│  │ tailscale voice (用户态)        │                             │
│  │  ├ 全局快捷键 (RAlt)            │                             │
│  │  └ WASAPI 录音 → WAV           │                             │
│  └─────────────────────────────────┘                             │
│                                                                   │
│  数据飞轮（本地/远程一致）                                         │
│  voice-history.jsonl + audio/*.wav                               │
│   → Whisper 蒸馏 (jp-4080) + Gemini Flash 纠正                  │
│   → QLoRA → 0.6B adapter → WE 润色升级                          │
└──────────────────────────────────────────────────────────────────┘
```

## 八、改动总览

### Tailscale 客户端 (Go)

| 文件 | 类型 | 参照 |
|------|------|------|
| `feature/voicerelay/ext.go` | 新增 | `feature/taildrop/ext.go` |
| `feature/voicerelay/peerapi.go` | 新增 | `feature/taildrop/peerapi.go` |
| `feature/voicerelay/localapi.go` | 新增 | `feature/taildrop/localapi.go` |
| `feature/voicerelay/voicerelay.go` | 新增 | `feature/taildrop/taildrop.go` |
| `feature/voicerelay/paths.go` | 新增 | `feature/taildrop/paths.go` |
| `feature/buildfeatures/feature_voicerelay_*.go` | 新增 | 编译开关 |
| `feature/condregister/maybe_voicerelay.go` | 新增 | 自动注册 |
| `cmd/tailscale/cli/voice.go` | 新增 | 参照 `cli/file.go` |
| `cmd/tailscale/cli/voice_windows.go` | 新增 | 热键 + WASAPI 录音 |

### WE (Swift)

| 文件 | 类型 | 说明 |
|------|------|------|
| `Sources/RemoteInbox.swift` | 新增 | FSEvents 目录监听 + SA 文件处理 |
| `Sources/WEApp.swift` | 改动 | AppDelegate 启动 RemoteInbox |
| `Sources/StatusBarController.swift` | 改动 | 菜单显示远程状态 |

### 不改的

| 组件 | 为什么不改 |
|------|----------|
| VoiceSession / VoicePipeline / TextInjector / VoiceHistory | 完全复用 |
| Headscale server / Portal / ACL | 网络层已就绪 |
| tailscale-gui | 不在 GUI 里，在 daemon + CLI 里 |
| go.mod (Tailscale) | `tailscale voice` 的录音用 Windows syscall，不加新依赖；或加 portaudio 一个 |

## 九、实施顺序

```
Phase 1: Tailscale Extension 骨架
  ├── feature/voicerelay/ 照搬 taildrop 结构
  ├── ext.go: 注册 + PeerAPI handler（接收写文件）
  ├── localapi.go: LocalAPI handler（转发）
  ├── 编译开关 + condregister
  └── 验证: curl 调 LocalAPI → Mac Mini 的 ~/.we/remote-inbox/ 出现 WAV

Phase 2: WE RemoteInbox
  ├── RemoteInbox.swift: FSEvents 目录监听
  ├── 检测 WAV → SA 文件输入 → Pipeline → TextInjector
  ├── AppDelegate 集成
  └── 验证: 手动放一个 WAV 到 remote-inbox/ → 文字出现在焦点窗口

Phase 3: CLI tailscale voice
  ├── cli/voice.go: 命令框架 + LocalAPI 调用
  ├── voice_windows.go: Win32 RegisterHotKey + WASAPI 录音
  └── 验证: 完整链路——按快捷键说话 → 文字出现在 Mac Mini 远程桌面

Phase 4: 自启与体验
  ├── Windows 开机自启注册
  ├── 录音/发送/就绪状态反馈（声音提示或 Windows Toast）
  └── WE StatusBar 显示远程连接数
```

## 十、设计原则

1. **照搬 Taildrop 模式** — Extension + PeerAPI + LocalAPI + CLI，不发明新模式
2. **WE 不开端口** — 通过文件系统解耦，WE 保持纯本地应用
3. **默认开启** — Extension 随 tailscaled 自动加载，和 Taildrop 一样
4. **不改已有代码** — VoiceSession/Pipeline/TextInjector/VoiceHistory 全复用
5. **编译可移除** — `ts_omit_voicerelay` 标签可完全去除此功能
