import Foundation

/// How a TTS request should pick its speaker.
enum VoiceSelection {
    /// Let the model / server default decide (`default_voice_preset`, if configured).
    case serverDefault
    /// A named voice: a model preset, a `voice_dir` wav basename, or a model-native cached id.
    case named(String)
    /// Clone from a reference clip that lives on this phone, inlined as base64.
    case inline(wav: Data, referenceText: String?)

    var label: String {
        switch self {
        case .serverDefault: return "Server default"
        case .named(let n): return n
        case .inline: return "Cloned voice"
        }
    }
}

/// Everything the app asks of `audiocpp_server`.
///
/// The endpoint names and field names here come from `app/server/README.md` in the
/// audio.cpp tree, so if you upgrade the server and something moves, that file is
/// the place to check.
struct AudioCPPClient {

    var baseURL: String
    var apiKey: String

    static var current: AudioCPPClient {
        AudioCPPClient(baseURL: AppSettings.serverURL, apiKey: AppSettings.apiKey)
    }

    /// audio.cpp caps an inlined base64 reference at 5 MiB of *decoded* payload.
    static let maxInlineReferenceBytes = 5 * 1024 * 1024

    // MARK: Sessions

    /// Short-deadline session for the small JSON calls.
    private static let quick: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 15
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// Inference can legitimately take minutes (a long paragraph, a cold model load,
    /// a queue behind another request), so generation gets its own patient session.
    private static let long: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private static let decoder = JSONDecoder()

    // MARK: Request plumbing

    /// Normalises whatever the user typed into Settings: adds the scheme, drops a
    /// trailing slash, and tolerates a `/v1` they pasted in by habit.
    static func normalised(_ raw: String) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return base }
        if !base.lowercased().hasPrefix("http://") && !base.lowercased().hasPrefix("https://") {
            base = "http://" + base
        }
        while base.hasSuffix("/") { base.removeLast() }
        if base.lowercased().hasSuffix("/v1") { base = String(base.dropLast(3)) }
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET") throws -> URLRequest {
        let base = Self.normalised(baseURL)
        guard !base.isEmpty, var comps = URLComponents(string: base + path) else { throw VoxError.badURL }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url, url.host != nil else { throw VoxError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        // audio.cpp itself has no authentication. This is here for the case where
        // it sits behind a reverse proxy that wants a bearer token.
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func json(_ path: String, _ body: [String: Any], method: String = "POST") throws -> URLRequest {
        var req = try request(path, method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return req
    }

    /// Runs a request and hands back raw bytes, mapping transport and HTTP failures
    /// onto `VoxError` so every screen can just show `error.localizedDescription`.
    private func raw(_ req: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let err as URLError where err.code == .cancelled {
            throw CancellationError()
        } catch {
            throw VoxError.unreachable((error as NSError).localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw VoxError.unreachable("No response.") }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 401, 403:  throw VoxError.unauthorized
        case 503:
            // The server uses 503 for both "busy" and "not enough memory"; its JSON
            // body says which, and tidy() surfaces that message.
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("insufficient_memory") { throw VoxError.http(503, body) }
            throw VoxError.busy
        default:
            throw VoxError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
    }

    private func decode<T: Decodable>(_ req: URLRequest, as type: T.Type, session: URLSession? = nil) async throws -> T {
        let (data, _) = try await raw(req, session: session ?? Self.quick)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw VoxError.http(200, String(data: data, encoding: .utf8))
        }
    }

    // MARK: Discovery

    func health() async throws -> HealthResponse {
        try await decode(try request("/health"), as: HealthResponse.self)
    }

    func models() async throws -> [ModelList.Entry] {
        try await decode(try request("/v1/models"), as: ModelList.self).entries
    }

    /// Cached voice ids, server-side preset names and `voice_dir` wav basenames.
    /// A server with no `voice_dir` and no presets legitimately returns an empty list.
    func voices(model: String?) async throws -> [String] {
        var q: [URLQueryItem] = []
        if let model, !model.isEmpty { q.append(URLQueryItem(name: "model", value: model)) }
        return try await decode(try request("/v1/audio/voices", query: q), as: VoiceListResponse.self).voices ?? []
    }

    // MARK: Text to speech

    private func speechBody(model: String, text: String, voice: VoiceSelection,
                            responseFormat: String, options: [String: Any]) throws -> [String: Any] {
        var body: [String: Any] = ["model": model, "input": text, "response_format": responseFormat]
        // The families' `options.request` entries ARE the top-level body fields —
        // `reference_text` appears both in that list and as a documented speech field —
        // so these go in flat. Applied before the voice, which must win: an inline clone
        // carries its own reference_text and that one is the correct one.
        for (key, value) in options where !key.isEmpty { body[key] = value }
        switch voice {
        case .serverDefault:
            break
        case .named(let name):
            body["voice"] = name
        case .inline(let wav, let refText):
            guard wav.count <= Self.maxInlineReferenceBytes else {
                throw VoxError.referenceTooLarge(wav.count)
            }
            body["voice_ref"] = ["type": "base64", "data": wav.base64EncodedString()]
            if let refText, !refText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                body["reference_text"] = refText
            }
        }
        return body
    }

    /// One-shot speech. Returns WAV bytes ready for `AVAudioPlayer`.
    func speech(model: String, text: String, voice: VoiceSelection,
                options: [String: Any] = [:]) async throws -> Data {
        // Reported so the UI can say "loading" when the server stalls to swap a model in.
        let job = await ServerActivity.shared.begin(model: model, kind: "speech")
        defer { Task { await ServerActivity.shared.end(job) } }
        let body = try speechBody(model: model, text: text, voice: voice,
                                  responseFormat: "wav", options: options)
        let (data, http) = try await raw(try json("/v1/audio/speech", body), session: Self.long)
        guard !data.isEmpty else { throw VoxError.emptyResponse }

        // Default is audio/wav bytes, but a server can be configured to answer JSON.
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.contains("json") {
            if let parsed = try? Self.decoder.decode(SpeechJSONResponse.self, from: data),
               let wav = parsed.wavData { return wav }
            throw VoxError.http(200, String(data: data, encoding: .utf8))
        }
        return data
    }

    /// Streaming speech for a model configured with `mode: "streaming"`.
    /// Yields raw PCM chunks (s16le, mono) as they arrive.
    func speechStream(model: String, text: String, voice: VoiceSelection,
                      options: [String: Any] = [:]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body = try speechBody(model: model, text: text, voice: voice,
                                              responseFormat: "pcm", options: options)
                    body["stream_format"] = "sse"
                    // VoxCPM2 streaming rejects retry_badcase, which is an offline-only
                    // behaviour. Harmless on models that don't know the option.
                    body["options"] = ["retry_badcase": false]
                    var req = try json("/v1/audio/speech", body)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let (bytes, resp) = try await Self.long.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw VoxError.unreachable("No response.") }
                    guard (200..<300).contains(http.statusCode) else {
                        if http.statusCode == 401 || http.statusCode == 403 { throw VoxError.unauthorized }
                        if http.statusCode == 503 { throw VoxError.busy }
                        throw VoxError.http(http.statusCode, nil)
                    }

                    var parser = SSEParser()
                    for try await line in bytes.sseLines {
                        for event in parser.feed(line + "\n") {
                            switch SSEDecode.speech(event) {
                            case .delta(let pcm): continuation.yield(pcm)
                            case .done:
                                continuation.finish()
                                return
                            case .error(let m): throw VoxError.http(200, m)
                            case nil: break
                            }
                        }
                    }
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

    // MARK: Speech to text

    private func multipart(_ path: String, fields: [String: String], wav: Data,
                           filename: String = "audio.wav") throws -> URLRequest {
        let boundary = "vox.\(UUID().uuidString)"
        var req = try request(path, method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        for (key, value) in fields where !value.isEmpty {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")
        req.httpBody = body
        return req
    }

    /// Transcribe a finished recording. `file` + `model` are required, `language` optional.
    func transcribe(wav: Data, model: String, language: String? = nil,
                    options: [String: Any] = [:]) async throws -> TranscriptionResponse {
        let job = await ServerActivity.shared.begin(model: model, kind: "transcription")
        defer { Task { await ServerActivity.shared.end(job) } }
        var fields = ["model": model, "language": language ?? ""]
        // Multipart carries everything as strings; the server parses them per its spec.
        for (key, value) in options { fields[key] = String(describing: value) }
        let req = try multipart("/v1/audio/transcriptions", fields: fields, wav: wav)
        return try await decode(req, as: TranscriptionResponse.self, session: Self.long)
    }

    /// Same upload, richer answer: word timings, segments and speaker turns where the
    /// model produced them. The plain route throws those away.
    func transcribeDetails(wav: Data, model: String, language: String? = nil) async throws -> TranscriptionDetails {
        let job = await ServerActivity.shared.begin(model: model, kind: "transcription")
        defer { Task { await ServerActivity.shared.end(job) } }
        let req = try multipart("/v1/audio/transcriptions/details",
                               fields: ["model": model, "language": language ?? ""],
                               wav: wav)
        return try await decode(req, as: TranscriptionDetails.self, session: Self.long)
    }

    // MARK: Housekeeping

    /// Frees the GPU without restarting the container.
    @discardableResult
    func unloadAllModels() async throws -> UnloadResponse {
        try await decode(try request("/v1/tasks/unload_all_models", method: "POST"),
                         as: UnloadResponse.self, session: Self.long)
    }

    @discardableResult
    func unloadModels(_ ids: [String]) async throws -> UnloadResponse {
        try await decode(try json("/v1/tasks/unload_models", ["model_ids": ids]),
                         as: UnloadResponse.self, session: Self.long)
    }
}
