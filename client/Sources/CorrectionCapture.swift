import Foundation
import AppKit
import ApplicationServices

/// Monitors user edits after text injection to capture corrections.
///
/// Two capture strategies, auto-selected per session:
/// 1. AX observer — registers kAXValueChangedNotification on the text element,
///    tracks every edit in real-time. Covers most standard and Electron apps.
/// 2. Edit detection + clipboard snapshot — for terminal/Electron apps where AX
///    is unavailable. Monitors backspace to detect edits, then reads final text
///    via clipboard (Cmd+A → Cmd+C) only when a correction actually happened.
///
/// Data flow: TextInjector inserts -> CorrectionCapture monitors ->
/// CorrectionStore persists -> AlternativeSwap learns
final class CorrectionCapture {
    private var isMonitoring = false
    private var insertedText: String = ""
    private var rawText: String = ""
    private var targetApp: AppIdentity?
    private var profile: CaptureProfile?
    private var captureTimer: Timer?
    private var eventMonitor: Any?

    // AX observation state
    private var axObserver: AXObserver?
    private var trackedElement: AXUIElement?
    private var latestText: String?
    private var previousText: String?

    // Edit detection state (terminal/Electron fallback)
    private var useEditDetectionMode = false
    private var hasEdited = false

    // Terminal prompt detection (for reading command line from AX buffer)
    private var terminalPromptPrefix: String?
    private var promptRetryTimer: Timer?

    // Injection timestamp (for Claude history reader fallback)
    private var injectionTime: Date?

    // MARK: - Public API

    /// Start monitoring for user corrections after text injection.
    func startWindow(insertedText: String, rawText: String, app: AppIdentity) {
        // Cancel any in-progress capture from a previous session.
        if isMonitoring {
            endCapture(reason: "new session started")
        }

        self.insertedText = insertedText
        self.rawText = rawText
        self.targetApp = app
        self.profile = CaptureProfile.profile(for: app.bundleID)

        guard profile?.enabled == true else {
            DebugLog.log(.correction, "Capture disabled for \(app.bundleID)")
            return
        }

        isMonitoring = true
        injectionTime = Date()

        // Auto-detect capture strategy.
        let appElement = AXUIElementCreateApplication(app.processID)
        if let textElement = findTextElement(from: appElement) {
            let currentValue = readAXValue(from: textElement) ?? ""
            let ratio = Double(currentValue.count) / max(Double(insertedText.count), 1)

            if ratio > 5.0 {
                // AX returns full buffer (terminal-like app), use edit detection mode.
                useEditDetectionMode = true
                detectTerminalPrompt(from: appElement)
                // Write pending record for shell hook to pick up (bypasses AX limitation).
                TerminalCorrectionBridge.writePending(insertedText: insertedText, rawText: rawText, app: app)
                DebugLog.log(.correction, "Capture started (edit-detect): \"\(insertedText)\" in \(app.appName) [AX buffer \(currentValue.count) chars]")
            } else {
                setupAXObserver(element: textElement, pid: app.processID)
                latestText = currentValue
                DebugLog.log(.correction, "Capture started (AX): \"\(insertedText)\" in \(app.appName), signal=\(profile!.submitSignal.rawValue)")
            }
        } else {
            // No AX text element found at all — edit detection mode.
            useEditDetectionMode = true
            // Also write pending for shell hook if this is a terminal app.
            if TextInjector.isTerminalApp(app.bundleID) {
                TerminalCorrectionBridge.writePending(insertedText: insertedText, rawText: rawText, app: app)
            }
            DebugLog.log(.correction, "Capture started (edit-detect): \"\(insertedText)\" in \(app.appName) [no AX element]")
        }

        startEventMonitoring()

        captureTimer = Timer.scheduledTimer(
            withTimeInterval: profile?.captureTimeout ?? 30,
            repeats: false
        ) { [weak self] _ in
            self?.endCapture(reason: "timeout")
        }
    }

    /// Stop monitoring without capturing (e.g. new session started).
    func cancel() {
        endCapture(reason: "cancelled")
    }

    // MARK: - AX Deep Traversal

    /// Find the editable text element starting from the app's focused element.
    /// If the focused element itself has kAXValueAttribute, use it directly.
    /// Otherwise, traverse children looking for AXTextArea / AXTextField.
    private func findTextElement(from appElement: AXUIElement) -> AXUIElement? {
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success else { return nil }

        let focused = focusedElement as! AXUIElement

        // Direct check: focused element has a string value.
        if readAXValue(from: focused) != nil {
            return focused
        }

        // Traverse children to find the actual text element (Electron wrappers, etc).
        return searchTextElement(in: focused, maxDepth: 5)
    }

    /// BFS through AX children, prioritizing text roles.
    private func searchTextElement(in element: AXUIElement, maxDepth: Int) -> AXUIElement? {
        guard maxDepth > 0 else { return nil }

        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &children
        ) == .success, let childArray = children as? [AXUIElement] else { return nil }

        // First pass: look for elements with text roles that have a value.
        for child in childArray {
            var role: AnyObject?
            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success,
               let roleStr = role as? String,
               roleStr == "AXTextArea" || roleStr == "AXTextField" {
                if readAXValue(from: child) != nil {
                    return child
                }
            }
        }

        // Second pass: recurse into all children.
        for child in childArray {
            if let found = searchTextElement(in: child, maxDepth: maxDepth - 1) {
                return found
            }
        }

        return nil
    }

    private func readAXValue(from element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value
        ) == .success else { return nil }
        return value as? String
    }

    // MARK: - Terminal Prompt Detection

    /// At injection time, find the inserted text in the AX buffer and save the prompt prefix.
    /// Retries after a delay to allow async paste to complete.
    private func detectTerminalPrompt(from appElement: AXUIElement) {
        // Try immediately first (covers fast/synchronous injection).
        if tryDetectPrompt(from: appElement) { return }

        // Paste via Edit→Paste is async; retry after a short delay using Timer.
        promptRetryTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self, self.isMonitoring, let app = self.targetApp else { return }
            let retryElement = AXUIElementCreateApplication(app.processID)
            if self.tryDetectPrompt(from: retryElement) {
                DebugLog.log(.correction, "Prompt detected on retry: \"\(self.terminalPromptPrefix ?? "")\"")
            } else {
                DebugLog.log(.correction, "Prompt detection failed after retry")
            }
        }
    }

    private func tryDetectPrompt(from appElement: AXUIElement) -> Bool {
        guard let textElement = findTextElement(from: appElement),
              let buffer = readAXValue(from: textElement) else { return false }

        // Search for the full inserted text in the buffer.
        if buffer.contains(insertedText) {
            let lines = buffer.components(separatedBy: "\n")
            for line in lines.reversed() {
                if let range = line.range(of: insertedText) {
                    terminalPromptPrefix = String(line[..<range.lowerBound])
                    return true
                }
            }
        }

        // Try with a shorter prefix (TUI might wrap long text across lines).
        let searchLen = min(8, insertedText.count)
        let shortPrefix = String(insertedText.prefix(searchLen))
        if buffer.contains(shortPrefix) {
            let lines = buffer.components(separatedBy: "\n")
            for line in lines.reversed() {
                if let range = line.range(of: shortPrefix) {
                    terminalPromptPrefix = String(line[..<range.lowerBound])
                    return true
                }
            }
        }

        return false
    }

    /// Read the user's edited text from the terminal AX buffer.
    ///
    /// Strategy: search the buffer (from the end) for a line that shares a
    /// significant prefix with the inserted text. This works for both shell
    /// prompts and TUI apps like Claude Code, because the injected text
    /// appears somewhere in the buffer and the user edits it in-place.
    private func readTerminalEditedText() -> String? {
        guard let app = targetApp else { return nil }
        let appElement = AXUIElementCreateApplication(app.processID)
        guard let textElement = findTextElement(from: appElement),
              let buffer = readAXValue(from: textElement) else { return nil }

        // If we have a prompt prefix, use it (most reliable).
        if let prefix = terminalPromptPrefix {
            let lines = buffer.components(separatedBy: "\n")
            for line in lines.reversed() {
                guard line.hasPrefix(prefix) else { continue }
                let afterPrompt = String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !afterPrompt.isEmpty {
                    return afterPrompt
                }
            }
        }

        // Fallback: search for a line that starts with the same prefix as insertedText.
        let searchPrefix = String(insertedText.prefix(min(8, insertedText.count)))
        guard !searchPrefix.isEmpty else { return nil }

        let allLines = buffer.components(separatedBy: "\n")
        for line in allLines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Check if this line contains our text (or a prefix of it).
            if trimmed.contains(searchPrefix) {
                // Extract the portion starting from our text's prefix.
                if let range = trimmed.range(of: searchPrefix) {
                    let candidate = String(trimmed[range.lowerBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // Sanity check: candidate should be similar length to inserted text.
                    let ratio = Double(candidate.count) / max(Double(insertedText.count), 1)
                    if ratio > 0.5 && ratio < 3.0 {
                        return candidate
                    }
                }
            }
        }

        return nil
    }

    // MARK: - AX Observer

    private func setupAXObserver(element: AXUIElement, pid: pid_t) {
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let capture = Unmanaged<CorrectionCapture>.fromOpaque(refcon).takeUnretainedValue()
            capture.handleAXValueChanged(element)
        }

        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success,
              let observer else {
            DebugLog.log(.correction, "Failed to create AX observer for pid \(pid)")
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        self.axObserver = observer
        self.trackedElement = element
    }

    private func handleAXValueChanged(_ element: AXUIElement) {
        let newText = readAXValue(from: element)
        // Keep previous non-empty text (guards against chat apps clearing field on send).
        if let current = latestText, !current.isEmpty {
            previousText = current
        }
        latestText = newText
        DebugLog.log(.correction, "AX value changed: \"\(newText ?? "<nil>")\"")
    }

    // MARK: - Event Monitoring

    private func startEventMonitoring() {
        guard let profile else { return }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        if profile.submitSignal == .focusChange {
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(appDidDeactivate(_:)),
                name: NSWorkspace.didDeactivateApplicationNotification,
                object: nil
            )
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        // Edit detection: track backspace in non-AX mode.
        if useEditDetectionMode && !event.isARepeat && event.keyCode == 51 {
            hasEdited = true
        }

        let isEnter = event.keyCode == 36

        // Edit detection mode: Enter triggers capture only if user edited.
        if useEditDetectionMode && isEnter && hasEdited {
            captureAndCompare()
            return
        }

        // Normal submit signal detection (AX mode).
        guard let profile else { return }
        let isCmdHeld = event.modifierFlags.contains(.command)

        switch profile.submitSignal {
        case .enter:
            if isEnter && !isCmdHeld { captureAndCompare() }
        case .cmdEnter:
            if isEnter && isCmdHeld { captureAndCompare() }
        case .focusChange, .none:
            break
        }
    }

    // MARK: - Clipboard Snapshot

    /// Read the current text field content via clipboard snapshot.
    /// Only called when a correction is detected (hasEdited = true).
    /// Steps: save clipboard → Cmd+A → Cmd+C → read → restore clipboard → deselect.
    private func readViaClipboard() -> String {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        Self.simulateKeyPress(keyCode: 0, flags: .maskCommand)   // Cmd+A
        Thread.sleep(forTimeInterval: 0.05)
        Self.simulateKeyPress(keyCode: 8, flags: .maskCommand)   // Cmd+C
        Thread.sleep(forTimeInterval: 0.05)

        let captured = pasteboard.string(forType: .string) ?? ""

        // Restore original clipboard.
        pasteboard.clearContents()
        if let saved {
            pasteboard.setString(saved, forType: .string)
        }

        // Deselect: move cursor to end.
        Self.simulateKeyPress(keyCode: 124, flags: .maskCommand) // Cmd+Right
        Thread.sleep(forTimeInterval: 0.02)

        return captured
    }

    private static func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Capture & Compare

    @objc private func appDidDeactivate(_ notification: Notification) {
        guard let deactivatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              deactivatedApp.processIdentifier == targetApp?.processID else { return }
        captureAndCompare()
    }

    private func captureAndCompare() {
        guard isMonitoring, let app = targetApp else { return }

        DebugLog.log(.correction, "Submit signal triggered in \(app.appName)")

        let finalText: String
        if useEditDetectionMode {
            if let terminalText = readTerminalEditedText() {
                // Terminal: found the edited text in AX buffer.
                finalText = terminalText
            } else if targetApp.map({ TextInjector.isTerminalApp($0.bundleID) }) == true {
                // Terminal but can't read AX buffer — try Claude history fallback.
                DebugLog.log(.correction, "Terminal AX read failed, trying Claude history fallback...")
                tryCaptureFromClaudeHistory()
                return
            } else {
                // Non-terminal (WeChat, Claude app, etc): use clipboard snapshot.
                finalText = readViaClipboard()
            }
        } else {
            // Prefer latest tracked value; if empty (chat app cleared on send), use previous.
            // Last resort: direct read from tracked element.
            let axText = latestText.flatMap({ $0.isEmpty ? previousText : $0 })
                         ?? previousText
                         ?? trackedElement.flatMap({ readAXValue(from: $0) })
            finalText = axText ?? ""
        }

        guard !finalText.isEmpty else {
            DebugLog.log(.correction, "Final text is empty, skipping capture")
            endCapture(reason: "empty final text")
            return
        }

        // Compare similarity.
        let similarity = Self.stringSimilarity(insertedText, finalText)
        let lengthRatio = Double(finalText.count) / max(Double(insertedText.count), 1)

        DebugLog.log(.correction, "Compare: inserted=\"\(insertedText)\" final=\"\(finalText)\" similarity=\(String(format: "%.2f", similarity)) lengthRatio=\(String(format: "%.2f", lengthRatio))")

        // Only capture if within reasonable bounds (actual correction, not rewrite).
        if similarity > 0.3 && similarity < 1.0 && lengthRatio > 0.5 && lengthRatio < 2.0 {
            let quality = similarity * min(lengthRatio, 1.0 / lengthRatio)

            let entry = CorrectionEntry(
                id: UUID().uuidString,
                timestamp: Date(),
                rawText: rawText,
                insertedText: insertedText,
                userFinalText: finalText,
                quality: quality,
                appBundleID: app.bundleID,
                appName: app.appName,
                metadata: [
                    "captureMode": useEditDetectionMode ? "clipboard" : "ax"
                ]
            )
            CorrectionStore.shared.save(entry)
            DebugLog.log(.correction, "Correction saved! quality=\(String(format: "%.2f", quality)) mode=\(useEditDetectionMode ? "clipboard" : "ax")")
        } else if similarity >= 1.0 {
            DebugLog.log(.correction, "Text unchanged, no correction needed")
        } else {
            DebugLog.log(.correction, "Outside capture bounds (sim=\(String(format: "%.2f", similarity)) ratio=\(String(format: "%.2f", lengthRatio))), skipping")
        }

        endCapture(reason: "captured")
    }

    /// Normalized edit distance similarity (1 - levenshtein/maxLen).
    /// More accurate than character-set Jaccard for correction detection,
    /// since it preserves character order and position.
    private static func stringSimilarity(_ a: String, _ b: String) -> Double {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        guard m > 0 || n > 0 else { return 1.0 }

        // Optimize: if lengths differ drastically, skip full DP.
        let maxLen = max(m, n)
        if maxLen > 0 && Double(min(m, n)) / Double(maxLen) < 0.3 { return 0.0 }

        // Space-optimized Levenshtein (two rows).
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                if aChars[i - 1] == bChars[j - 1] {
                    curr[j] = prev[j - 1]
                } else {
                    curr[j] = 1 + min(prev[j], curr[j - 1], prev[j - 1])
                }
            }
            swap(&prev, &curr)
        }
        return 1.0 - Double(prev[n]) / Double(maxLen)
    }

    // MARK: - Claude History Fallback

    /// When terminal AX read fails, wait briefly then read Claude Code's session
    /// history to find the user's final submitted text.
    private func tryCaptureFromClaudeHistory() {
        guard let app = targetApp, let injection = injectionTime else {
            endCapture(reason: "terminal-ax-failed")
            return
        }

        // Save state needed for the delayed callback.
        let savedInsertedText = insertedText
        let savedRawText = rawText
        let savedInjectionTime = injection

        // End the main capture window (release event monitors etc.)
        // but do the history check after a delay.
        endCapture(reason: "terminal-ax-fallback-pending")

        // Delay 500ms to let Claude Code write the user message to its session log.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            guard let userText = ClaudeHistoryReader.lastUserMessage(after: savedInjectionTime) else {
                DebugLog.log(.correction, "Claude history fallback: no matching message found")
                return
            }

            let similarity = Self.stringSimilarity(savedInsertedText, userText)
            let lengthRatio = Double(userText.count) / max(Double(savedInsertedText.count), 1)

            DebugLog.log(.correction, "Claude history compare: inserted=\"\(savedInsertedText.prefix(40))\" final=\"\(userText.prefix(40))\" similarity=\(String(format: "%.2f", similarity)) lengthRatio=\(String(format: "%.2f", lengthRatio))")

            if similarity > 0.3 && similarity < 1.0 && lengthRatio > 0.5 && lengthRatio < 2.0 {
                let quality = similarity * min(lengthRatio, 1.0 / lengthRatio)
                let entry = CorrectionEntry(
                    id: UUID().uuidString,
                    timestamp: Date(),
                    rawText: savedRawText,
                    insertedText: savedInsertedText,
                    userFinalText: userText,
                    quality: quality,
                    appBundleID: app.bundleID,
                    appName: app.appName,
                    metadata: ["captureMode": "claude-history"]
                )
                CorrectionStore.shared.save(entry)
                DebugLog.log(.correction, "Correction saved via Claude history! quality=\(String(format: "%.2f", quality))")
            } else if similarity >= 1.0 {
                DebugLog.log(.correction, "Claude history: text unchanged, no correction")
            } else {
                DebugLog.log(.correction, "Claude history: outside capture bounds (sim=\(String(format: "%.2f", similarity)) ratio=\(String(format: "%.2f", lengthRatio)))")
            }
        }
    }

    func endCapture(reason: String) {
        guard isMonitoring else { return }
        DebugLog.log(.correction, "Capture ended: \(reason)")
        isMonitoring = false

        captureTimer?.invalidate()
        captureTimer = nil

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        // Clean up AX observer.
        if let observer = axObserver, let element = trackedElement {
            AXObserverRemoveNotification(observer, element, kAXValueChangedNotification as CFString)
        }
        axObserver = nil
        trackedElement = nil
        latestText = nil
        previousText = nil

        // Clean up edit detection state.
        useEditDetectionMode = false
        hasEdited = false
        terminalPromptPrefix = nil
        promptRetryTimer?.invalidate()
        promptRetryTimer = nil
        injectionTime = nil

        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
