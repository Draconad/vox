import SwiftUI
import UniformTypeIdentifiers

/// Dictation and transcription. Hold the button and talk, or bring in a file.
struct ListenView: View {

    @EnvironmentObject private var server: ServerStore

    @AppStorage(SettingsKey.asrModel) private var asrModel = ""
    @AppStorage(SettingsKey.language) private var language = ""
    @AppStorage(SettingsKey.autoStop) private var autoStop = true
    @AppStorage(SettingsKey.liveDictation) private var liveDictation = false

    @StateObject private var mic = MicRecorder()
    @ObservedObject private var activity = ServerActivity.shared

    @State private var transcript = ""
    @State private var partial = ""
    @State private var details: TranscriptionDetails?
    @State private var busy = false
    @State private var error: String?
    @State private var importing = false
    @State private var copied = false
    @State private var timing: String?

    @State private var liveSession: LiveTranscriber?
    @State private var liveTask: Task<Void, Never>?

    private var hasText: Bool { !transcript.isEmpty || !partial.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        StatusPill(connection: server.connection, name: "audio.cpp")
                        Spacer()
                        Button { importing = true } label: {
                            Label("File", systemImage: "folder")
                                .font(.footnote.weight(.medium))
                        }
                        .disabled(busy || mic.isRecording)
                    }

                    recorderCard
                    Card(padding: 12) {
                        ModelRow(title: "Model", selection: $asrModel,
                                 options: server.asrModels.map(\.id),
                                 allOptions: server.models.map(\.id),
                                 emptyHint: "No models — check the server")
                    }

                    if let loading = activity.label {
                        Card(padding: 12) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small).tint(Theme.warn)
                                Text(loading).font(.callout).monospacedDigit().foregroundStyle(Theme.warn)
                            }
                        }
                    }
                    if let error { errorCard(error) }
                    if hasText { transcriptCard }
                    if let details, (details.words?.isEmpty == false || details.speakerTurns?.isEmpty == false) {
                        detailCard(details)
                    }
                    // Last, for the same reason as Speak: the transcript is what you
                    // came for, and it shouldn't sit below the model's option list.
                    OptionsPanel(modelID: asrModel,
                                 declaredFamily: server.models.first { $0.id == asrModel }?.family)
                    Spacer(minLength: 8)
                }
                .padding(16)
            }
            .voxBackground()
            .navigationTitle("Listen")
            .onDisappear {
                // Leaving the tab mid-dictation would otherwise strand the upload
                // connection, its bound stream pair and the transcriber itself.
                if mic.isRecording { mic.cancel() }
                liveTask?.cancel()
                liveTask = nil
                liveSession?.cancel()
                liveSession = nil
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.audio, .wav, .mp3, .mpeg4Audio, .aiff],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { transcribeFile(url) }
            case .failure(let err): error = err.localizedDescription
            }
        }
    }

    // MARK: Recorder

    private var recorderCard: some View {
        Card {
            VStack(spacing: 16) {
                WaveformView(levels: mic.levels, active: mic.isRecording)
                    .frame(height: 68)

                HStack(alignment: .center, spacing: 16) {
                    Button {
                        mic.isRecording ? stopRecording() : startRecording()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(mic.isRecording ? Theme.bad : Theme.accent)
                                .frame(width: 62, height: 62)
                                .shadow(color: (mic.isRecording ? Theme.bad : Theme.accent).opacity(0.4),
                                        radius: 12, y: 4)
                            Image(systemName: mic.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 23, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || asrModel.isEmpty)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(mic.isRecording ? mic.duration.clockString
                             : (busy ? "Transcribing…" : "Ready"))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.primaryText)
                        Text(asrModel.isEmpty ? "Pick a model first"
                             : (liveDictation ? "Live — text appears as you speak"
                                : (autoStop ? "Stops when you stop talking" : "Tap again to stop")))
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    Spacer()
                }
            }
        }
    }

    private var transcriptCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(text: partial.isEmpty ? "Transcript" : "Live")
                    Spacer()
                    if let timing {
                        Text(timing).font(.caption2).foregroundStyle(Theme.tertiaryText).monospacedDigit()
                    }
                }
                Text(transcript.isEmpty ? partial : transcript)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = transcript.isEmpty ? partial : transcript
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_400_000_000)
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? Theme.good : Theme.accent)

                    Spacer()

                    Button {
                        transcript = ""
                        partial = ""
                        details = nil
                        timing = nil
                    } label: {
                        Text("Clear").font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func detailCard(_ details: TranscriptionDetails) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Detail")
                if let turns = details.speakerTurns, !turns.isEmpty {
                    ForEach(turns) { turn in
                        HStack(alignment: .top, spacing: 8) {
                            Text(turn.speakerId ?? "?")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 54, alignment: .leading)
                            Text(turn.text ?? "")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                } else if let words = details.words, !words.isEmpty {
                    Text("\(words.count) words timed"
                         + (details.seconds(words.last?.endSample).map { String(format: ", ending at %.1f s", $0) } ?? ""))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                if let language = details.language {
                    Text("Detected language: \(language)")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad)
                Text(message).font(.callout).foregroundStyle(Theme.primaryText)
            }
        }
    }

    // MARK: Actions

    private func startRecording() {
        guard !asrModel.isEmpty else {
            error = VoxError.noModelSelected("transcription").localizedDescription
            return
        }
        error = nil
        transcript = ""
        partial = ""
        details = nil
        timing = nil

        Task {
            guard await AudioSessionManager.requestMicrophone() else {
                error = "Vox needs microphone access. Turn it on in iOS Settings → Vox."
                return
            }
            do {
                var session: LiveTranscriber?
                if liveDictation {
                    session = LiveTranscriber(client: .current, model: asrModel,
                                              sampleRate: mic.sampleRate,
                                              language: language.isEmpty ? nil : language)
                    if let session {
                        let stream = try session.start()
                        liveSession = session
                        liveTask = Task {
                            do {
                                for try await event in stream {
                                    switch event {
                                    case .delta(let s): partial += s
                                    case .done(let s): if !s.isEmpty { partial = s }
                                    case .error(let m): error = m
                                    }
                                }
                            } catch {
                                // The recording still gets transcribed the normal way
                                // when you stop, so this isn't fatal.
                                self.error = "Live transcription dropped: \(error.localizedDescription)"
                            }
                        }
                    }
                }
                mic.configureSilenceDetection(threshold: 0.045, seconds: AppSettings.silenceSeconds)
                let captured = session
                try mic.start(
                    onChunk: captured.map { s in { (chunk: Data) in s.append(chunk) } },
                    onSilence: autoStop ? { Task { @MainActor in stopRecording() } } : nil
                )
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func stopRecording() {
        guard mic.isRecording else { return }
        let wav = mic.stop()
        liveSession?.finish()
        liveSession = nil
        liveTask?.cancel()
        liveTask = nil
        guard let wav else {
            error = "That was too short to transcribe."
            return
        }
        transcribe(wav: wav)
    }

    private func transcribeFile(_ url: URL) {
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                // Whole file, no trim: this is a transcription, not a reference clip.
                // Decoding runs off the main thread — an hour-long recording would
                // otherwise freeze the UI long enough for the watchdog to kill the app.
                let converted = try await Task.detached(priority: .userInitiated) {
                    try AudioConverter.toWAV(url: url)
                }.value
                try await run(wav: converted.wav)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func transcribe(wav: Data) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await run(wav: wav)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Uses the `/details` route so word timings and speaker turns aren't thrown away;
    /// it returns the same `text` as the plain route.
    private func run(wav: Data) async throws {
        let lang = language.isEmpty ? nil : language
        let result = try await AudioCPPClient.current
            .transcribeDetails(wav: wav, model: asrModel, language: lang)
        transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        details = result
        if let t = result.timing, let wall = t.wallMs, let audio = t.audioDurationMs, audio > 0 {
            timing = String(format: "%.1f s for %.1f s of audio (%.2fx)", wall / 1000, audio / 1000, wall / audio)
        } else {
            timing = nil
        }
    }
}
