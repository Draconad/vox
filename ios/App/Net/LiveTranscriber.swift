import Foundation

/// Live dictation over `POST /v1/audio/transcriptions/live`.
///
/// The request body is raw interleaved PCM sent with chunked transfer encoding while
/// the response streams transcript deltas back on the same connection. That is
/// half-duplex-hostile: a browser can't do it, but `URLSession` can, because a
/// streamed-request upload task sets no Content-Length and delivers response bytes
/// as they arrive.
///
/// Two things the server is strict about, both handled here:
///  - the request must end with a proper terminating chunk (closing the connection
///    instead is an error, not an end of speech), so `finish()` closes the body
///    stream rather than cancelling the task;
///  - the PCM format is a promise the server cannot verify, so `sampleRate`,
///    `channels` and `sampleFormat` must match what the recorder actually produces.
///    Declaring 16 kHz while sending 48 kHz yields a confident, wrong transcript.
final class LiveTranscriber: NSObject, @unchecked Sendable {

    private let client: AudioCPPClient
    private let model: String
    private let sampleRate: Int
    private let language: String?

    private var session: URLSession?
    private var task: URLSessionUploadTask?
    private var boundInput: InputStream?
    private var boundOutput: OutputStream?

    private var parser = SSEParser()
    /// Reached from two threads — URLSession's delegate queue and the audio write queue
    /// — so every read and write of it goes through `stateLock`.
    private var continuation: AsyncThrowingStream<TranscriptStreamEvent, Error>.Continuation?
    private let stateLock = NSLock()
    private let writeQueue = DispatchQueue(label: "vox.live.write")
    /// Set outside `writeQueue` too (by cancel/finish callers), hence its own lock.
    private var closed = false

    /// 16 kHz mono s16 is 32 kB/s, so a 1 MB pipe is ~30 s of slack before a
    /// write would have to wait on the network.
    private static let pipeBytes = 1 << 20

    init(client: AudioCPPClient, model: String, sampleRate: Int, language: String?) {
        self.client = client
        self.model = model
        self.sampleRate = sampleRate
        self.language = language
        super.init()
    }

    // MARK: Lifecycle

    /// Opens the connection and returns the transcript event stream.
    func start() throws -> AsyncThrowingStream<TranscriptStreamEvent, Error> {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: Self.pipeBytes, inputStream: &input, outputStream: &output)
        guard let input, let output else { throw VoxError.unreachable("Couldn't open an audio pipe.") }
        boundInput = input
        boundOutput = output
        output.open()

        var req = try liveRequest()
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("audio/L16", forHTTPHeaderField: "Content-Type")
        // Never wait on a 100-continue the server doesn't answer.
        req.setValue("", forHTTPHeaderField: "Expect")

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 0          // the request lasts as long as you talk
        cfg.timeoutIntervalForResource = 0
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        stateLock.lock()
        self.session = session
        stateLock.unlock()

        let stream = AsyncThrowingStream<TranscriptStreamEvent, Error> { cont in
            self.stateLock.lock()
            self.continuation = cont
            self.stateLock.unlock()
            cont.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.cancel() }
            }
        }
        let task = session.uploadTask(withStreamedRequest: req)
        stateLock.lock()
        self.task = task
        stateLock.unlock()
        task.resume()
        return stream
    }

    private func liveRequest() throws -> URLRequest {
        let base = AudioCPPClient.normalised(client.baseURL)
        guard !base.isEmpty,
              var comps = URLComponents(string: base + "/v1/audio/transcriptions/live")
        else { throw VoxError.badURL }
        var q = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "sample_format", value: "s16le"),
        ]
        if let language, !language.isEmpty { q.append(URLQueryItem(name: "language", value: language)) }
        comps.queryItems = q
        guard let url = comps.url, url.host != nil else { throw VoxError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !client.apiKey.isEmpty {
            req.setValue("Bearer \(client.apiKey)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// Push captured PCM. Safe to call from an audio tap: the write is hopped onto
    /// its own queue so the render thread is never blocked.
    func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        writeQueue.async { [weak self] in
            guard let self, let out = self.boundOutput, !self.isClosed else { return }
            var remaining = pcm
            var stalls = 0
            while !remaining.isEmpty {
                guard out.hasSpaceAvailable else {
                    // Re-checked every pass: finish() and cancel() queue behind this
                    // block, so a stall that ignored them would make "stop" take
                    // seconds to respond.
                    if self.isClosed { return }
                    stalls += 1
                    if stalls > 500 {                  // ~5 s of nowhere to put it
                        self.fail(VoxError.unreachable("The connection stopped accepting audio."))
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }
                stalls = 0
                let written = remaining.withUnsafeBytes { buf -> Int in
                    guard let p = buf.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                    return out.write(p, maxLength: remaining.count)
                }
                if written <= 0 {
                    self.fail(VoxError.unreachable("The audio connection dropped."))
                    return
                }
                remaining.removeFirst(written)
            }
        }
    }

    private var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    private func markClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if closed { return false }
        closed = true
        return true
    }

    /// Ends the utterance properly: closing the body stream is what makes
    /// URLSession send the terminating chunk the server insists on. Closing the
    /// connection without one is an error to this endpoint, not an end of speech.
    func finish() {
        guard markClosed() else { return }
        writeQueue.async { [weak self] in
            self?.boundOutput?.close()
        }
    }

    /// Abandon the request without a clean end of speech.
    /// Reachable from the main actor, from `writeQueue` (via `fail`) and from the
    /// stream's own termination handler, so the two references it hands off are taken
    /// under the same lock the delegate queue uses to clear them.
    func cancel() {
        _ = markClosed()
        stateLock.lock()
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        stateLock.unlock()
        writeQueue.async { [weak self] in
            self?.boundOutput?.close()
            task?.cancel()
            session?.invalidateAndCancel()
        }
    }

    /// Ends the event stream with an error, exactly once, whichever thread notices first.
    private func fail(_ error: Error) {
        stateLock.lock()
        let cont = continuation
        continuation = nil
        stateLock.unlock()
        cont?.finish(throwing: error)
        cancel()
    }

    /// Hands one event to the consumer, if the stream is still open.
    private func emit(_ event: TranscriptStreamEvent, finished: Bool = false) {
        stateLock.lock()
        let cont = continuation
        if finished { continuation = nil }
        stateLock.unlock()
        cont?.yield(event)
        if finished { cont?.finish() }
    }

    private func finishStream(throwing error: Error? = nil) {
        stateLock.lock()
        let cont = continuation
        continuation = nil
        stateLock.unlock()
        if let error { cont?.finish(throwing: error) } else { cont?.finish() }
    }

    // No deinit here on purpose. URLSession retains its delegate until it is
    // invalidated, so a transcriber with a live request can never be deallocated and
    // a deinit could not run to release it. Every owner therefore calls `cancel()`
    // explicitly: ChatStore on finish/stop, ListenView on disappear.
}

extension LiveTranscriber: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        completionHandler(boundInput)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        switch http.statusCode {
        case 401, 403: fail(VoxError.unauthorized)
        case 503:      fail(VoxError.busy)
        default:       fail(VoxError.http(http.statusCode, nil))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        for event in parser.feed(text) {
            switch SSEDecode.transcript(event) {
            case .delta(let s):
                emit(.delta(s))
            case .done(let s):
                emit(.done(s), finished: true)
            case .error(let m):
                fail(VoxError.http(200, m))
            case nil:
                break
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        for event in parser.finish() {
            if case .done(let s)? = SSEDecode.transcript(event) { emit(.done(s)) }
        }
        if let error, (error as? URLError)?.code != .cancelled {
            finishStream(throwing: VoxError.unreachable((error as NSError).localizedDescription))
        } else {
            finishStream()
        }
        session.finishTasksAndInvalidate()
        stateLock.lock()
        self.session = nil
        self.task = nil
        stateLock.unlock()
    }
}
