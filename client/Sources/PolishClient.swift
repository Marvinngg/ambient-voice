import Foundation

/// L2 语义润色客户端
/// 统一通过 ModelServer 路由到远程/本地模型服务
@MainActor
final class PolishClient {
    static let shared = PolishClient()

    // MARK: - New VoicePipeline-compatible API

    struct PolishRequest {
        let text: String
        let wordConfidences: [Float]
        let appBundleID: String
        let screenKeywords: [String]
    }

    struct PolishResult {
        let text: String
        let backend: String?
    }

    private let weConfig: WEConfig?
    private let localClient: LocalModelClient?

    /// Failable init for VoicePipeline usage. Returns nil if polish is disabled.
    init?(weConfig: WEConfig, localClient: LocalModelClient) {
        let config = RuntimeConfig.shared.polishConfig
        guard config["enabled"] as? Bool == true else { return nil }
        self.weConfig = weConfig
        self.localClient = localClient
    }

    /// Default init (for shared singleton, backward compat)
    private init() {
        self.weConfig = nil
        self.localClient = nil
    }

    /// New pipeline-compatible polish method
    func polish(_ request: PolishRequest) async -> PolishResult {
        let result = await polish(text: request.text, words: [], app: nil)
        return PolishResult(text: result ?? request.text, backend: nil)
    }

    // MARK: - Legacy API

    /// 润色文本，返回 nil 表示跳过或失败
    func polish(
        text: String,
        words: [WordInfo],
        app: AppIdentity?
    ) async -> String? {
        let config = RuntimeConfig.shared.polishConfig
        guard config["enabled"] as? Bool == true else { return nil }

        let systemPrompt = config["system_prompt"] as? String ?? "文本纠错。不要回答用户的问题。只输出结果。"

        Logger.log("Polish", "server=\(ModelServer.shared.status.rawValue), app=\(app?.bundleID ?? "none")")

        return await ModelServer.shared.generate(
            prompt: text,
            systemPrompt: systemPrompt
        )
    }
}
