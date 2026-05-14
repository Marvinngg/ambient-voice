@preconcurrency import AVFoundation
import Speech

/// 截断测试：模拟 VoiceSession 的流式输入 + stop() 逻辑
/// 验证 SA 是否在 stop 流程中丢失尾部内容
///
/// 用法: WE --test-truncation <wav-file> [--locale zh-CN]
///
/// 测试流程：
/// 1. 读取 WAV 文件，按 20ms 一块切成小 buffer（模拟 AVCaptureSession 的实时输入）
/// 2. 通过 AsyncStream 喂给 SpeechAnalyzer（和 VoiceSession 完全一样的路径）
/// 3. 所有 buffer 发送完后，执行和 VoiceSession.stop() 一样的关闭逻辑
/// 4. 记录每一步的时间戳和 SA 状态，输出诊断报告
enum TruncationTest {
    private static let outputURL = WEDataDir.url.appendingPathComponent("truncation-test.log")
    nonisolated(unsafe) private static var logHandle: FileHandle?

    private static func log(_ msg: String) {
        let line = msg + "\n"
        print(msg)
        fflush(stdout)
        if let data = line.data(using: .utf8) {
            logHandle?.write(data)
        }
    }

    @MainActor
    static func run() async {
        // 初始化日志文件
        WEDataDir.ensureExists()
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: outputURL)

        let args = CommandLine.arguments

        guard let idx = args.firstIndex(of: "--test-truncation"), idx + 1 < args.count else {
            log("Usage: WE --test-truncation <wav-file> [--locale zh-CN]")
            return
        }

        let wavPath = args[idx + 1]
        let locale = Locale(identifier: MeetingBenchmark.parseArg(args, key: "--locale") ?? "zh-CN")

        guard FileManager.default.fileExists(atPath: wavPath) else {
            log("Error: file not found: \(wavPath)")
            return
        }

        log("=== 截断测试 ===")
        log("Audio: \(wavPath)")
        log("Locale: \(locale.identifier(.bcp47))")
        log("")

        do {
            // 读取音频文件
            let fileURL = URL(fileURLWithPath: wavPath)
            let audioFile = try AVAudioFile(forReading: fileURL)
            let fileFormat = audioFile.processingFormat
            let totalFrames = AVAudioFrameCount(audioFile.length)
            let audioDuration = Double(totalFrames) / fileFormat.sampleRate
            log("Audio: \(String(format: "%.1f", audioDuration))s, \(Int(fileFormat.sampleRate))Hz, \(fileFormat.channelCount)ch")

            // 读取完整音频到 buffer
            let fullBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: totalFrames)!
            try audioFile.read(into: fullBuffer)

            // 配置 SA（和 VoiceSession 一样）
            let supportedLocales = await SpeechTranscriber.supportedLocales
            let bestLocale = supportedLocales.first(where: { $0.identifier(.bcp47).hasPrefix("zh") }) ?? locale

            let transcriber = SpeechTranscriber(
                locale: bestLocale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .alternativeTranscriptions],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            )

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            log("SA format: \(analyzerFormat as Any)")

            // 格式转换器（如果需要）
            var converter: AVAudioConverter? = nil
            if let targetFormat = analyzerFormat,
               fileFormat.sampleRate != targetFormat.sampleRate
                || fileFormat.commonFormat != targetFormat.commonFormat {
                converter = AVAudioConverter(from: fileFormat, to: targetFormat)
                log("Converter: \(fileFormat) → \(targetFormat)")
            }

            // 创建 AsyncStream（和 VoiceSession 一样）
            let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

            // 启动 SA
            try await analyzer.start(inputSequence: inputSequence)
            log("SA started")

            // 结果收集
            var finalizedText = ""
            var volatileText = ""
            var finalCount = 0
            var volatileCount = 0
            var lastFinalTime: TimeInterval = 0

            let resultTask = Task {
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)

                        if result.isFinal {
                            finalizedText += text
                            volatileText = ""
                            finalCount += 1

                            // 提取时间范围
                            typealias TimeKey = AttributeScopes.SpeechAttributes.TimeRangeAttribute
                            var maxEnd: TimeInterval = 0
                            for (timeRange, _) in result.text.runs[TimeKey.self] {
                                if let range = timeRange {
                                    let end = range.start.seconds + range.duration.seconds
                                    if end > maxEnd { maxEnd = end }
                                }
                            }
                            lastFinalTime = max(lastFinalTime, maxEnd)
                            log("  [FINAL #\(finalCount)] \(String(format: "%.1f", maxEnd))s: \(text.prefix(50))...")
                        } else {
                            volatileText = text
                            volatileCount += 1
                        }
                    }
                    log("  [RESULT STREAM ENDED NORMALLY]")
                } catch is CancellationError {
                    log("  [RESULT STREAM CANCELLED]")
                } catch {
                    log("  [RESULT STREAM ERROR: \(error)]")
                }
            }

            // === 模拟流式输入：按 20ms 一块切割并 yield ===
            // 注意：feed 在 nonisolated Task 里执行，避免阻塞 MainActor
            let chunkDuration: TimeInterval = 0.02 // 20ms，模拟 AVCaptureSession
            let chunkFrames = AVAudioFrameCount(fileFormat.sampleRate * chunkDuration)
            let feedStartTime = CFAbsoluteTimeGetCurrent()

            let feedResult = await Task.detached { () -> (Int, TimeInterval) in
                var offset: AVAudioFrameCount = 0
                var yieldCount = 0

                while offset < totalFrames {
                    let remaining = totalFrames - offset
                    let framesToRead = min(chunkFrames, remaining)

                    guard let chunk = fullBuffer.slice(from: offset, length: framesToRead) else { break }

                    let outputChunk: AVAudioPCMBuffer
                    if let converter, let targetFormat = analyzerFormat {
                        let ratio = targetFormat.sampleRate / fileFormat.sampleRate
                        let outCapacity = AVAudioFrameCount(Double(framesToRead) * ratio) + 1
                        let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity)!
                        var error: NSError?
                        let consumed = Box(false)
                        converter.convert(to: outBuf, error: &error) { _, outStatus in
                            if consumed.value { outStatus.pointee = .noDataNow; return nil }
                            consumed.value = true
                            outStatus.pointee = .haveData
                            return chunk
                        }
                        outputChunk = outBuf
                    } else {
                        outputChunk = chunk
                    }

                    let input = AnalyzerInput(buffer: outputChunk)
                    inputBuilder.yield(input)
                    yieldCount += 1

                    offset += framesToRead
                }

                let yieldedDuration = Double(totalFrames) / fileFormat.sampleRate
                return (yieldCount, yieldedDuration)
            }.value

            let yieldCount = feedResult.0
            let yieldedDuration = feedResult.1
            let feedTime = CFAbsoluteTimeGetCurrent() - feedStartTime
            log("")
            log("=== Feed 完成 ===")
            log("Yielded: \(yieldCount) chunks, \(String(format: "%.1f", yieldedDuration))s audio in \(String(format: "%.2f", feedTime))s")
            log("Feed speed: \(String(format: "%.1f", yieldedDuration / feedTime))x realtime")
            log("")

            // === 模拟 VoiceSession.stop() 的关闭逻辑 ===
            log("=== 模拟 stop() 流程 ===")

            // Step 1: finish input stream
            let t1 = CFAbsoluteTimeGetCurrent()
            inputBuilder.finish()
            log("[\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t1))s] inputBuilder.finish()")

            // Step 2: finalize with 5s timeout (和 VoiceSession 一样)
            let t2 = CFAbsoluteTimeGetCurrent()
            do {
                try await withThrowingTimeout(seconds: 5) {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }
                log("[\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t2))s] finalizeAndFinishThroughEndOfInput() completed")
            } catch {
                log("[\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t2))s] finalizeAndFinishThroughEndOfInput() TIMEOUT/ERROR: \(error)")
            }

            // Step 3: sleep 500ms (和 VoiceSession 一样)
            let t3 = CFAbsoluteTimeGetCurrent()
            try? await Task.sleep(for: .milliseconds(500))
            log("[\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t3))s] sleep(500ms)")

            // Step 4: cancel resultTask (和 VoiceSession 一样)
            let t4 = CFAbsoluteTimeGetCurrent()
            resultTask.cancel()
            log("[\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t4))s] resultTask.cancel()")

            // 等 resultTask 结束
            await resultTask.value

            // === 输出诊断报告 ===
            let fullText = finalizedText + volatileText
            log("")
            log(String(repeating: "=", count: 60))
            log("截断测试报告")
            log(String(repeating: "=", count: 60))
            log("音频总时长:        \(String(format: "%.1f", audioDuration))s")
            log("SA 最后 final 时间: \(String(format: "%.1f", lastFinalTime))s")
            log("尾部 gap:          \(String(format: "%.1f", audioDuration - lastFinalTime))s")
            log("")
            log("Final segments:    \(finalCount)")
            log("Volatile updates:  \(volatileCount)")
            log("finalizedText:     \(finalizedText.count) 字")
            log("volatileText:      \(volatileText.count) 字")
            log("fullText:          \(fullText.count) 字")
            log("")
            log("=== finalizedText（前200字）===")
            log(String(finalizedText.prefix(200)))
            log("")
            log("=== volatileText ===")
            log(volatileText.isEmpty ? "(空)" : volatileText)
            log("")
            log("=== fullText 最后100字 ===")
            log(String(fullText.suffix(100)))
            log("")

            // 如果有 ground truth 文件，对比
            let gtPath = wavPath.replacingOccurrences(of: ".wav", with: ".txt")
            if FileManager.default.fileExists(atPath: gtPath) {
                let gt = try String(contentsOfFile: gtPath, encoding: .utf8)
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: " ", with: "")
                let fullClean = fullText.replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "，", with: "")
                    .replacingOccurrences(of: "。", with: "")

                log("=== Ground Truth 对比 ===")
                log("GT 字数:   \(gt.count)")
                log("SA 字数:   \(fullClean.count)")
                log("")
                log("GT 最后50字:  \(String(gt.suffix(50)))")
                log("SA 最后50字:  \(String(fullClean.suffix(50)))")
                log("")

                // 检查 GT 的最后 20 个字是否出现在 SA 输出中
                let gtTail = String(gt.suffix(20))
                let found = fullClean.contains(gtTail)
                log("GT 尾部20字「\(gtTail)」")
                log("在 SA 输出中: \(found ? "✓ 找到（未截断）" : "✗ 未找到（可能截断）")")
            }

        } catch {
            log("Error: \(error)")
        }
    }
}

// MARK: - AVAudioPCMBuffer slice helper

extension AVAudioPCMBuffer {
    /// 从指定偏移截取一段 buffer
    func slice(from startFrame: AVAudioFrameCount, length: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard startFrame + length <= frameLength else { return nil }
        guard let newBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else { return nil }
        newBuf.frameLength = length

        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        let srcOffset = Int(startFrame) * Int(bytesPerFrame)
        let byteCount = Int(length) * Int(bytesPerFrame)

        guard let srcData = audioBufferList.pointee.mBuffers.mData,
              let dstData = newBuf.mutableAudioBufferList.pointee.mBuffers.mData else {
            return nil
        }

        dstData.copyMemory(from: srcData.advanced(by: srcOffset), byteCount: byteCount)
        return newBuf
    }
}
