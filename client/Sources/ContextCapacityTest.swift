import AVFoundation
import Speech

/// 测试 SpeechAnalyzer contextualStrings 的容量上限
/// 用法: WE --test-context-capacity <wav-file>
enum ContextCapacityTest {
    @MainActor
    static func run() async {
        WEDataDir.ensureExists()
        let args = CommandLine.arguments

        guard let idx = args.firstIndex(of: "--test-context-capacity"), idx + 1 < args.count else {
            print("Usage: WE --test-context-capacity <wav-file>")
            return
        }

        let wavPath = args[idx + 1]

        guard FileManager.default.fileExists(atPath: wavPath) else {
            print("Error: file not found: \(wavPath)")
            return
        }

        print("=== contextualStrings 容量测试 ===")
        print("Audio: \(wavPath)")
        print()

        // 测试不同数量的 contextualStrings
        let testSizes = [0, 50, 100, 500, 1000, 5000]

        for size in testSizes {
            // 生成测试词汇
            var words: [String] = []
            if size > 0 {
                // 混合真实词汇 + 填充词
                let realWords = ["蒸馏", "微调", "Claude", "SpeechAnalyzer", "Whisper", "Gemini",
                                 "ollama", "数据飞轮", "contextualStrings", "AlternativeSwap",
                                 "FluidAudio", "CoreML", "Tailscale", "MacOS", "语音识别",
                                 "转写", "润色", "纠错", "模型", "训练"]
                words.append(contentsOf: realWords)
                for i in words.count..<size {
                    words.append("测试词\(i)")
                }
            }

            print("--- \(size) words ---")

            do {
                let localeObj = Locale(identifier: "zh-CN")
                let transcriber = SpeechTranscriber(
                    locale: localeObj,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults],
                    attributeOptions: [.audioTimeRange]
                )

                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath))

                // 注入 contextualStrings
                if !words.isEmpty {
                    let context = AnalysisContext()
                    context.contextualStrings[.general] = words
                    try await analyzer.setContext(context)
                    print("  Injected: \(words.count) words ✓")
                } else {
                    print("  No context (baseline)")
                }

                // 收集结果
                let collector = AlternativesCollector()

                let resultTask = Task { @Sendable in
                    do {
                        for try await result in transcriber.results {
                            guard result.isFinal else { continue }
                            let text = String(result.text.characters)
                            await collector.add(best: text, alternatives: [], wordConfidences: [])
                        }
                    } catch {}
                }

                let start = CFAbsoluteTimeGetCurrent()
                try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
                await resultTask.value
                let elapsed = CFAbsoluteTimeGetCurrent() - start

                let segments = await collector.segments
                let fullText = segments.map { $0.best }.joined()
                print("  Time: \(String(format: "%.2f", elapsed))s")
                print("  Segments: \(segments.count)")
                print("  Text: \(fullText.prefix(80))...")
                print()

            } catch {
                print("  ERROR: \(error)")
                print()
            }
        }
    }
}
