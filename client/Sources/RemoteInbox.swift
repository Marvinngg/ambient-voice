import AVFoundation
import Network
import Speech

/// 远程语音接收服务
///
/// 监听 HTTP 端口，接收 Windows 侧 tailscale voice 发来的 WAV 音频。
/// 收到 WAV → 临时文件 → SpeechAnalyzer 文件输入 → VoicePipeline → TextInjector
///
/// 使用 Network.framework (NWListener)，零第三方依赖。
/// 协议极简：POST /transcribe，body 是 WAV 二进制，返回 200。
@MainActor
final class RemoteInbox {
    private var listener: NWListener?
    private let pipeline = VoicePipeline()
    private var isProcessing = false

    /// 当前状态回调（UI 用）
    var onStatusChange: ((Status) -> Void)?

    enum Status: String {
        case listening = "监听中"
        case receiving = "接收中"
        case processing = "识别中"
        case idle = "未启动"
    }

    func start(port: UInt16, authToken: String) {
        guard listener == nil else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            Logger.log("Remote", "Failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async {
                self?.handleConnection(connection, authToken: authToken)
            }
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Logger.log("Remote", "Listening on :\(port)")
            case .failed(let error):
                Logger.log("Remote", "Listener failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: .main)
        onStatusChange?(.listening)
        Logger.log("Remote", "RemoteInbox started on :\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        onStatusChange?(.idle)
        Logger.log("Remote", "RemoteInbox stopped")
    }

    // MARK: - HTTP 连接处理

    // 每个 HTTP 连接的解析状态。Connection-scoped，单连接独享。
    // @unchecked Sendable：状态只在 NWConnection.receive 的 completion handler
    // 内读写，由 connection.start(queue: .main) 保证总在 main queue 上，与
    // RemoteInbox 的 @MainActor isolation 一致——无真实数据竞争。
    private final class HTTPRequestState: @unchecked Sendable {
        var accumulated = Data()
        var contentLength: Int?
        var headerEndIndex: Int?
    }

    private func handleConnection(_ connection: NWConnection, authToken: String) {
        connection.start(queue: .main)

        // Read data in chunks. Once we have the HTTP headers, parse
        // Content-Length and read exactly that many body bytes.
        // Do NOT wait for connection close (causes deadlock with
        // HTTP clients that keep the connection open for the response).
        let state = HTTPRequestState()
        readMore(connection: connection, state: state, authToken: authToken)
    }

    private func readMore(connection: NWConnection, state: HTTPRequestState, authToken: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) {
            [weak self] data, _, isComplete, error in
            // NWConnection.receive 的 completion 是 @Sendable，但 Network 框架在
            // connection.start(queue: .main) 后会在 main queue 上分发回调，所以这里
            // 用 MainActor.assumeIsolated 同步声明 main actor 隔离（不引入 Task 调度）。
            MainActor.assumeIsolated {
                guard let self else { return }

                if let data {
                    state.accumulated.append(data)
                }

                // Try to find header boundary if not yet found
                if state.headerEndIndex == nil {
                    let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
                    if let range = state.accumulated.range(of: separator) {
                        state.headerEndIndex = range.upperBound
                        // Parse Content-Length from headers
                        let headerData = state.accumulated[state.accumulated.startIndex..<range.lowerBound]
                        if let headerStr = String(data: headerData, encoding: .utf8) {
                            for line in headerStr.components(separatedBy: "\r\n") {
                                if line.lowercased().hasPrefix("content-length:") {
                                    let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                                    state.contentLength = Int(val)
                                }
                            }
                        }
                    }
                }

                // Check if we have all the data we need
                if let hEnd = state.headerEndIndex {
                    let bodyReceived = state.accumulated.count - hEnd
                    let bodyNeeded = state.contentLength ?? 0

                    if bodyReceived >= bodyNeeded || isComplete || error != nil {
                        // All data received — process immediately
                        self.handleFullRequest(state.accumulated, connection: connection, authToken: authToken)
                        return
                    }
                }

                if isComplete || error != nil {
                    self.handleFullRequest(state.accumulated, connection: connection, authToken: authToken)
                    return
                }

                self.readMore(connection: connection, state: state, authToken: authToken)
            }
        }
    }

    private func handleFullRequest(_ data: Data, connection: NWConnection, authToken: String) {
        guard !data.isEmpty else {
            connection.cancel()
            return
        }

        let (headers, body) = RemoteInbox.parseHTTPRequest(data)

        // 验证 token
        if !authToken.isEmpty {
            let auth = headers["authorization"] ?? ""
            if auth != "Bearer \(authToken)" {
                RemoteInbox.sendResponse(connection, status: "401 Unauthorized", body: "unauthorized")
                return
            }
        }

        let requestLine = headers["_request_line"] ?? ""
        guard requestLine.contains("/transcribe"), requestLine.hasPrefix("POST"), !body.isEmpty else {
            RemoteInbox.sendResponse(connection, status: "400 Bad Request", body: "bad request")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            guard !self.isProcessing else {
                RemoteInbox.sendResponse(connection, status: "429 Too Many Requests", body: "busy")
                return
            }

            Logger.log("Remote", "Received WAV: \(body.count) bytes")
            self.onStatusChange?(.receiving)

            await self.processAudio(wavData: body)
            RemoteInbox.sendResponse(connection, status: "200 OK", body: "ok")
        }
    }

    // MARK: - 音频处理（核心链路）

    private func processAudio(wavData: Data) async {
        isProcessing = true
        onStatusChange?(.processing)
        defer {
            isProcessing = false
            onStatusChange?(.listening)
        }

        let tStart = CFAbsoluteTimeGetCurrent()

        // 1. 写临时文件
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let tempURL = WEDataDir.url.appendingPathComponent("audio/remote-\(timestamp).wav")
        do {
            try wavData.write(to: tempURL)
        } catch {
            Logger.log("Remote", "Failed to write temp WAV: \(error)")
            return
        }

        do {
            // 2. 配置 SpeechTranscriber
            guard let locale = await SpeechUtils.findChineseLocale() else {
                Logger.log("Remote", "No Chinese locale available")
                return
            }

            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.transcriptionConfidence]
            )
            try await SpeechUtils.ensureModelInstalled(transcriber: transcriber, locale: locale)

            // 3. 创建 SpeechAnalyzer
            let analyzer = SpeechAnalyzer(modules: [transcriber])

            // 3.5 上下文注入（字典 + OCR），和本地 VoiceSession 路径统一
            let currentApp = AppIdentity.current()
            let polish = RuntimeConfig.shared.polishConfig
            let dictEnabled = polish["context_dictionary_enabled"] as? Bool ?? false
            let dictPath = polish["context_dictionary_path"] as? String
            let ocrEnabled = polish["context_ocr_enabled"] as? Bool ?? false
            let contextWords = await ContextEnhancer.enhance(
                for: currentApp,
                dictionaryEnabled: dictEnabled,
                dictionaryPath: dictPath,
                ocrEnabled: ocrEnabled
            )
            if !contextWords.isEmpty {
                let ctx = AnalysisContext()
                ctx.contextualStrings[.general] = contextWords
                try? await analyzer.setContext(ctx)
                let preview = contextWords.prefix(5).joined(separator: ", ")
                let suffix = contextWords.count > 5 ? "..." : ""
                Logger.log("Remote", "SA context injected \(contextWords.count) terms: [\(preview)\(suffix)]")
            }
            let tCtxDone = CFAbsoluteTimeGetCurrent()
            let ctxMs = Int((tCtxDone - tStart) * 1000)

            // 4. 结果收集
            var fullText = ""
            var allWords: [WordInfo] = []

            let resultTask = Task {
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        if result.isFinal {
                            fullText += text
                            allWords.append(contentsOf: extractWords(from: result.text))
                            Logger.log("Remote", "SA final: \(text.prefix(50))")
                        }
                    }
                } catch {
                    Logger.log("Remote", "Result stream error: \(error)")
                }
            }

            // 5. 文件输入（MeetingSession 已验证的 API）
            let inputFile = try AVAudioFile(forReading: tempURL)
            let audioDuration = Double(inputFile.length) / inputFile.processingFormat.sampleRate
            Logger.log("Remote", "Starting SA from file (\(String(format: "%.1f", audioDuration))s)")
            try await analyzer.start(inputAudioFile: inputFile, finishAfterFile: true)
            await resultTask.value
            let tSADone = CFAbsoluteTimeGetCurrent()
            let saMs = Int((tSADone - tCtxDone) * 1000)

            guard !fullText.isEmpty else {
                Logger.log("Remote", "Empty transcription, skipping pipeline")
                return
            }

            // 6. 构造 TranscriptionResult，走 VoicePipeline
            let transcription = TranscriptionResult(
                fullText: fullText,
                words: allWords,
                audioPath: tempURL.path,
                timestamp: Date()
            )

            Logger.log("Remote", "Transcribed: \(fullText.prefix(80))")

            await pipeline.process(
                transcription: transcription,
                targetApp: AppIdentity.current()
            )

            let totalMs = Int((CFAbsoluteTimeGetCurrent() - tStart) * 1000)
            let pipelineMs = totalMs - ctxMs - saMs
            Logger.log("Remote", "Timing: ctx=\(ctxMs)ms sa=\(saMs)ms pipeline=\(pipelineMs)ms remote_total=\(totalMs)ms (audio=\(String(format: "%.1f", audioDuration))s)")

        } catch {
            Logger.log("Remote", "Processing error: \(error)")
        }
    }

    // MARK: - 词级信息提取（和 VoiceSession 相同）

    private func extractWords(from attrText: AttributedString) -> [WordInfo] {
        var words: [WordInfo] = []
        typealias ConfKey = AttributeScopes.SpeechAttributes.ConfidenceAttribute

        for (confidence, range) in attrText.runs[ConfKey.self] {
            let wordText = String(attrText[range].characters)
            guard !wordText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            words.append(WordInfo(
                text: wordText,
                confidence: Float(confidence ?? 1.0),
                alternatives: [],
                startTime: 0,
                duration: 0
            ))
        }
        return words
    }

    // MARK: - HTTP 解析/响应

    private nonisolated static func parseHTTPRequest(_ data: Data) -> (headers: [String: String], body: Data) {
        // 找 \r\n\r\n 分隔 header 和 body
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        var headers: [String: String] = [:]
        var body = Data()

        if let range = data.range(of: separator) {
            let headerData = data[data.startIndex..<range.lowerBound]
            body = data[range.upperBound...]

            if let headerStr = String(data: headerData, encoding: .utf8) {
                let lines = headerStr.components(separatedBy: "\r\n")
                if let first = lines.first {
                    headers["_request_line"] = first
                }
                for line in lines.dropFirst() {
                    if let colonIdx = line.firstIndex(of: ":") {
                        let key = line[line.startIndex..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
                        let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                        headers[key] = value
                    }
                }
            }
        }

        return (headers, body)
    }

    private nonisolated static func sendResponse(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
