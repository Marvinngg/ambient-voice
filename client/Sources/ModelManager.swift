import Foundation

/// 模型管理：检测就绪状态、从后端下载、hash 校验
@MainActor
final class ModelManager {
    static let shared = ModelManager()

    private let modelsDir = WEDataDir.url.appendingPathComponent("models")

    struct ManifestEntry: Codable {
        let filename: String
        let sha256: String
        let size: Int64
        let url: String?
    }

    struct Manifest: Codable {
        let version: String?
        let models: [String: ManifestEntry]?

        // 兼容简化格式
        let base_model: ManifestEntry?
        let adapter: ManifestEntry?
    }

    /// 检查基础模型是否已下载
    var isBaseModelReady: Bool {
        FileManager.default.fileExists(atPath: baseModelPath.path)
    }

    /// 检查 adapter 是否已下载
    var isAdapterReady: Bool {
        FileManager.default.fileExists(atPath: adapterPath.path)
    }

    var baseModelPath: URL {
        modelsDir.appendingPathComponent("base.gguf")
    }

    var adapterPath: URL {
        modelsDir.appendingPathComponent("sa-adapter.gguf")
    }

    /// 从 manifest URL 下载模型
    func downloadModels(progressHandler: ((String, Double) -> Void)? = nil) async throws {
        let config = RuntimeConfig.shared.downloadsConfig
        guard let manifestURLStr = config["manifest"] as? String,
              let manifestURL = URL(string: manifestURLStr) else {
            Logger.log("Model", "No manifest URL configured")
            return
        }

        // 下载 manifest
        Logger.log("Model", "Fetching manifest: \(manifestURLStr)")
        let (manifestData, _) = try await URLSession.shared.data(from: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        Logger.log("Model", "Manifest version: \(manifest.version ?? "unknown")")

        // 下载 base model
        let baseURL = config["base_model"] as? String
        if let urlStr = baseURL, let url = URL(string: urlStr), !isBaseModelReady {
            progressHandler?("base model", 0)
            try await downloadFile(from: url, to: baseModelPath, progressHandler: { p in
                progressHandler?("base model", p)
            })
        }

        // 下载 adapter
        let adapterURL = config["adapter"] as? String
        if let urlStr = adapterURL, let url = URL(string: urlStr) {
            progressHandler?("adapter", 0)
            try await downloadFile(from: url, to: adapterPath, progressHandler: { p in
                progressHandler?("adapter", p)
            })
        }
    }

    private func downloadFile(
        from url: URL,
        to destination: URL,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws {
        Logger.log("Model", "Downloading \(url.lastPathComponent)...")
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        let httpResponse = response as? HTTPURLResponse
        guard httpResponse?.statusCode == 200 else {
            throw ModelError.downloadFailed(url.lastPathComponent, httpResponse?.statusCode ?? 0)
        }

        // 移动到目标位置
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)

        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        Logger.log("Model", "Downloaded \(url.lastPathComponent): \(size / 1024 / 1024)MB")
        progressHandler?(1.0)
    }
}

enum ModelError: Error {
    case downloadFailed(String, Int)
    case hashMismatch(String)
}
