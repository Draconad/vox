import Foundation
import SwiftUI

/// The hands-free conversation: microphone → audio.cpp ASR → LLM → audio.cpp TTS → speaker.
///
/// The part worth knowing about is that the reply is spoken **sentence by sentence**.
/// The LLM's tokens are buffered until a sentence closes, that sentence is sent for
/// speech immediately, and the next one is generated while the first is still playing.
/// Waiting for the whole reply before speaking would add the full generation time to
/// the silence after you stop talking, which is what makes most voice assistants feel
/// slow.
@MainActor
final class ChatStore: ObservableObject {

    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case thinking
        case speaking

        var label: String {
            switch self {
            case .idle:         return "Tap to talk"
            case .listening:    return "Listening…"
            case .transcribing: return "Transcribing…"
            case .thinking:     return "Thinking…"
            case .speaking:     return "Speaking…"
            }
        }
    }

    struct Turn: Identifiable, Equatable {
        var id = UUID()
        var role: ChatClient.Message.Role
        var text: String
        var isPartial = false
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var liveTranscript = ""
    @Published var error: String?

    /// True while the hands-free loop is up — the Talk screen renders this as a call
    /// in progress rather than as a conversation you can scroll.
    @Published private(set) var inCall = false
    @Published private(set) var callStartedAt: Date?

    /// One line of what is happening right now, for a screen with no transcript:
    /// what you're saying while it listens, what it's saying while it answers.
    var caption: String {
        switch phase {
        case .listening:
            return liveTranscript
        case .transcribing:
            return liveTranscript
        case .thinking, .speaking, .idle:
            return turns.last(where: { $0.role == .assistant })?.text ?? ""
        }
    }

    /// The last thing you said, shown small above the reply so a misheard word is obvious.
    var lastHeard: String {
        turns.last(where: { $0.role == .user })?.text ?? ""
    }

    let mic = MicRecorder()
    let player = SpeechPlayer()

    private let library: VoiceLibrary
    private var history: [ChatClient.Message] = []

    private var llmTask: Task<Void, Never>?
    /// The one TTS request in flight. Held so barging in can cancel it — otherwise a
    /// sentence already being generated still arrives and plays into the open mic.
    private var speechTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var liveSession: LiveTranscriber?

    private var sentenceBuffer = ""
    private var speechQueue: [String] = []
    private var speaking = false
    private var replyFinished = false
    /// True while the loop should pick the microphone back up after speaking.
    private var continuous = false

    init(library: VoiceLibrary) {
        self.library = library
        // SpeechPlayer isn't actor-bound (its delegate callbacks come from AVFoundation),
        // so hop back onto the main actor before touching this store.
        player.onDrained { [weak self] in
            Task { @MainActor in self?.speechDrained() }
        }
    }

    // MARK: Conversation control

    /// Starts (or restarts) listening. `continuous` keeps the loop going after each reply.
    func startListening(continuous: Bool) {
        guard phase == .idle || phase == .speaking else { return }
        self.continuous = continuous
        stopSpeaking()

        guard !AppSettings.asrModel.isEmpty else {
            error = VoxError.noModelSelected("transcription").localizedDescription
            return
        }

        // Set only once the call can actually start, and regardless of hands-free:
        // a one-shot turn still needs the hang-up button and the interrupt control.
        inCall = true
        if callStartedAt == nil { callStartedAt = Date() }

        Task {
            guard await AudioSessionManager.requestMicrophone() else {
                error = "Vox needs microphone access. Turn it on in iOS Settings → Vox."
                endCall()
                return
            }
            do {
                liveTranscript = ""
                mic.configureSilenceDetection(threshold: 0.045, seconds: AppSettings.silenceSeconds)
                let useLive = AppSettings.liveDictation
                if useLive { try startLiveSession() }
                // Capture the session strongly here: the chunk handler runs on the audio
                // thread and must not reach back into main-actor state to find it.
                let session = useLive ? liveSession : nil
                try mic.start(
                    onChunk: session.map { s in { (chunk: Data) in s.append(chunk) } },
                    onSilence: AppSettings.autoStop
                        ? { [weak self] in Task { @MainActor in self?.finishListening() } }
                        : nil
                )
                phase = .listening
            } catch {
                self.error = error.localizedDescription
                phase = .idle
                endCall()
            }
        }
    }

    /// Clears the call indicators. The screen shows a red hang-up button and a running
    /// clock off the back of these, so leaving them set after a failure would show a
    /// call that isn't happening.
    private func endCall() {
        continuous = false
        inCall = false
        callStartedAt = nil
    }

    /// Stop listening and act on what was said.
    func finishListening() {
        guard phase == .listening else { return }
        let wav = mic.stop()
        liveSession?.finish()
        liveSession = nil
        liveTask?.cancel()
        liveTask = nil

        guard let wav else {
            phase = .idle
            if continuous { error = nil }
            return
        }
        phase = .transcribing
        Task { await transcribeAndAsk(wav: wav) }
    }

    /// Abandon whatever is happening and go quiet. This is the "end call" path.
    func stopEverything() {
        endCall()
        llmTask?.cancel(); llmTask = nil
        // Without this a sentence already being generated still lands, and the phone
        // starts talking after you've hung up.
        speechTask?.cancel(); speechTask = nil
        liveTask?.cancel(); liveTask = nil
        liveSession?.cancel(); liveSession = nil
        mic.cancel()
        player.stop()
        speechQueue.removeAll()
        speaking = false
        sentenceBuffer = ""
        phase = .idle
    }

    /// Abandon this exchange but stay in the call — the "cancel that, go again" path,
    /// as distinct from hanging up. Leaves `inCall` alone so the screen keeps its timer
    /// and its End button.
    func cancelTurn() {
        llmTask?.cancel(); llmTask = nil
        speechTask?.cancel(); speechTask = nil
        liveTask?.cancel(); liveTask = nil
        liveSession?.cancel(); liveSession = nil
        if phase == .listening { mic.cancel() }
        player.stop()
        speechQueue.removeAll()
        speaking = false
        sentenceBuffer = ""
        replyFinished = false
        liveTranscript = ""
        phase = .idle
        if continuous { startListening(continuous: true) }
    }

    /// Silences the current reply completely. Cancelling the LLM matters as much as
    /// stopping the player: a reply still streaming would keep queueing sentences and
    /// start talking over the microphone that just opened.
    private func stopSpeaking() {
        llmTask?.cancel()
        llmTask = nil
        speechTask?.cancel()
        speechTask = nil
        player.stop()
        speechQueue.removeAll()
        speaking = false
        sentenceBuffer = ""
        replyFinished = false
    }

    func clearConversation() {
        stopEverything()
        turns = []
        history = []
        liveTranscript = ""
        error = nil
    }

    /// Send typed text instead of speaking it.
    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Typing mid-call replaces whatever was being said or heard, and keeps the
        // loop going if there was one — dropping it silently would leave the hang-up
        // button showing a call that never listens again.
        let resume = continuous
        if phase == .listening {
            mic.cancel()
            liveSession?.cancel()
            liveSession = nil
            liveTask?.cancel()
            liveTask = nil
        }
        stopSpeaking()
        append(.user, trimmed)
        continuous = resume
        ask()
    }

    // MARK: Steps

    private func transcribeAndAsk(wav: Data) async {
        do {
            let language = AppSettings.language.isEmpty ? nil : AppSettings.language
            let result = try await AudioCPPClient.current.transcribe(
                wav: wav, model: AppSettings.asrModel, language: language)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            liveTranscript = ""
            guard !text.isEmpty else {
                phase = .idle
                if continuous { startListening(continuous: true) }
                return
            }
            append(.user, text)
            ask()
        } catch is CancellationError {
            phase = .idle
        } catch {
            self.error = error.localizedDescription
            phase = .idle
            endCall()
        }
    }

    private func ask() {
        guard !AppSettings.llmModel.isEmpty else {
            error = "No language model is picked yet. Choose one in Settings."
            phase = .idle
            return
        }
        phase = .thinking
        replyFinished = false
        sentenceBuffer = ""

        let messages = [ChatClient.Message(role: .system, content: AppSettings.systemPrompt)] + history
        let model = AppSettings.llmModel
        let speakReplies = AppSettings.autoSpeakReplies && !AppSettings.ttsModel.isEmpty

        // The visible assistant turn grows as tokens arrive.
        let turnID = UUID()
        turns.append(Turn(id: turnID, role: .assistant, text: "", isPartial: true))

        llmTask = Task { [weak self] in
            guard let self else { return }
            var full = ""
            do {
                for try await token in ChatClient.current.stream(model: model, messages: messages) {
                    if Task.isCancelled { break }
                    full += token
                    self.updateTurn(turnID, text: full, partial: true)
                    if speakReplies { self.absorbForSpeech(token) }
                }
                // An AsyncThrowingStream does NOT throw CancellationError when the
                // consuming task is cancelled — it just stops yielding and the loop
                // ends normally. Without this check a barged-in reply would run the
                // whole completion path, re-arm replyFinished, and schedule a second
                // listen on top of the one the user just started.
                if Task.isCancelled {
                    self.updateTurn(turnID, text: full, partial: false)
                    return
                }
                self.updateTurn(turnID, text: full, partial: false)
                self.history.append(ChatClient.Message(role: .assistant, content: full))
                self.trimHistory()
                if speakReplies {
                    self.flushSentenceBuffer()
                    self.replyFinished = true
                    self.pumpSpeech()
                    if self.speechQueue.isEmpty && !self.speaking && !self.player.hasWork {
                        self.speechDrained()
                    }
                } else {
                    self.phase = .idle
                    if self.continuous { self.startListening(continuous: true) }
                }
            } catch is CancellationError {
                self.updateTurn(turnID, text: full, partial: false)
                self.phase = .idle
            } catch {
                self.updateTurn(turnID, text: full.isEmpty ? "—" : full, partial: false)
                self.error = error.localizedDescription
                self.phase = .idle
                self.endCall()
            }
        }
    }

    // MARK: Sentence-at-a-time speech

    /// Buffers tokens and releases a sentence as soon as one closes.
    private func absorbForSpeech(_ token: String) {
        sentenceBuffer += token
        while let sentence = Self.takeSentence(from: &sentenceBuffer) {
            enqueueSpeech(sentence)
        }
    }

    private func flushSentenceBuffer() {
        let rest = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        sentenceBuffer = ""
        if !rest.isEmpty { enqueueSpeech(rest) }
    }

    /// Pulls one speakable sentence off the front of `buffer`, or returns nil if the
    /// buffer doesn't hold a complete one yet.
    ///
    /// Two guards keep it from cutting in the wrong places: a sentence has to be at
    /// least 24 characters, so "3.5" and "Dr." don't become sentence ends, and a
    /// clause-length overflow releases at a comma so an LLM that rambles without
    /// punctuation still starts speaking.
    static func takeSentence(from buffer: inout String) -> String? {
        let enders: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
        let minimum = 24
        let overflow = 220

        var index = buffer.startIndex
        var count = 0
        while index < buffer.endIndex {
            let char = buffer[index]
            count += 1
            let next = buffer.index(after: index)
            if enders.contains(char), count >= minimum {
                // Only a real sentence end if what follows is whitespace or nothing,
                // and what precedes isn't a digit (so decimals survive).
                let followedByBreak = next == buffer.endIndex || buffer[next].isWhitespace
                let previous = index > buffer.startIndex ? buffer[buffer.index(before: index)] : " "
                if followedByBreak && !(char == "." && previous.isNumber) {
                    let sentence = String(buffer[buffer.startIndex...index])
                    buffer = String(buffer[next...])
                    let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
            }
            if char == "\n", count >= minimum {
                let sentence = String(buffer[buffer.startIndex..<index])
                buffer = String(buffer[next...])
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
                // `buffer` is different storage now, so `index` and `next` are stale:
                // carrying on with them would index off the end of the new string.
                index = buffer.startIndex
                count = 0
                continue
            }
            index = next
        }

        if count > overflow, let comma = buffer.firstIndex(where: { $0 == "," || $0 == ";" || $0 == ":" }),
           buffer.distance(from: buffer.startIndex, to: comma) >= minimum {
            let cut = buffer.index(after: comma)
            let sentence = String(buffer[buffer.startIndex..<cut])
            buffer = String(buffer[cut...])
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func enqueueSpeech(_ sentence: String) {
        speechQueue.append(sentence)
        pumpSpeech()
    }

    /// One sentence in flight at a time, so the audio comes out in the order it was written.
    private func pumpSpeech() {
        guard !speaking, !speechQueue.isEmpty else { return }
        speaking = true
        let sentence = speechQueue.removeFirst()
        phase = .speaking
        speechTask = Task { [weak self] in
            guard let self else { return }
            do {
                let wav = try await AudioCPPClient.current.speech(
                    model: AppSettings.ttsModel,
                    text: sentence,
                    voice: self.library.selection(AppSettings.selectedVoice),
                    options: ModelOptionStore.shared.requestFields(model: AppSettings.ttsModel))
                try Task.checkCancellation()
                self.player.play(wav: wav)
            } catch is CancellationError {
                // nothing to say about a cancelled sentence
            } catch {
                self.error = error.localizedDescription
            }
            self.speaking = false
            self.pumpSpeech()
            // If that sentence failed, the player never got a clip and so will never
            // report draining — without this the screen stays on "Speaking…" forever
            // and the hands-free loop stops.
            if self.speechQueue.isEmpty && !self.speaking && !self.player.hasWork {
                self.speechDrained()
            }
        }
    }

    /// The player ran out of audio. If the reply is complete too, the turn is over.
    private func speechDrained() {
        guard replyFinished, speechQueue.isEmpty, !speaking else { return }
        phase = .idle
        if continuous {
            // A beat of quiet, so the app isn't hearing the tail of its own speech.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let self, self.continuous, self.phase == .idle else { return }
                self.startListening(continuous: true)
            }
        }
    }

    // MARK: Live dictation (optional)

    private func startLiveSession() throws {
        let session = LiveTranscriber(client: .current,
                                      model: AppSettings.asrModel,
                                      sampleRate: mic.sampleRate,
                                      language: AppSettings.language.isEmpty ? nil : AppSettings.language)
        let stream = try session.start()
        liveSession = session
        liveTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .delta(let s): self.liveTranscript += s
                    case .done(let s): if !s.isEmpty { self.liveTranscript = s }
                    case .error(let m): self.error = m
                    }
                }
            } catch {
                // Live is a nicety; the recording is still transcribed the normal way
                // when listening finishes, so a failure here isn't worth an alert —
                // and whatever was already heard is left on screen rather than wiped.
            }
        }
    }

    // MARK: Turn bookkeeping

    /// The whole history is resent with every request, so it has to be bounded or a
    /// long conversation eventually overruns the model's context and every reply fails.
    private static let historyLimit = 24

    private func append(_ role: ChatClient.Message.Role, _ text: String) {
        turns.append(Turn(role: role, text: text))
        history.append(ChatClient.Message(role: role, content: text))
        trimHistory()
    }

    private func trimHistory() {
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        // Only the last user and assistant entries are ever read back (the call screen
        // has no transcript), so there is no reason to keep the rest.
        if turns.count > Self.historyLimit {
            turns.removeFirst(turns.count - Self.historyLimit)
        }
    }

    private func updateTurn(_ id: UUID, text: String, partial: Bool) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[i].text = text
        turns[i].isPartial = partial
    }
}
