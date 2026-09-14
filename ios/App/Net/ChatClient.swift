import Foundation

/// The language model half of the conversation.
///
/// Deliberately speaks the OpenAI-compatible `/v1/chat/completions` dialect rather
/// than Ollama's native `/api/chat`, because that one URL shape also works if you
/// point it at Open WebUI, llama.cpp's server, or anything else later. Ollama serves
/// it on port 11434 with no key.
struct ChatClient {

    var baseURL: String
    var apiKey: String

    static var current: ChatClient {
        ChatClient(baseURL: AppSettings.llmURL, apiKey: AppSettings.llmKey)
    }

    struct Message: Codable, Identifiable, Equatable {
        enum Role: String, Codable { case system, user, assistant }
        var id = UUID()
        var role: Role
        var content: String

        init(id: UUID = UUID(), role: Role, content: String) {
            self.id = id
            self.role = role
            self.content = content
        }

        private enum CodingKeys: String, CodingKey { case role, content }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = UUID()
            role = try c.decode(Role.self, forKey: .role)
            content = try c.decode(String.self, forKey: .content)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(role, forKey: .role)
            try c.encode(content, forKey: .content)
        }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        let base = AudioCPPClient.normalised(baseURL)
        guard !base.isEmpty, let url = URL(string: base + path), url.host != nil else { throw VoxError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// Model ids the LLM server offers. Ollama answers this from its installed tags.
    func models() async throws -> [String] {
        let req = try request("/v1/models")
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await Self.session.data(for: req)
        } catch {
            throw VoxError.unreachable((error as NSError).localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw VoxError.unauthorized }
        guard (200..<300).contains(code) else {
            throw VoxError.http(code, String(data: data, encoding: .utf8))
        }
        if let list = try? JSONDecoder().decode(ModelList.self, from: data) {
            return list.entries.map(\.id).sorted()
        }
        // Ollama's native shape, in case /v1/models isn't served.
        struct Tags: Decodable { struct M: Decodable { var name: String }; var models: [M] }
        if let tags = try? JSONDecoder().decode(Tags.self, from: data) {
            return tags.models.map(\.name).sorted()
        }
        return []
    }

    /// Streams the reply token by token.
    ///
    /// Not every server honours `stream: true`, and not every one that does speaks
    /// SSE. Three shapes are accepted, because getting this wrong is invisible — a
    /// parser looking only for `data:` lines discards a plain JSON body silently
    /// (`{"id":"chatcmpl-…` parses as a field named `{"id"`) and the reply comes out
    /// empty with no error at all:
    ///   1. SSE  — `data: {"choices":[{"delta":{"content":"…"}}]}`
    ///   2. one JSON body — `{"choices":[{"message":{"content":"…"}}]}`
    ///   3. NDJSON — Ollama's native `{"message":{"content":"…"},"done":false}` per line
    func stream(model: String, messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try request("/v1/chat/completions", method: "POST")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let payload: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, resp) = try await Self.session.bytes(for: req)
                    let http = resp as? HTTPURLResponse
                    let code = http?.statusCode ?? 0
                    if code == 401 || code == 403 { throw VoxError.unauthorized }
                    guard (200..<300).contains(code) else {
                        throw VoxError.http(code, try await Self.collect(bytes, limit: 2_000))
                    }

                    let contentType = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                    if !contentType.contains("event-stream") {
                        let body = try await Self.collect(bytes, limit: 400_000)
                        let text = Self.textFromNonStreamedBody(body)
                        if !text.isEmpty {
                            continuation.yield(text)
                            continuation.finish()
                            return
                        }
                        throw VoxError.http(200, body.isEmpty
                            ? "The model returned an empty reply."
                            : String(body.prefix(400)))
                    }

                    var parser = SSEParser()
                    var yielded = false
                    var sawReasoning = false
                    // Kept only so an empty reply can show what actually arrived. A
                    // stream that parses to nothing is the hardest thing to diagnose
                    // from a phone, and "empty reply" on its own says nothing useful.
                    var sample = ""

                    for try await line in bytes.sseLines {
                        if sample.count < 400, !line.isEmpty { sample += line + "\n" }
                        for event in parser.feed(line + "\n") {
                            let data = event.data.trimmingCharacters(in: .whitespaces)
                            if data == "[DONE]" {
                                try Self.checkEmpty(yielded: yielded, sawReasoning: sawReasoning, sample: sample)
                                continuation.finish()
                                return
                            }
                            guard let obj = SSEDecode.json(data) else { continue }
                            if let msg = SSEDecode.message(obj), obj["choices"] == nil {
                                throw VoxError.http(200, msg)
                            }
                            guard let choices = obj["choices"] as? [[String: Any]] else { continue }
                            for choice in choices {
                                if Self.isReasoningOnly(choice) { sawReasoning = true }
                                if let text = Self.text(from: choice), !text.isEmpty {
                                    yielded = true
                                    continuation.yield(text)
                                }
                            }
                        }
                    }
                    // A stream closed without its final blank line still has one event
                    // sitting in the parser — often the last content chunk.
                    for event in parser.finish() {
                        let data = event.data.trimmingCharacters(in: .whitespaces)
                        guard data != "[DONE]", let obj = SSEDecode.json(data),
                              let choices = obj["choices"] as? [[String: Any]] else { continue }
                        for choice in choices {
                            if let text = Self.text(from: choice), !text.isEmpty {
                                yielded = true
                                continuation.yield(text)
                            }
                        }
                    }
                    try Self.checkEmpty(yielded: yielded, sawReasoning: sawReasoning, sample: sample)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Response shapes

    private static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> String {
        var body = ""
        for try await line in bytes.sseLines {
            body += line + "\n"
            if body.count > limit { break }
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pulls the reply out of a body that wasn't an SSE stream — either one JSON
    /// object, or NDJSON with a fragment per line.
    private static func textFromNonStreamedBody(_ body: String) -> String {
        var out = ""
        // One whole object first: the common case when a server ignores stream:true.
        if let obj = SSEDecode.json(body) {
            if let choices = obj["choices"] as? [[String: Any]] {
                for choice in choices { out += text(from: choice) ?? "" }
            }
            if out.isEmpty, let message = obj["message"] as? [String: Any],
               let content = message["content"] as? String {
                out += content
            }
            if out.isEmpty, let content = obj["response"] as? String { out += content }
            if !out.isEmpty { return out }
        }
        // Otherwise treat it as NDJSON and stitch the fragments back together.
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            var piece = String(line).trimmingCharacters(in: .whitespaces)
            if piece.hasPrefix("data:") { piece = String(piece.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            if piece == "[DONE]" { continue }
            guard let obj = SSEDecode.json(piece) else { continue }
            if let choices = obj["choices"] as? [[String: Any]] {
                for choice in choices { out += text(from: choice) ?? "" }
            } else if let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? String {
                out += content
            } else if let content = obj["response"] as? String {
                out += content
            }
        }
        return out
    }

    /// The spoken part of a choice, whichever dialect it arrived in. Reasoning fields
    /// are deliberately excluded — reading a model's chain of thought aloud is not what
    /// anyone wants from a voice assistant.
    private static func text(from choice: [String: Any]) -> String? {
        if let delta = choice["delta"] as? [String: Any],
           let content = delta["content"] as? String, !content.isEmpty {
            return content
        }
        if let message = choice["message"] as? [String: Any],
           let content = message["content"] as? String, !content.isEmpty {
            return content
        }
        if let content = choice["text"] as? String, !content.isEmpty {
            return content
        }
        return nil
    }

    private static func isReasoningOnly(_ choice: [String: Any]) -> Bool {
        guard let delta = choice["delta"] as? [String: Any] else { return false }
        if let content = delta["content"] as? String, !content.isEmpty { return false }
        for key in ["reasoning_content", "reasoning", "thinking"] {
            if let value = delta[key] as? String, !value.isEmpty { return true }
        }
        return false
    }

    /// An empty reply should say so rather than showing an empty bubble — and should
    /// show what the server actually sent, so the cause is visible instead of guessed.
    private static func checkEmpty(yielded: Bool, sawReasoning: Bool, sample: String) throws {
        guard !yielded else { return }
        if sawReasoning {
            throw VoxError.http(200, "That model only returned its reasoning, with no answer to speak. "
                                + "Pick a non-reasoning model, or turn thinking off for it.")
        }
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw VoxError.http(200, "The model returned an empty reply — the server sent no data at all.")
        }
        throw VoxError.http(200, "The model returned no text. The server sent:\n\n"
                            + String(trimmed.prefix(300)))
    }
}
