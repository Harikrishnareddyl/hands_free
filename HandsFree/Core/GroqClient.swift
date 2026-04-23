import Foundation

/// Thin Groq client. Handles speech-to-text and chat completions.
/// Whisper is used for transcription (relies on native punctuation + `prompt`
/// for vocabulary); chat completions back the Ask-AI flow with SSE streaming.
struct GroqClient {
    enum Model {
        static let whisperTurbo = "whisper-large-v3-turbo"
        static let whisperLarge = "whisper-large-v3"
    }

    /// Chat models available via the same Groq key. Ordered for the picker.
    enum LLMModel {
        static let llama33_70b = "llama-3.3-70b-versatile"
        static let llama31_8b  = "llama-3.1-8b-instant"
        static let kimiK2      = "moonshotai/kimi-k2-instruct"
        static let qwen3_32b   = "qwen/qwen3-32b"
        static let gptOss120b  = "openai/gpt-oss-120b"

        static let all: [(id: String, label: String)] = [
            (llama33_70b, "Llama 3.3 70B"),
            (llama31_8b,  "Llama 3.1 8B"),
            (kimiK2,      "Kimi K2"),
            (qwen3_32b,   "Qwen3 32B"),
            (gptOss120b,  "GPT-OSS 120B"),
        ]
    }

    struct ChatMessage {
        let role: String   // "system" | "user" | "assistant"
        let content: String
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

    // MARK: - Chat completions (SSE streaming)

    /// Streams a chat completion, invoking `onDelta` for every content token
    /// as it arrives. Returns the full concatenated response when the stream
    /// closes. `onDelta` is called on the URLSession delegate queue — callers
    /// should hop to the main actor before touching UI.
    func chatStream(
        messages: [ChatMessage],
        model: String,
        temperature: Double = 0.7,
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        struct MsgBody: Encodable { let role: String; let content: String }
        struct Body: Encodable {
            let model: String
            let messages: [MsgBody]
            let stream: Bool
            let temperature: Double
        }
        let body = Body(
            model: model,
            messages: messages.map { MsgBody(role: $0.role, content: $0.content) },
            stream: true,
            temperature: temperature
        )
        request.httpBody = try JSONEncoder().encode(body)

        Log.info("groq", "POST /chat/completions (stream), model=\(model), msgs=\(messages.count)")
        let start = Date()
        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw GroqError.http(statusCode: -1, body: "no response")
        }
        if !(200..<300).contains(http.statusCode) {
            var bodyStr = ""
            for try await line in bytes.lines {
                bodyStr += line + "\n"
                if bodyStr.count > 2000 { break }
            }
            Log.error("groq", "chat HTTP \(http.statusCode): \(bodyStr.prefix(400))")
            throw GroqError.http(statusCode: http.statusCode, body: bodyStr)
        }

        var full = ""
        for try await line in bytes.lines {
            // SSE framing: lines of form "data: {...}" or "data: [DONE]".
            guard line.hasPrefix("data:") else { continue }
            let payload = line
                .dropFirst(5)
                .trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }

            do {
                let chunk = try JSONDecoder().decode(ChatChunk.self, from: data)
                if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                    full += delta
                    onDelta(delta)
                }
            } catch {
                // Ignore parse errors on individual SSE frames — Groq
                // occasionally emits keep-alive / control frames we don't care
                // about. A terminal error would've come through HTTP status.
                continue
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        Log.info("groq", "chat ok in \(String(format: "%.2f", elapsed))s, \(full.count) chars")
        return full
    }

    private struct ChatChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta
        }
        let choices: [Choice]
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { self.append(d) }
    }
}
