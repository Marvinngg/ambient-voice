import Foundation

/// Result of a full voice pipeline run.
struct PipelineResult {
    let rawText: String
    let l1Text: String
    let injected: Bool
}

/// Orchestrates real-time voice processing:
/// L1 deterministic correction → inject → capture → history.
///
/// L2 (Whisper/Gemini distillation) is offline-only — runs in distill/ scripts,
/// not in the real-time path. This keeps injection latency minimal.
enum VoicePipeline {

    // MARK: - Shared state

    @MainActor private(set) static var correctionCapture: CorrectionCapture?
    @MainActor private(set) static var polishClient: PolishClient?
    @MainActor private(set) static var replacements: [String: String] = [:]

    /// Configure the pipeline with runtime dependencies.
    @MainActor
    static func configure(config: WEConfig, localClient: LocalModelClient) {
        correctionCapture = CorrectionCapture()
        let client = PolishClient(weConfig: config, localClient: localClient)
        polishClient = client
        if client == nil {
            DebugLog.log(.pipeline, "L2 polish disabled: no polish config")
        }
        replacements = config.replacements ?? [:]
    }

    // MARK: - Public API

    /// Run the real-time processing pipeline for a completed voice session.
    ///
    /// Steps:
    /// 1. Import shell corrections (terminal flywheel)
    /// 2. L1 deterministic correction (AlternativeSwap + screen context)
    /// 3. Inject final text into the target application
    /// 4. Start correction capture window
    /// 5. Save session to voice history (with audio path for offline distillation)
    @MainActor @discardableResult
    static func process(
        result: TranscriptionResult,
        appIdentity: AppIdentity,
        screenContext: ScreenContext? = nil,
        audioFilePath: String? = nil
    ) async -> PipelineResult {
        let sessionID = UUID().uuidString
        DebugLog.log(.pipeline, "Pipeline started for session \(sessionID)")

        // Import any corrections from the shell hook before L1 runs
        TerminalCorrectionBridge.importShellCorrections()

        let contextKeywords = screenContext?.keywords ?? []
        if !contextKeywords.isEmpty {
            DebugLog.log(.pipeline, "Screen context: \(contextKeywords.count) keywords")
        }

        // Step 1: L1 deterministic correction
        let correctionHistory = CorrectionStore.shared.loadHistory()
        let l1Result = AlternativeSwap.apply(
            rawText: result.fullText,
            words: result.words,
            correctionHistory: correctionHistory,
            contextKeywords: contextKeywords,
            replacements: replacements
        )
        let l1Text = l1Result.text
        DebugLog.log(.pipeline, "L1: \"\(result.fullText)\" -> \"\(l1Text)\"")

        // Step 2: L2 low-confidence polish (local Qwen3 0.6B)
        // Only sends low-confidence segments to the model, keeps the rest unchanged.
        let finalText: String
        let polishedText: String?
        if let client = polishClient {
            let l2Result = await Self.polishLowConfidence(
                l1WordTexts: l1Result.wordTexts,
                words: result.words,
                client: client,
                appBundleID: appIdentity.bundleID,
                contextKeywords: contextKeywords
            )
            finalText = l2Result.text
            polishedText = l2Result.changed ? l2Result.text : nil
            if l2Result.changed {
                DebugLog.log(.pipeline, "L2: \"\(l1Text)\" -> \"\(finalText)\" (\(l2Result.latencyMs)ms, \(l2Result.segmentsPolished) segments)")
            } else {
                DebugLog.log(.pipeline, "L2: no low-confidence segments to polish")
            }
        } else {
            finalText = l1Text
            polishedText = nil
        }

        // Step 3: Inject into target app
        let injected: Bool
        if !finalText.isEmpty {
            TextInjector.insert(finalText, into: appIdentity)
            injected = true
            DebugLog.log(.pipeline, "Injected \(finalText.count) chars into \(appIdentity.appName)")
        } else {
            injected = false
            DebugLog.log(.pipeline, "Skipped injection: empty text")
        }

        // Step 4: Start correction capture
        if injected {
            correctionCapture?.startWindow(
                insertedText: finalText,
                rawText: result.fullText,
                app: appIdentity
            )
        }

        // Step 5: Save to voice history (audioFilePath preserved for offline distillation)
        let historyEntry = VoiceHistoryEntry(
            sessionID: sessionID,
            timestamp: Date(),
            rawText: result.fullText,
            l1Text: l1Text,
            polishedText: polishedText,
            appBundleID: appIdentity.bundleID,
            appName: appIdentity.appName,
            wordCount: result.words.count,
            duration: result.words.last.map { $0.timestamp + $0.duration } ?? 0,
            polished: polishedText != nil,
            audioFilePath: audioFilePath
        )
        VoiceHistory.shared.save(entry: historyEntry)
        DebugLog.log(.pipeline, "Session \(sessionID) saved to history")

        return PipelineResult(
            rawText: result.fullText,
            l1Text: l1Text,
            injected: injected
        )
    }

    // MARK: - Low-Confidence Polish

    private struct L2Result {
        let text: String
        let changed: Bool
        let latencyMs: Int
        let segmentsPolished: Int
    }

    /// Extract low-confidence segments, polish them individually, splice back.
    ///
    /// Groups consecutive low-confidence words into segments, sends each to the
    /// model with surrounding context. High-confidence words are never modified.
    @MainActor
    private static func polishLowConfidence(
        l1WordTexts: [String],
        words: [TranscribedWord],
        client: PolishClient,
        appBundleID: String,
        contextKeywords: [String]
    ) async -> L2Result {
        let l1Text = l1WordTexts.joined()
        guard !words.isEmpty else {
            return L2Result(text: l1Text, changed: false, latencyMs: 0, segmentsPolished: 0)
        }

        let threshold: Float = 0.5
        let start = DispatchTime.now()

        // Find runs of consecutive low-confidence words.
        // Skip words that L1 already replaced (wordText differs from original).
        var segments: [(range: Range<Int>, text: String)] = []
        var i = 0
        while i < words.count {
            let l1Changed = l1WordTexts[i] != words[i].text
            if words[i].confidence < threshold && !l1Changed {
                let runStart = i
                var runText = ""
                while i < words.count && words[i].confidence < threshold
                      && l1WordTexts[i] == words[i].text {
                    runText += words[i].text
                    i += 1
                }
                segments.append((range: runStart..<i, text: runText))
            } else {
                i += 1
            }
        }

        guard !segments.isEmpty else {
            return L2Result(text: l1Text, changed: false, latencyMs: 0, segmentsPolished: 0)
        }

        // Polish each low-confidence segment with context.
        var polishResults: [(range: Range<Int>, original: String, polished: String)] = []

        for segment in segments {
            // Build context using L1-corrected word texts.
            let ctxBefore = l1WordTexts[max(0, segment.range.lowerBound - 3)..<segment.range.lowerBound]
                .joined()
            let ctxAfter = l1WordTexts[segment.range.upperBound..<min(words.count, segment.range.upperBound + 3)]
                .joined()

            let prompt = "前文:\(ctxBefore)\n需要修正:\(segment.text)\n后文:\(ctxAfter)"

            let result = await client.polish(
                PolishClient.PolishRequest(
                    text: prompt,
                    wordConfidences: [],
                    appBundleID: appBundleID,
                    screenKeywords: contextKeywords
                )
            )

            let polished = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.backend != nil && !polished.isEmpty && polished != segment.text {
                polishResults.append((range: segment.range, original: segment.text, polished: polished))
            }
        }

        guard !polishResults.isEmpty else {
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            return L2Result(text: l1Text, changed: false, latencyMs: elapsed, segmentsPolished: 0)
        }

        // Rebuild text using L1-corrected word texts, replacing polished segments.
        var parts: [String] = []
        var wi = 0
        for rep in polishResults {
            // Append L1-corrected words before this segment.
            while wi < rep.range.lowerBound {
                parts.append(l1WordTexts[wi])
                wi += 1
            }
            parts.append(rep.polished)
            DebugLog.log(.pipeline, "L2 segment: \"\(rep.original)\" -> \"\(rep.polished)\"")
            wi = rep.range.upperBound
        }
        // Append remaining L1-corrected words.
        while wi < words.count {
            parts.append(l1WordTexts[wi])
            wi += 1
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        return L2Result(
            text: parts.joined(),
            changed: true,
            latencyMs: elapsed,
            segmentsPolished: polishResults.count
        )
    }
}
