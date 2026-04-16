import AppKit
import SwiftUI

@main
struct WEApp {
    static func main() {
        // contextualStrings 容量测试
        if CommandLine.arguments.contains("--test-context-capacity") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                await ContextCapacityTest.run()
                app.terminate(nil)
            }
            app.run()
            return
        }

        // alternatives 测试：WE --test-alternatives <wav-file>
        if CommandLine.arguments.contains("--test-alternatives") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                await AlternativesTest.run()
                app.terminate(nil)
            }
            app.run()
            return
        }

        // 评估模式：WE --bench-meeting <wav-file> [--locale zh-CN] [--output result.json]
        if CommandLine.arguments.contains("--bench-meeting") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                await MeetingBenchmark.run()
                app.terminate(nil)
            }
            app.run()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // 菜单栏应用，不显示 Dock 图标
        app.run()
    }
}

/// 会议模式评估入口
/// 用法：WE --bench-meeting <wav> [--locale zh-CN] [--output result.json]
///   或：WE --bench-meeting --batch <manifest.jsonl> [--output-dir results/]
enum MeetingBenchmark {
    @MainActor
    static func run() async {
        WEDataDir.ensureExists()
        let args = CommandLine.arguments

        guard let benchIdx = args.firstIndex(of: "--bench-meeting"), benchIdx + 1 < args.count else {
            print("Usage: WE --bench-meeting <wav-file> [--locale zh-CN] [--output result.json]")
            print("       WE --bench-meeting --batch <manifest.jsonl> [--output-dir results/]")
            return
        }

        let locale = parseArg(args, key: "--locale") ?? "zh-CN"

        if args.contains("--batch") {
            guard let manifest = parseArg(args, key: "--batch") else {
                print("Error: --batch requires manifest file path")
                return
            }
            let outputDir = parseArg(args, key: "--output-dir") ?? "bench-results"
            await runBatch(manifest: manifest, outputDir: outputDir, locale: locale)
        } else {
            let wavPath = args[benchIdx + 1]
            let output = parseArg(args, key: "--output")
            await runSingle(wavPath: wavPath, locale: locale, outputPath: output)
        }
    }

    @MainActor
    static func runSingle(wavPath: String, locale: String, outputPath: String?) async {
        let fileURL = URL(fileURLWithPath: wavPath)
        guard FileManager.default.fileExists(atPath: wavPath) else {
            print("Error: file not found: \(wavPath)")
            return
        }

        print("Audio: \(wavPath)")
        print("Locale: \(locale)")

        let meetingConfig = WEConfig.MeetingConfig.default
        let session = MeetingSession(config: meetingConfig)
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = await session.runFromFile(fileURL, locale: locale)
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime

        // 导出 Markdown（走我们的 MeetingExporter）
        let mdURL = MeetingExporter.exportMarkdown(
            segments: result.segments,
            duration: result.duration
        )

        // 构建评估 JSON
        let json = formatResult(result, totalTime: totalTime, mdPath: mdURL?.path)

        if let outputPath {
            let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: outputPath))
            print("Result: \(outputPath)")
        } else {
            let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data ?? Data(), encoding: .utf8) ?? "{}")
        }

        if let md = mdURL {
            print("Markdown: \(md.path)")
        }
    }

    @MainActor
    static func runBatch(manifest: String, outputDir: String, locale: String) async {
        guard let content = try? String(contentsOfFile: manifest, encoding: .utf8) else {
            print("Error: cannot read \(manifest)")
            return
        }

        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let meetingConfig = WEConfig.MeetingConfig.default
        print("Manifest: \(manifest) (\(lines.count) files)")
        print("Output: \(outputDir)/\n")

        for (i, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let audioPath = entry["audio"] as? String else {
                print("[\(i+1)/\(lines.count)] SKIP: invalid line")
                continue
            }

            let id = entry["id"] as? String ?? URL(fileURLWithPath: audioPath).deletingPathExtension().lastPathComponent
            let entryLocale = entry["locale"] as? String ?? locale

            print("[\(i+1)/\(lines.count)] \(id) ...", terminator: " ")
            fflush(stdout)

            let fileURL = URL(fileURLWithPath: audioPath)
            let session = MeetingSession(config: meetingConfig)
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = await session.runFromFile(fileURL, locale: entryLocale)
            let totalTime = CFAbsoluteTimeGetCurrent() - startTime

            // 导出 Markdown
            let mdURL = MeetingExporter.exportMarkdown(
                segments: result.segments,
                duration: result.duration
            )

            // 保存 JSON
            let json = formatResult(result, totalTime: totalTime, mdPath: mdURL?.path)
            let jsonData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            let outPath = "\(outputDir)/\(id).json"
            try? jsonData?.write(to: URL(fileURLWithPath: outPath))

            let rtfx = result.duration / totalTime
            print("OK \(String(format: "%.1f", result.duration))s RTFx=\(String(format: "%.1f", rtfx)) segs=\(result.segments.count)")
        }
    }

    static func formatResult(_ result: MeetingResult, totalTime: Double, mdPath: String?) -> [String: Any] {
        var json: [String: Any] = [
            "audio": result.audioPath ?? "",
            "duration_s": round(result.duration * 100) / 100,
            "total_processing_s": round(totalTime * 100) / 100,
            "rtfx": round(result.duration / max(totalTime, 0.01) * 10) / 10,
            "n_segments": result.segments.count,
            "n_speakers": Set(result.segments.compactMap { $0.speakerId }).count,
            "markdown_path": mdPath ?? "",
            // 完整转写文本（供 WER/CER 对比）
            "hypothesis": result.segments.map { $0.text }.joined(),
            "segments": result.segments.map { seg in
                [
                    "text": seg.text,
                    "start": round(seg.startTime * 100) / 100,
                    "end": round(seg.endTime * 100) / 100,
                    "speaker": seg.speakerId ?? ""
                ] as [String: Any]
            }
        ]
        return json
    }

    static func parseArg(_ args: [String], key: String) -> String? {
        guard let idx = args.firstIndex(of: key), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private let moduleManager = ModuleManager()
    private let config = RuntimeConfig.shared
    private let recordingIndicator = RecordingIndicator()
    private let remoteInbox = RemoteInbox()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始化数据目录
        WEDataDir.ensureExists()

        // 检查权限
        let axOK = PermissionManager.checkAccessibility()
        let screenOK = PermissionManager.checkScreenCapture()
        Logger.log("WE", "Accessibility: \(axOK), Screen capture: \(screenOK)")

        // 初始化菜单栏
        statusBar = StatusBarController(moduleManager: moduleManager)

        // 注册语音模块
        let voiceModule = VoiceModule()
        voiceModule.onStateChange = { [weak self] state in
            guard let self else { return }
            let recording = state == .recording
            self.statusBar?.setRecording(recording)
            if recording {
                self.recordingIndicator.show()
            } else {
                self.recordingIndicator.hide()
            }
        }
        moduleManager.register(voiceModule)

        // 初始化 VoicePipeline（加载 replacements + polishClient）
        let weConfig = WEConfig.load()
        let serverConfig = config.serverConfig
        let endpoint = serverConfig["endpoint"] as? String ?? "http://localhost:11434"
        let model = serverConfig["model"] as? String ?? "qwen3:0.6b"
        VoicePipeline.configure(config: weConfig, localClient: LocalModelClient(endpoint: endpoint, model: model))

        // 注册全局热键
        GlobalHotKey.shared.onPress = { [weak self] in
            self?.moduleManager.activeModule?.onHotKeyDown()
        }
        GlobalHotKey.shared.onRelease = { [weak self] in
            self?.moduleManager.activeModule?.onHotKeyUp()
        }
        GlobalHotKey.shared.start()

        // 启动模型服务器健康检测
        ModelServer.shared.startHealthCheck()

        // 启动远程语音接收
        let remoteConfig = config.remoteConfig
        if remoteConfig["enabled"] as? Bool == true {
            let port = remoteConfig["port"] as? Int ?? 9800
            let token = remoteConfig["auth_token"] as? String ?? ""
            remoteInbox.onStatusChange = { [weak self] status in
                self?.statusBar?.setRemoteStatus(status)
            }
            remoteInbox.start(port: UInt16(port), authToken: token)
            Logger.log("WE", "Remote inbox: ON (:\(port))")
        }

        // G1 ambient 模式（config 控制开关）
        if config.ambientEnabled {
            let ambient = AmbientController.shared
            ambient.onSpeechStart = { [weak self] in
                guard let vm = self?.moduleManager.activeModule as? VoiceModule,
                      vm.state == .idle else { return }
                vm.onHotKeyDown()  // 复用热键流程：开始录音
            }
            ambient.onSpeechEnd = { [weak self] in
                guard let vm = self?.moduleManager.activeModule as? VoiceModule,
                      vm.state == .recording else { return }
                vm.onHotKeyUp()  // 复用热键流程：停止并处理
            }
            ambient.start()
            Logger.log("WE", "Ambient mode: ON")
        }

        Logger.log("WE", "App launched, modules: \(moduleManager.moduleNames)")
        Logger.log("WE", "Server endpoint: \(config.serverConfig["endpoint"] as? String ?? "not set")")
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKey.shared.stop()
        AmbientController.shared.stop()
        ModelServer.shared.stopHealthCheck()
        remoteInbox.stop()
        Logger.log("WE", "App terminated")
    }
}
