import AppKit
import ScreenCaptureKit
import Vision

/// G3: 屏幕上下文感知
/// 截取焦点窗口 → Vision OCR → 提取上下文关键词
/// 用途：注入 SA AnalysisContext 提升转写准确率 + L2 润色上下文
@MainActor
final class ScreenContextProvider {
    static let shared = ScreenContextProvider()

    struct ScreenContext: Sendable {
        let text: String                // OCR 全文
        let contextualWords: [String]   // 注入 SA 的关键词
        let timestamp: Date
    }

    /// 截取焦点窗口并 OCR
    /// 不再用 CGPreflightScreenCaptureAccess 做硬门禁，直接尝试 ScreenCaptureKit
    /// 首次调用会触发系统将 app 加入屏幕录制列表
    func capture(for app: AppIdentity?) async -> ScreenContext? {
        guard let image = await captureWindow(for: app) else {
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

    // MARK: - ScreenCaptureKit 截屏

    private func captureWindow(for app: AppIdentity?) async -> CGImage? {
        guard let app else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )

            // 找到目标应用的主窗口
            guard let window = content.windows.first(where: {
                $0.owningApplication?.processID == app.processID && $0.isOnScreen
            }) else {
                Logger.log("Screen", "No window found for pid \(app.processID)")
                return nil
            }

            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * 2)  // Retina
            config.height = Int(window.frame.height * 2)
            config.showsCursor = false

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return image
        } catch {
            Logger.log("Screen", "ScreenCaptureKit error: \(error)")
            return nil
        }
    }

    // MARK: - OCR

    private func recognizeText(in image: CGImage) async -> String {
        // Vision OCR 在后台线程运行（perform 是同步阻塞的）
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

    /// 从 OCR 文本提取关键词，注入 SA AnalysisContext 做上下文偏置
    private func extractContextualWords(from text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var keywords = Set<String>()

        // 取最后 30 行（最近的内容最相关）
        for line in lines.suffix(30) {
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

        return Array(keywords.prefix(50))
    }
}
