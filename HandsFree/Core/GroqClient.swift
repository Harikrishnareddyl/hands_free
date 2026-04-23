import Foundation

/// Thin Groq client. Speech-to-text only — we rely on Whisper's native
/// punctuation/capitalization and the `prompt` parameter for vocabulary hints.
struct GroqClient {
    enum Model {
        static let whisperTurbo = "whisper-large-v3-turbo"
        static let whisperLarge = "whisper-large-v3"
    }

    enum GroqError: LocalizedError {
        case missingAPIKey
        case http(statusCode: Int, body: String)
        case decoding(Error)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Groq API key. See Settings → API key for setup instructions."
            case .http(let code, let body):
                return "Groq HTTP \(code): \(body.prefix(400))"
            case .decoding(let e):
                return "Groq decode error: \(e.localizedDescription)"
            }
        }
    }

    let apiKey: String
    var session: URLSession = .shared
    var baseURL = URL(string: "https://api.groq.com/openai/v1")!

    func transcribe(
        audioURL: URL,
        model: String = Model.whisperTurbo,
        language: String? = nil,
        prompt: String? = nil
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("audio/transcriptions")
        let boundary = "----HandsFree-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        appendField("model", model)
        appendField("response_format", "json")
        appendField("temperature", "0")
        if let language { appendField("language", language) }
        if let prompt, !prompt.isEmpty { appendField("prompt", prompt) }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        body.append("\r\n--\(boundary)--\r\n")

        Log.info("groq", "POST /audio/transcriptions, body=\(body.count) bytes, model=\(model)")
        let start = Date()
        let (data, response) = try await session.upload(for: request, from: body)
        let elapsed = Date().timeIntervalSince(start)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            Log.error("groq", "transcribe HTTP \(code) after \(String(format: "%.2f", elapsed))s: \(bodyStr.prefix(400))")
            throw GroqError.http(statusCode: code, body: bodyStr)
        }

        do {
            let text = try JSONDecoder().decode(TranscriptionResponse.self, from: data).text
            Log.info("groq", "transcribe ok in \(String(format: "%.2f", elapsed))s: \"\(text.prefix(80))\"")
            return text
        } catch {
            Log.error("groq", "transcribe decode failed: \(error.localizedDescription)")
            throw GroqError.decoding(error)
        }
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { self.append(d) }
    }
}
