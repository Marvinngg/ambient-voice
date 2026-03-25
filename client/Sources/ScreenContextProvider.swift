import AppKit
import ScreenCaptureKit
import Vision

/// G3: 屏幕上下文感知
/// 截取焦点元素附近区域 → Vision OCR → 提取上下文关键词
/// 截取策略：以焦点元素位置为中心截取 800×600 区域，而非整个窗口
@MainActor
final class ScreenContextProvider {
    static let shared = ScreenContextProvider()

    /// 截取区域大小（逻辑像素，Retina 下实际翻倍）
    /// 800×600 约覆盖光标上下 20-30 行文字
    private let captureWidth: CGFloat = 800
    private let captureHeight: CGFloat = 600

    struct ScreenContext: Sendable {
        let text: String                // OCR 全文
        let contextualWords: [String]   // 注入 SA 的关键词
        let timestamp: Date
    }

    /// 截取焦点元素附近区域并 OCR
    func capture(for app: AppIdentity?) async -> ScreenContext? {
        guard let image = await captureNearFocus(for: app) else {
            Logger.log("Screen", "Screenshot failed for \(app?.bundleID ?? "nil")")
            return nil
        }

        let text = await recognizeText(in: image)
        guard !text.isEmpty else {
            Logger.log("Screen", "OCR empty")
            return nil
        }

        let words = extractContextualWords(from: text)
        Logger.log("Screen", "OCR \(text.count) chars, \(words.count) keywords: \(words.joined(separator: ", "))")
        return ScreenContext(text: text, contextualWords: words, timestamp: Date())
    }

    // MARK: - 焦点附近截取

    /// 获取截图中心点，优先级：AX 焦点位置 → 鼠标位置 → 窗口中心
    private func getFocusCenter(for app: AppIdentity, windowFrame: CGRect) -> CGPoint {
        // 优先：AX API 获取焦点元素的屏幕位置
        if let axCenter = getAXFocusPosition(pid: app.processID) {
            Logger.log("Screen", "Focus center from AX: (\(Int(axCenter.x)), \(Int(axCenter.y)))")
            return axCenter
        }

        // 备选：鼠标光标位置（通常在用户关注区域附近）
        let mouseLocation = NSEvent.mouseLocation
        // NSEvent.mouseLocation 是左下角原点，转换为左上角原点
        let screenHeight = NSScreen.main?.frame.height ?? 1080
        let mousePoint = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)

        // 检查鼠标是否在目标窗口内
        if windowFrame.contains(CGPoint(x: mouseLocation.x, y: mouseLocation.y)) {
            Logger.log("Screen", "Focus center from mouse: (\(Int(mousePoint.x)), \(Int(mousePoint.y)))")
            return mousePoint
        }

        // 兜底：窗口中心
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        Logger.log("Screen", "Focus center from window center: (\(Int(center.x)), \(Int(center.y)))")
        return center
    }

    /// 通过 AX API 获取焦点元素的屏幕位置
    private func getAXFocusPosition(pid: pid_t) -> CGPoint? {
        let appRef = AXUIElementCreateApplication(pid)
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement else {
            return nil
        }

        // 获取焦点元素的位置
        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXPositionAttribute as CFString, &positionValue) == .success,
              let posRef = positionValue else {
            return nil
        }

        var position = CGPoint.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &position) else {
            return nil
        }

        // 获取焦点元素的大小，用中心点作为焦点中心
        var sizeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let sizeRef = sizeValue {
            var size = CGSize.zero
            if AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) {
                // 返回元素的中心偏上位置（光标通常在输入区域上部）
                return CGPoint(x: position.x + size.width / 2, y: position.y + size.height * 0.3)
            }
        }

        return position
    }

    /// 截取焦点附近区域
    private func captureNearFocus(for app: AppIdentity?) async -> CGImage? {
        guard let app else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )

            guard let window = content.windows.first(where: {
                $0.owningApplication?.processID == app.processID && $0.isOnScreen
            }) else {
                Logger.log("Screen", "No window found for pid \(app.processID)")
                return nil
            }

            let windowFrame = window.frame
            let focusCenter = getFocusCenter(for: app, windowFrame: windowFrame)

            // 计算截取区域（以焦点为中心，captureWidth × captureHeight）
            var captureRect = CGRect(
                x: focusCenter.x - captureWidth / 2,
                y: focusCenter.y - captureHeight / 2,
                width: captureWidth,
                height: captureHeight
            )

            // 约束在窗口范围内
            captureRect = captureRect.intersection(windowFrame)

            // 如果区域太小（焦点在窗口边缘），扩展到至少 400×300
            if captureRect.width < 400 || captureRect.height < 300 {
                // fallback：截整个窗口
                captureRect = windowFrame
                Logger.log("Screen", "Focus region too small, fallback to full window")
            }

            let config = SCStreamConfiguration()
            config.width = Int(captureRect.width * 2)   // Retina
            config.height = Int(captureRect.height * 2)
            config.sourceRect = CGRect(
                x: captureRect.origin.x - windowFrame.origin.x,
                y: captureRect.origin.y - windowFrame.origin.y,
                width: captureRect.width,
                height: captureRect.height
            )
            config.showsCursor = false

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            Logger.log("Screen", "Captured \(Int(captureRect.width))×\(Int(captureRect.height)) near focus (\(Int(focusCenter.x)),\(Int(focusCenter.y)))")
            return image
        } catch {
            Logger.log("Screen", "ScreenCaptureKit error: \(error)")
            return nil
        }
    }

    // MARK: - OCR

    private func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try? handler.perform([request])

                let text = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")

                continuation.resume(returning: text)
            }
        }
    }

    // MARK: - 关键词提取

    /// 从 OCR 文本提取关键词
    /// 截取区域已经是焦点附近，不需要再做"最后 30 行"过滤
    private func extractContextualWords(from text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var keywords = Set<String>()

        for line in lines {
            let words = line.components(separatedBy: .whitespaces)
            for word in words {
                let clean = word.trimmingCharacters(in: .punctuationCharacters)
                guard clean.count >= 2 else { continue }

                // 英文专有名词 / 技术术语（首字母大写）
                if let first = clean.first, first.isUppercase, first.isASCII {
                    keywords.insert(clean)
                }

                // 中文词组（2-8字，非纯数字）
                if let first = clean.first, !first.isASCII, clean.count <= 8,
                   !clean.allSatisfy({ $0.isNumber }) {
                    keywords.insert(clean)
                }
            }
        }

        // Apple 官方建议 contextualStrings 所有 tag 合计不超过 100 个
        return Array(keywords.prefix(100))
    }
}
