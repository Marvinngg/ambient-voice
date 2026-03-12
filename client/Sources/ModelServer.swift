import Foundation

/// 模型推理服务器连接管理
/// 支持局域网直连 / Tailscale / localhost，自动健康检测 + 断线降级
@MainActor
final class ModelServer {
    static let shared = ModelServer()

    enum Status: String {
        case unknown
        case connected
        case disconnected
    }

    private(set) var status: Status = .unknown
    private var healthTask: Task<Void, Never>?

    /// 状态变更通知（菜单栏用）
    var onStatusChange: ((Status) -> Void)?

    // MARK: - 配置读取

    private var serverConfig: [String: Any] {
        RuntimeConfig.shared.serverConfig
    }

    private var endpoint: String {
        serverConfig["endpoint"] as? String ?? "http://localhost:11434"
    }

    private var model: String {
        serverConfig["model"] as? String ?? "qwen3:0.6b"
    }

    private var apiType: String {
        serverConfig["api"] as? String ?? "ollama"
    }

    private var timeout: TimeInterval {
        serverConfig["timeout"] as? TimeInterval ?? 10
    }

    // MARK: - 健康检测

    func startHealthCheck() {
        stopHealthCheck()

        let interval = serverConfig["health_interval"] as? TimeInterval ?? 30

        healthTask = Task { [weak self] in
            // 首次立即检查
            await self?.checkHealth()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self?.checkHealth()
            }
        }
    }

    func stopHealthCheck() {
        healthTask?.cancel()
        healthTask = nil
    }

    @discardableResult
    func checkHealth() async -> Bool {
        let healthURL: String
        if apiType == "openai" {
            // OpenAI-compatible: strip path, check /v1/models
            let base = endpoint
                .replacingOccurrences(of: "/v1/chat/completions", with: "")
                .replacingOccurrences(of: "/v1/completions", with: "")
            healthURL = base + "/v1/models"
        } else {
            // Ollama: check /api/tags
            let base = endpoint.replacingOccurrences(of: "/api/generate", with: "")
            healthURL = base + "/api/tags"
        }

        guard let url = URL(string: healthURL) else {
            updateStatus(.disconnected)
            return false
        }

        do {
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.httpMethod = "GET"
            // OpenAI 需要 auth
            if apiType == "openai", let key = serverConfig["api_key"] as? String, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let (_, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            updateStatus(ok ? .connected : .disconnected)
            return ok
        } catch {
            Logger.log("Server", "Health check error: \(error)")
            updateStatus(.disconnected)
            return false
        }
    }

    // MARK: - 推理

    func generate(
        prompt: String,
        systemPrompt: String = "口语转书面。只输出结果。"
    ) async -> String? {
        // 如果状态不是 connected，先尝试一次快速健康检查
        if status != .connected {
            Logger.log("Server", "Status=\(status.rawValue), trying health check...")
            await checkHealth()
        }
        guard status == .connected else {
            Logger.log("Server", "Not connected after check, skipping polish")
            return nil
        }

        let result: String?
        switch apiType {
        case "openai":
            result = await generateOpenAI(prompt: prompt, systemPrompt: systemPrompt)
        default:
            result = await generateOllama(prompt: prompt, systemPrompt: systemPrompt)
        }
        return result
    }

    // MARK: - Ollama API

    private func generateOllama(prompt: String, systemPrompt: String) async -> String? {
        let urlStr = endpoint.hasSuffix("/api/generate") ? endpoint : endpoint + "/api/generate"
        guard let url = URL(string: urlStr) else { return nil }

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "system": systemPrompt,
            "stream": false,
            "think": false,
            "options": ["temperature": 0, "num_predict": 256]
        ]

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["response"] as? String {
                return response.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            Logger.log("Server", "Ollama error: \(error.localizedDescription)")
            updateStatus(.disconnected)
        }
        return nil
    }

    // MARK: - OpenAI-compatible API

    private func generateOpenAI(prompt: String, systemPrompt: String) async -> String? {
        let urlStr = endpoint.contains("/v1/") ? endpoint : endpoint + "/v1/chat/completions"
        guard let url = URL(string: urlStr) else { return nil }

        let apiKey = serverConfig["api_key"] as? String ?? ""

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0,
            "max_tokens": 256
        ]

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            Logger.log("Server", "OpenAI error: \(error.localizedDescription)")
            updateStatus(.disconnected)
        }
        return nil
    }

    // MARK: - 状态管理

    private func updateStatus(_ newStatus: Status) {
        guard status != newStatus else { return }
        status = newStatus
        Logger.log("Server", "Status -> \(newStatus.rawValue) (\(endpoint))")
        onStatusChange?(newStatus)
    }
}
