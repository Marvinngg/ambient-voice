/// TranscriptionBench — SpeechAnalyzer 转写准确率评估工具
///
/// 读取 WAV 音频文件，通过 Apple SpeechAnalyzer 转写，
/// 输出文本供外部脚本计算 WER/CER。
///
/// 用法:
///   transcription-bench <wav-file> [--locale zh-CN] [--output result.json]
///   transcription-bench --batch <manifest.jsonl> [--output-dir results/]
///
/// 单文件模式：转写一个 WAV，输出 JSON（含转写文本 + 耗时）
/// 批量模式：manifest.jsonl 每行 {"audio": "path.wav", "reference": "ground truth text"}

import AVFoundation
import Foundation
import Speech

// MARK: - 入口

@main
struct TranscriptionBench {
    static func main() async {
        let args = CommandLine.arguments

        guard args.count >= 2 else {
            printUsage()
            exit(1)
        }

        if args[1] == "--batch" {
            guard args.count >= 3 else {
                print("Error: --batch requires manifest file path")
                exit(1)
            }
            let manifest = args[2]
            let outputDir = parseArg(args, key: "--output-dir") ?? "results"
            await runBatch(manifest: manifest, outputDir: outputDir)
        } else {
            let wavPath = args[1]
            let locale = parseArg(args, key: "--locale") ?? "zh-CN"
            let output = parseArg(args, key: "--output")
            await runSingle(wavPath: wavPath, locale: locale, outputPath: output)
        }
    }

    static func printUsage() {
        print("""
        TranscriptionBench — SpeechAnalyzer 转写评估工具

        用法:
          transcription-bench <wav-file> [--locale zh-CN] [--output result.json]
          transcription-bench --batch <manifest.jsonl> [--output-dir results/]

        单文件模式:
          读取 WAV 文件，通过 SpeechAnalyzer 转写，输出 JSON

        批量模式:
          manifest.jsonl 每行格式: {"audio": "path/to/file.wav", "reference": "真实文本", "id": "meeting_001"}
          结果输出到 output-dir/

        输出 JSON 格式:
          {
            "id": "meeting_001",
            "audio": "path/to/file.wav",
            "duration_s": 120.5,
            "locale": "zh-CN",
            "hypothesis": "转写结果文本",
            "reference": "真实文本（如提供）",
            "processing_time_s": 3.2,
            "rtfx": 37.6,
            "segments": [
              {"text": "一段话", "start": 0.0, "end": 3.5, "is_final": true}
            ]
          }
        """)
    }

    // MARK: - 单文件

    static func runSingle(wavPath: String, locale: String, outputPath: String?) async {
        guard FileManager.default.fileExists(atPath: wavPath) else {
            print("Error: file not found: \(wavPath)")
            exit(1)
        }

        print("Audio: \(wavPath)")
        print("Locale: \(locale)")

        do {
            let result = try await transcribe(wavPath: wavPath, locale: locale)

            let json = formatResult(result)
            let jsonData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"

            if let outputPath {
                try jsonStr.write(toFile: outputPath, atomically: true, encoding: .utf8)
                print("Result saved to: \(outputPath)")
            } else {
                print(jsonStr)
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }

    // MARK: - 批量

    static func runBatch(manifest: String, outputDir: String) async {
        guard FileManager.default.fileExists(atPath: manifest) else {
            print("Error: manifest not found: \(manifest)")
            exit(1)
        }

        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        guard let content = try? String(contentsOfFile: manifest, encoding: .utf8) else {
            print("Error: cannot read manifest")
            exit(1)
        }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        print("Manifest: \(manifest) (\(lines.count) files)")
        print("Output: \(outputDir)/")
        print("")

        var allResults: [[String: Any]] = []

        for (i, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let audioPath = entry["audio"] as? String else {
                print("[\(i+1)/\(lines.count)] SKIP: invalid line")
                continue
            }

            let id = entry["id"] as? String ?? URL(fileURLWithPath: audioPath).deletingPathExtension().lastPathComponent
            let reference = entry["reference"] as? String
            let locale = entry["locale"] as? String ?? "zh-CN"

            print("[\(i+1)/\(lines.count)] \(id) ...", terminator: " ")
            fflush(stdout)

            do {
                var result = try await transcribe(wavPath: audioPath, locale: locale)
                result.reference = reference
                result.id = id

                let json = formatResult(result)
                let jsonData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"

                let outputPath = "\(outputDir)/\(id).json"
                try jsonStr.write(toFile: outputPath, atomically: true, encoding: .utf8)

                allResults.append(json)

                let rtfx = result.durationSeconds / result.processingTime
                print("OK  \(String(format: "%.1f", result.durationSeconds))s  RTFx=\(String(format: "%.1f", rtfx))  \(result.hypothesis.prefix(40))...")
            } catch {
                print("FAIL: \(error)")
            }
        }

        // 写汇总
        if !allResults.isEmpty {
            let summaryPath = "\(outputDir)/_summary.json"
            let summaryData = try? JSONSerialization.data(
                withJSONObject: ["count": allResults.count, "results": allResults],
                options: [.prettyPrinted, .sortedKeys]
            )
            try? summaryData?.write(to: URL(fileURLWithPath: summaryPath))
            print("\nSummary: \(summaryPath) (\(allResults.count) files)")
        }
    }

    // MARK: - 核心转写逻辑

    struct TranscriptionResult {
        var id: String = ""
        var audioPath: String
        var durationSeconds: Double
        var locale: String
        var hypothesis: String
        var reference: String?
        var processingTime: Double
        var segments: [(text: String, start: Double, end: Double, isFinal: Bool)]
    }

    static func transcribe(wavPath: String, locale: String) async throws -> TranscriptionResult {
        // 1. 读取 WAV 文件
        let fileURL = URL(fileURLWithPath: wavPath)
        let audioFile = try AVAudioFile(forReading: fileURL)
        let fileFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        let duration = Double(frameCount) / fileFormat.sampleRate

        print("(\(String(format: "%.1f", duration))s, \(Int(fileFormat.sampleRate))Hz)", terminator: " ")
        fflush(stdout)

        // 2. 创建 SpeechTranscriber
        let localeObj = Locale(identifier: locale)
        let transcriber = SpeechTranscriber(
            locale: localeObj,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        // 3. 确保模型已安装
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.language.languageCode == localeObj.language.languageCode }) {
            print("Warning: locale \(locale) not installed, attempting download...")
            if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await downloader.downloadAndInstall()
            }
        }

        // 4. 获取 analyzer 格式
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        guard let analyzerFormat else {
            throw NSError(domain: "TranscriptionBench", code: 1, userInfo: [NSLocalizedDescriptionKey: "No analyzer format available"])
        }

        // 5. 创建输入流
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        // 6. 启动分析器
        try await analyzer.start(inputSequence: inputSequence)

        // 7. 收集结果（用 actor 隔离满足 Swift 6 并发安全）
        let collector = ResultCollector()

        let resultTask = Task { @Sendable in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        var startTime: Double = 0
                        var endTime: Double = 0
                        typealias TimeKey = AttributeScopes.SpeechAttributes.TimeRangeAttribute
                        for (timeRange, _) in result.text.runs[TimeKey.self] {
                            guard let range = timeRange else { continue }
                            let s = range.start.seconds
                            let e = s + range.duration.seconds
                            if s < startTime || startTime == 0 { startTime = s }
                            if e > endTime { endTime = e }
                        }
                        await collector.add(text: text, start: startTime, end: endTime)
                    }
                }
            } catch {
                // 流结束
            }
        }

        // 8. 读取音频并喂入
        let startTime = CFAbsoluteTimeGetCurrent()

        // 创建格式转换器（如需要）
        let converter: AVAudioConverter?
        if fileFormat.sampleRate != analyzerFormat.sampleRate
            || fileFormat.commonFormat != analyzerFormat.commonFormat
            || fileFormat.channelCount != analyzerFormat.channelCount {
            converter = AVAudioConverter(from: fileFormat, to: analyzerFormat)
        } else {
            converter = nil
        }

        // 分块读取（模拟实时流，每块 100ms）
        let chunkFrames = AVAudioFrameCount(fileFormat.sampleRate * 0.1)
        var framesRead: AVAudioFrameCount = 0

        while framesRead < frameCount {
            let remaining = frameCount - framesRead
            let thisChunk = min(chunkFrames, remaining)

            guard let readBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: thisChunk) else { break }
            try audioFile.read(into: readBuffer)
            framesRead += readBuffer.frameLength

            // 格式转换
            let outputBuffer: AVAudioPCMBuffer
            if let converter {
                guard let converted = convertBuffer(readBuffer, converter: converter, targetFormat: analyzerFormat) else {
                    continue
                }
                outputBuffer = converted
            } else {
                outputBuffer = readBuffer
            }

            // 喂入 SpeechAnalyzer
            let input = AnalyzerInput(buffer: outputBuffer)
            inputBuilder.yield(input)
        }

        // 9. 结束输入
        inputBuilder.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        // 等待结果处理完成
        await resultTask.value

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        // 10. 拼接最终文本
        let segments = await collector.segments
        let finalTexts = await collector.texts
        let hypothesis = finalTexts.joined()

        return TranscriptionResult(
            audioPath: wavPath,
            durationSeconds: duration,
            locale: locale,
            hypothesis: hypothesis,
            processingTime: processingTime,
            segments: segments
        )
    }

    // MARK: - 音频格式转换

    static func convertBuffer(_ input: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(input.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        var error: NSError?
        let inputRef = input
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputRef
        }

        return error == nil ? outputBuffer : nil
    }

    // MARK: - JSON 输出

    static func formatResult(_ result: TranscriptionResult) -> [String: Any] {
        var json: [String: Any] = [
            "id": result.id,
            "audio": result.audioPath,
            "duration_s": round(result.durationSeconds * 100) / 100,
            "locale": result.locale,
            "hypothesis": result.hypothesis,
            "processing_time_s": round(result.processingTime * 100) / 100,
            "rtfx": round(result.durationSeconds / result.processingTime * 10) / 10,
            "segments": result.segments.map { seg in
                [
                    "text": seg.text,
                    "start": round(seg.start * 100) / 100,
                    "end": round(seg.end * 100) / 100,
                    "is_final": seg.isFinal
                ] as [String: Any]
            }
        ]
        if let ref = result.reference {
            json["reference"] = ref
        }
        return json
    }

    // MARK: - 工具

    static func parseArg(_ args: [String], key: String) -> String? {
        guard let idx = args.firstIndex(of: key), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}

// MARK: - 结果收集 Actor（Swift 6 并发安全）

actor ResultCollector {
    var segments: [(text: String, start: Double, end: Double, isFinal: Bool)] = []
    var texts: [String] = []

    func add(text: String, start: Double, end: Double) {
        segments.append((text: text, start: start, end: end, isFinal: true))
        texts.append(text)
    }
}
