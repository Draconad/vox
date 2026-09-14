import SwiftUI
import UniformTypeIdentifiers

/// The voice library: reference clips that live on this phone and get inlined into
/// every cloning request.
struct VoicesView: View {

    @EnvironmentObject private var server: ServerStore
    @EnvironmentObject private var library: VoiceLibrary

    @AppStorage(SettingsKey.selectedVoice) private var voiceToken = ""

    @State private var importing = false
    @State private var recording = false
    @State private var working: String?
    @State private var error: String?
    @State private var editing: StoredVoice?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    addCard
                    if let working { busyCard(working) }
                    if let error { errorCard(error) }
                    localSection
                    serverSection
                    explainer
                    Spacer(minLength: 8)
                }
                .padding(16)
            }
            .voxBackground()
            .navigationTitle("Voices")
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.audio, .wav, .mp3, .mpeg4Audio, .aiff],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { importClip(url) }
            case .failure(let err): error = err.localizedDescription
            }
        }
        .sheet(isPresented: $recording) {
            RecordReferenceSheet { wav, duration in
                addClip(wav: wav, duration: duration, name: "Recorded voice")
            }
        }
        .sheet(item: $editing) { voice in
            VoiceDetailSheet(voice: voice)
        }
    }

    // MARK: Sections

    private var addCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "Add a voice")
                Text("A 10–15 second clip of clean speech is all a cloning model wants. Vox converts whatever you give it to 16 kHz mono WAV and trims it.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                HStack(spacing: 12) {
                    Button { recording = true } label: {
                        actionTile(icon: "mic.fill", title: "Record")
                    }.buttonStyle(.plain)
                    Button { importing = true } label: {
                        actionTile(icon: "folder.fill", title: "From Files")
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func actionTile(icon: String, title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20))
            Text(title).font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cardRaised))
        .foregroundStyle(Theme.accent)
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "On this phone")
            if library.voices.isEmpty {
                Card {
                    Text("No reference clips yet.")
                        .font(.callout)
                        .foregroundStyle(Theme.tertiaryText)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(library.voices) { voice in
                        voiceRow(voice)
                    }
                }
            }
        }
    }

    private func voiceRow(_ voice: StoredVoice) -> some View {
        let isSelected = VoiceToken(stored: voiceToken).stored == VoiceToken.local(voice.id).stored
        return Card(padding: 14) {
            HStack(spacing: 12) {
                Button {
                    voiceToken = VoiceToken.local(voice.id).stored
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.tertiaryText)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    Text(voice.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text("\(voice.duration.clockString) · \(voice.byteCount / 1024) KB"
                         + (voice.referenceText.isEmpty ? " · no transcript" : ""))
                        .font(.caption)
                        .foregroundStyle(voice.referenceText.isEmpty ? Theme.warn : Theme.tertiaryText)
                }
                Spacer()
                Button { editing = voice } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "On the server")
            Card {
                if server.serverVoices.isEmpty {
                    Text(AppSettings.ttsModel.isEmpty
                         ? "Pick a TTS model in Settings to see the voices it offers."
                         : "This model reports no built-in voices, presets or voice_dir entries. Cloning from a clip above still works.")
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    VStack(spacing: 0) {
                        ForEach(server.serverVoices, id: \.self) { name in
                            let isSelected = voiceToken == VoiceToken.server(name).stored
                            Button {
                                voiceToken = VoiceToken.server(name).stored
                            } label: {
                                HStack {
                                    Text(name).foregroundStyle(Theme.primaryText)
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                    }
                                }
                                .padding(.vertical, 11)
                            }
                            .buttonStyle(.plain)
                            if name != server.serverVoices.last { Divider().overlay(Theme.hairline) }
                        }
                    }
                }
            }
        }
    }

    private var explainer: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "How cloning gets there")
                Text("Clips never leave this phone as files. Each request inlines the WAV as base64 in `voice_ref`, which audio.cpp accepts up to 5 MB — so there's nothing to stage on the server and no companion container to run.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                Text("The transcript goes along as `reference_text`. Models clone noticeably better with it, which is why Vox transcribes each new clip for you.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func busyCard(_ message: String) -> some View {
        Card {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text(message).font(.callout).foregroundStyle(Theme.secondaryText)
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

    // MARK: Adding

    private func importClip(_ url: URL) {
        error = nil
        working = "Converting \(url.lastPathComponent)…"
        let name = url.deletingPathExtension().lastPathComponent
        Task {
            do {
                // Off the main thread: decoding a long import would otherwise block the
                // UI for its whole duration, spinner included.
                let converted = try await Task.detached(priority: .userInitiated) {
                    try AudioConverter.toReferenceWAV(url: url)
                }.value
                addClip(wav: converted.wav, duration: converted.duration, name: name,
                        trimmed: converted.wasTrimmed)
            } catch {
                working = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func addClip(wav: Data, duration: Double, name: String, trimmed: Bool = false) {
        Task {
            var transcript = ""
            let asr = AppSettings.asrModel
            if AppSettings.autoReferenceText && !asr.isEmpty {
                working = "Transcribing the clip for its reference text…"
                do {
                    let language = AppSettings.language.isEmpty ? nil : AppSettings.language
                    transcript = try await AudioCPPClient.current
                        .transcribe(wav: wav, model: asr, language: language)
                        .text.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    // A missing transcript is a quality hit, not a failure - save it anyway
                    // and let them type one on the detail screen.
                    self.error = "Saved the clip, but couldn't transcribe it: \(error.localizedDescription)"
                }
            }
            working = nil
            do {
                let voice = try library.add(wav: wav, name: name,
                                            referenceText: transcript, duration: duration)
                voiceToken = VoiceToken.local(voice.id).stored
                if trimmed && error == nil {
                    error = "Trimmed to the first \(Int(AudioConverter.referenceClipSeconds)) seconds."
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Picker

/// Pushed from the Speak and Talk screens: one list of every way to choose a speaker.
struct VoicePickerView: View {
    @Binding var selection: String
    @EnvironmentObject private var server: ServerStore
    @EnvironmentObject private var library: VoiceLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                row(token: .serverDefault, title: "Server default",
                    subtitle: "Whatever default_voice_preset the model was configured with")
            }
            if !library.voices.isEmpty {
                Section("Cloned from this phone") {
                    ForEach(library.voices) { voice in
                        row(token: .local(voice.id), title: voice.name,
                            subtitle: voice.referenceText.isEmpty
                                ? "\(voice.duration.clockString) · no transcript"
                                : "\(voice.duration.clockString) · \(voice.referenceText)")
                    }
                }
            }
            if !server.serverVoices.isEmpty {
                Section("On the server") {
                    ForEach(server.serverVoices, id: \.self) { name in
                        row(token: .server(name), title: name, subtitle: nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .voxBackground()
        .navigationTitle("Voice")
    }

    private func row(token: VoiceToken, title: String, subtitle: String?) -> some View {
        Button {
            selection = token.stored
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.primaryText)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if selection == token.stored {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.card)
    }
}

// MARK: - Recording sheet

/// Records a reference clip, capped at 15 seconds because that's all the models want.
struct RecordReferenceSheet: View {
    var onDone: (Data, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var mic = MicRecorder()
    @State private var error: String?
    @State private var denied = false

    private let limit = AudioConverter.referenceClipSeconds

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                WaveformView(levels: mic.levels, active: mic.isRecording)
                    .frame(height: 90)
                    .padding(.horizontal, 24)

                Text(mic.duration.clockString)
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(mic.isRecording ? Theme.primaryText : Theme.tertiaryText)

                Text(mic.isRecording
                     ? "Read a couple of natural sentences. Stops on its own at \(Int(limit)) s."
                     : "Somewhere quiet, normal speaking voice.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 32)

                if let error {
                    Text(error).font(.caption).foregroundStyle(Theme.bad)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }

                Button {
                    mic.isRecording ? finish() : begin()
                } label: {
                    ZStack {
                        Circle()
                            .fill(mic.isRecording ? Theme.bad : Theme.accent)
                            .frame(width: 84, height: 84)
                        Image(systemName: mic.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(denied)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .voxBackground()
            .navigationTitle("Record a clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { mic.cancel(); dismiss() }
                }
            }
            .onChange(of: mic.duration) { _, new in
                if new >= limit && mic.isRecording { finish() }
            }
        }
    }

    private func begin() {
        error = nil
        Task {
            guard await AudioSessionManager.requestMicrophone() else {
                denied = true
                error = "Vox needs microphone access. Turn it on in iOS Settings → Vox."
                return
            }
            do {
                try mic.start()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func finish() {
        let duration = mic.duration
        guard let wav = mic.stop() else {
            error = "That was too short to use."
            return
        }
        onDone(wav, duration)
        dismiss()
    }
}

// MARK: - Detail sheet

/// Rename, fix the transcript, hear it back, try it, or delete.
struct VoiceDetailSheet: View {
    let voice: StoredVoice

    @EnvironmentObject private var library: VoiceLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var referenceText = ""
    @State private var busy: String?
    @State private var error: String?
    @State private var confirmDelete = false
    @StateObject private var player = SpeechPlayer()

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                }
                Section {
                    TextEditor(text: $referenceText)
                        .frame(minHeight: 90)
                } header: {
                    Text("Reference text")
                } footer: {
                    Text("What is actually said in the clip. Sent as `reference_text`; cloning is noticeably better with it right.")
                }

                Section("Clip") {
                    HStack {
                        Button {
                            if player.isPlaying { player.stop() }
                            else if let wav = library.wav(for: voice) { player.play(wav: wav) }
                        } label: {
                            Label(player.isPlaying ? "Stop" : "Play the reference clip",
                                  systemImage: player.isPlaying ? "stop.fill" : "play.fill")
                        }
                    }
                    HStack {
                        Text("Length")
                        Spacer()
                        Text(voice.duration.clockString).foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Text("Inline size")
                        Spacer()
                        Text("\(voice.byteCount / 1024) KB").foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        retranscribe()
                    } label: {
                        Label(busy == nil ? "Transcribe it again" : busy!, systemImage: "text.viewfinder")
                    }
                    .disabled(busy != nil || AppSettings.asrModel.isEmpty)
                    Button {
                        testSpeak()
                    } label: {
                        Label("Say a test line in this voice", systemImage: "speaker.wave.2.fill")
                    }
                    .disabled(busy != nil || AppSettings.ttsModel.isEmpty)
                }

                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(Theme.bad) }
                }

                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete this voice", systemImage: "trash")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .voxBackground()
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { player.stop(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }.fontWeight(.semibold)
                }
            }
            .onAppear {
                name = voice.name
                referenceText = voice.referenceText
            }
            .confirmationDialog("Delete \"\(voice.name)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    player.stop()
                    library.delete(voice)
                    dismiss()
                }
            }
        }
    }

    private func save() {
        library.rename(voice, to: name)
        library.setReferenceText(voice, referenceText)
        player.stop()
        dismiss()
    }

    private func retranscribe() {
        guard let wav = library.wav(for: voice) else { return }
        error = nil
        busy = "Transcribing…"
        Task {
            defer { busy = nil }
            do {
                let language = AppSettings.language.isEmpty ? nil : AppSettings.language
                referenceText = try await AudioCPPClient.current
                    .transcribe(wav: wav, model: AppSettings.asrModel, language: language)
                    .text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func testSpeak() {
        error = nil
        busy = "Generating…"
        let wav = library.wav(for: voice)
        Task {
            defer { busy = nil }
            do {
                var selection = VoiceSelection.serverDefault
                if let wav { selection = .inline(wav: wav, referenceText: referenceText) }
                let speech = try await AudioCPPClient.current.speech(
                    model: AppSettings.ttsModel,
                    text: "This is how I sound. The quick brown fox jumps over the lazy dog.",
                    voice: selection,
                    options: ModelOptionStore.shared.requestFields(model: AppSettings.ttsModel))
                player.play(wav: speech)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
