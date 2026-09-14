import Foundation

// MARK: - Errors

enum VoxError: LocalizedError {
    case badURL
    case unauthorized
    case http(Int, String?)
    case unreachable(String)
    case busy
    case emptyResponse
    case notWAV
    case referenceTooLarge(Int)
    case noModelSelected(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "That server address isn't valid. Check it in Settings."
        case .unauthorized:
            return "The server rejected the API key."
        case .http(let code, let body):
            if let body, !body.isEmpty { return "Server error \(code): \(Self.tidy(body))" }
            return "Server error (HTTP \(code))."
        case .unreachable(let why):
            return "Can't reach the server. \(why)"
        case .busy:
            return "The server is busy with another request. Try again in a moment."
        case .emptyResponse:
            return "The server returned no audio."
        case .notWAV:
            return "That file couldn't be read as audio."
        case .referenceTooLarge(let bytes):
            let mb = Double(bytes) / 1_048_576
            return String(format: "That reference clip is %.1f MB. Inline references are capped at 5 MB — trim it shorter.", mb)
        case .noModelSelected(let task):
            return "No \(task) model is picked yet. Choose one in Settings."
        }
    }

    /// audio.cpp returns errors as JSON; show the message rather than the braces.
    private static func tidy(_ body: String) -> String {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let m = obj["error"] as? String { return m }
            if let m = obj["message"] as? String { return m }
        }
        return String(body.prefix(300))
    }
}

// MARK: - Server responses

struct HealthResponse: Decodable {
    var status: String?
    var ok: Bool?
    var models: Int?
    var modelCount: Int?

    var isReady: Bool {
        if let ok { return ok }
        let s = status?.lowercased() ?? ""
        return s == "ok" || s == "ready" || s == "healthy"
    }
    var configuredModels: Int { models ?? modelCount ?? 0 }

    private enum CodingKeys: String, CodingKey {
        case status, ok, models
        case modelCount = "model_count"
    }
}

/// `GET /v1/models`, OpenAI shape: `{"data":[{"id":"pocket-tts", ...}]}`.
/// The extra fields audio.cpp adds (task/family) are optional, and used to
/// pre-sort the pickers when the server bothers to send them.
struct ModelList: Decodable {
    struct Entry: Decodable, Identifiable, Hashable {
        var id: String
        var task: String?
        var family: String?
        var mode: String?
        var ownedBy: String?

        private enum CodingKeys: String, CodingKey {
            case id, task, family, mode
            case ownedBy = "owned_by"
        }
    }
    var data: [Entry]?
    var models: [Entry]?

    var entries: [Entry] { data ?? models ?? [] }
}

struct VoiceListResponse: Decodable {
    var voices: [String]?
}

struct TranscriptionResponse: Decodable {
    var text: String
    var language: String?
    var timing: Timing?

    struct Timing: Decodable {
        var wallMs: Double?
        var audioDurationMs: Double?
        var rtf: Double?

        private enum CodingKeys: String, CodingKey {
            case wallMs = "wall_ms"
            case audioDurationMs = "audio_duration_ms"
            case rtf
        }
    }
}

/// `POST /v1/audio/transcriptions/details`. Everything past `text` and `timing`
/// only appears when the model actually produced it, so it's all optional.
struct TranscriptionDetails: Decodable {
    var text: String
    var language: String?
    var sampleRate: Double?
    var words: [Word]?
    var segments: [Segment]?
    var speakerTurns: [SpeakerTurn]?
    var timing: TranscriptionResponse.Timing?

    struct Word: Decodable, Identifiable {
        var word: String
        var startSample: Double?
        var endSample: Double?
        var confidence: Double?
        var id: String { "\(word)-\(startSample ?? 0)" }

        private enum CodingKeys: String, CodingKey {
            case word
            case startSample = "start_sample"
            case endSample = "end_sample"
            case confidence
        }
    }

    struct Segment: Decodable, Identifiable {
        var text: String?
        var startSample: Double?
        var endSample: Double?
        var confidence: Double?
        var id: String { "\(startSample ?? 0)-\(endSample ?? 0)" }

        private enum CodingKeys: String, CodingKey {
            case text, confidence
            case startSample = "start_sample"
            case endSample = "end_sample"
        }
    }

    struct SpeakerTurn: Decodable, Identifiable {
        var speakerId: String?
        var text: String?
        var startSample: Double?
        var endSample: Double?
        var id: String { "\(speakerId ?? "?")-\(startSample ?? 0)" }

        private enum CodingKeys: String, CodingKey {
            case text
            case speakerId = "speaker_id"
            case startSample = "start_sample"
            case endSample = "end_sample"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case text, language, words, segments, timing
        case sampleRate = "sample_rate"
        case speakerTurns = "speaker_turns"
    }

    /// Seconds into the clip, if the model gave us the rate to divide by.
    func seconds(_ sample: Double?) -> Double? {
        guard let sample, let rate = sampleRate, rate > 0 else { return nil }
        return sample / rate
    }
}

struct UnloadResponse: Decodable {
    var unloaded: [String]?
    var notFound: [String]?

    private enum CodingKeys: String, CodingKey {
        case unloaded
        case notFound = "not_found"
    }
}

/// `"response_format": "json"` on a speech request.
struct SpeechJSONResponse: Decodable {
    var audio: String?
    var data: String?
    var b64Json: String?

    private enum CodingKeys: String, CodingKey {
        case audio, data
        case b64Json = "b64_json"
    }

    var wavData: Data? {
        for candidate in [audio, data, b64Json] {
            guard var s = candidate else { continue }
            if let comma = s.range(of: "base64,") { s = String(s[comma.upperBound...]) }
            if let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters) { return d }
        }
        return nil
    }
}
