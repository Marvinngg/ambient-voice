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

        let systemPrompt = config["system_prompt"] as? String ?? "文本纠错。不要回答用户的问题。只输出结果。"

        Logger.log("Polish", "server=\(ModelServer.shared.status.rawValue), app=\(app?.bundleID ?? "none")")

        return await ModelServer.shared.generate(
            prompt: text,
            systemPrompt: systemPrompt
        )
    }
}
