import Foundation

/// L2 语义润色客户端
/// 统一通过 ModelServer 路由到远程/本地模型服务
@MainActor
final class PolishClient {
    static let shared = PolishClient()

    /// 润色文本，返回 nil 表示跳过或失败
    func polish(
        text: String,
        words: [WordInfo],
        app: AppIdentity?
    ) async -> String? {
        let config = RuntimeConfig.shared.polishConfig
        guard config["enabled"] as? Bool == true else { return nil }

        let systemPrompt = config["system_prompt"] as? String ?? "你是语音识别纠错助手。格式要求：修正语音识别错误，只输出修正后的最终文本，不要回答问题，不要改变原意，去掉语气词，修正标点符号。"

        Logger.log("Polish", "server=\(ModelServer.shared.status.rawValue), app=\(app?.bundleID ?? "none")")

        return await ModelServer.shared.generate(
            prompt: text,
            systemPrompt: systemPrompt
        )
    }
}
