import Foundation

/// One `data:` payload from a text/event-stream, with its optional `event:` name.
struct SSEEvent {
    var event: String?
    var data: String
}

/// Turns a byte stream into SSE events.
///
/// Used for three different streams that all share this framing: audio.cpp's
/// `speech.audio.delta` (streaming TTS), its `transcript.text.delta` (streaming and
/// live ASR), and the LLM's OpenAI-style chat completion chunks.
struct SSEParser {
    private var buffer = ""
    private var eventName: String?
    private var dataLines: [String] = []

    /// Emit as soon as a `data:` line arrives, rather than waiting for the blank line
    /// that formally terminates an event.
    ///
    /// This exists because the blank line is the fragile part of the chain: line
    /// splitters routinely discard empty lines, and a parser that waits for one then
    /// sits silent forever — a 200 response, a stream that reads fine, and not a single
    /// event out the other end. Nothing this app talks to (OpenAI-compatible chat,
    /// Ollama, audio.cpp) ever splits one event across several `data:` lines, so
    /// emitting per line costs nothing and removes the dependency.
    var emitOnDataLine = true

    /// Feed decoded text; returns whatever complete events it completes.
    mutating func feed(_ text: String) -> [SSEEvent] {
        buffer += text
        var out: [SSEEvent] = []
        // Normalise CRLF so a line split works on \n alone.
        buffer = buffer.replacingOccurrences(of: "\r\n", with: "\n")
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.isEmpty {
                if !dataLines.isEmpty {
                    out.append(SSEEvent(event: eventName, data: dataLines.joined(separator: "\n")))
                }
                eventName = nil
                dataLines = []
                continue
            }
            if line.hasPrefix(":") { continue }                     // comment / keep-alive
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = String(line[line.startIndex..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            switch field {
            case "event":
                eventName = value
            case "data":
                dataLines.append(value)
                if emitOnDataLine {
                    out.append(SSEEvent(event: eventName, data: dataLines.joined(separator: "\n")))
                    eventName = nil
                    dataLines = []
                }
            default:
                break                                               // id / retry - not used here
            }
        }
        return out
    }

    /// Flush a final event that arrived without its trailing blank line.
    mutating func finish() -> [SSEEvent] {
        guard !dataLines.isEmpty else { return [] }
        let e = SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
        eventName = nil
        dataLines = []
        return [e]
    }
}

/// A parsed audio.cpp streaming-audio event.
enum SpeechStreamEvent {
    case delta(Data)        // base64-decoded PCM chunk
    case done
    case error(String)
}

/// A parsed audio.cpp streaming-transcript event.
enum TranscriptStreamEvent {
    case delta(String)
    case done(String)
    case error(String)
}

enum SSEDecode {
    /// audio.cpp speech SSE: `speech.audio.delta` / `speech.audio.done`.
    static func speech(_ event: SSEEvent) -> SpeechStreamEvent? {
        if event.data.trimmingCharacters(in: .whitespaces) == "[DONE]" { return .done }
        guard let obj = json(event.data) else { return nil }
        let type = (obj["type"] as? String) ?? event.event ?? ""
        if type.hasSuffix("error") || obj["error"] != nil {
            return .error(message(obj) ?? "The server reported an error mid-stream.")
        }
        if type.hasSuffix("done") { return .done }
        // The base64 chunk has been called `audio` and `delta` across versions.
        for key in ["audio", "delta", "data", "chunk"] {
            if let s = obj[key] as? String,
               let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters), !d.isEmpty {
                return .delta(d)
            }
        }
        return nil
    }

    /// audio.cpp transcription SSE: `transcript.text.delta` / `transcript.text.done`.
    static func transcript(_ event: SSEEvent) -> TranscriptStreamEvent? {
        if event.data.trimmingCharacters(in: .whitespaces) == "[DONE]" { return .done("") }
        guard let obj = json(event.data) else { return nil }
        let type = (obj["type"] as? String) ?? event.event ?? ""
        if type.hasSuffix("error") || obj["error"] != nil {
            return .error(message(obj) ?? "The server reported an error mid-stream.")
        }
        let text = (obj["delta"] as? String) ?? (obj["text"] as? String) ?? ""
        if type.hasSuffix("done") { return .done(text) }
        if !text.isEmpty { return .delta(text) }
        return nil
    }

    static func json(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    static func message(_ obj: [String: Any]) -> String? {
        if let e = obj["error"] as? [String: Any] { return e["message"] as? String }
        if let e = obj["error"] as? String { return e }
        return obj["message"] as? String
    }
}


extension URLSession.AsyncBytes {

    /// Lines from the raw bytes, empty ones included.
    ///
    /// `AsyncLineSequence` is the obvious thing to reach for, but SSE gives a blank
    /// line structural meaning and a line splitter is entitled to drop it. Doing the
    /// split here means the framing this app relies on is the framing it implements,
    /// rather than an assumption about someone else's iterator.
    var sseLines: AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var line: [UInt8] = []
                line.reserveCapacity(256)
                do {
                    for try await byte in self {
                        if byte == 0x0A {                       // \n
                            if line.last == 0x0D { line.removeLast() }   // \r\n
                            continuation.yield(String(decoding: line, as: UTF8.self))
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(byte)
                        }
                    }
                    if !line.isEmpty {
                        continuation.yield(String(decoding: line, as: UTF8.self))
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
}
