import Foundation

class LocalModelClient {
    let endpoint: String
    let model: String

    init(endpoint: String = "http://localhost:11434", model: String = "qwen3:0.6b") {
        self.endpoint = endpoint
        self.model = model
    }

    func generate(system: String, prompt: String) async -> String? {
        // Call local ollama-compatible API
        let url = URL(string: "\(endpoint)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": model,
            "system": system,
            "prompt": prompt,
            "stream": false
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? String else {
            return nil
        }
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
