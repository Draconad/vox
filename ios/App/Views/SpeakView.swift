import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Text in, speech out. The screen that exists to answer "does this voice sound right".
struct SpeakView: View {

    @EnvironmentObject private var server: ServerStore
    @EnvironmentObject private var library: VoiceLibrary

    @AppStorage(SettingsKey.ttsModel) private var ttsModel = ""
    @AppStorage(SettingsKey.selectedVoice) private var voiceToken = ""
    @AppStorage(SettingsKey.streamingTTS) private var streamingTTS = false

    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    @State private var lastWAV: Data?
    @State private var lastSeconds: Double = 0
    @State private var generatedIn: Double?
    @State private var exportURL: URL?
    @State private var showingShare = false

    @StateObject private var player = SpeechPlayer()
    @ObservedObject private var activity = ServerActivity.shared

    private var voice: VoiceToken { VoiceToken(stored: voiceToken) }
    private var canGenerate: Bool {
        !ttsModel.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    editor
                    controls
                    if let error { errorCard(error) }
                    // Above the controls panel on purpose: replaying the last take is
                    // the thing you do most, and it shouldn't be a scroll away past a
                    // screenful of sliders.
                    if lastWAV != nil { resultCard }
                    OptionsPanel(modelID: ttsModel,
                                 declaredFamily: server.models.first { $0.id == ttsModel }?.family)
                    Spacer(minLength: 8)
                }
                .padding(16)
            }
            .voxBackground()
            .navigationTitle("Speak")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await server.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .sheet(isPresented: $showingShare) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            StatusPill(connection: server.connection, name: "audio.cpp")
            Spacer()
            if case .offline = server.connection {
                Text("Check Settings")
                    .font(.caption)
                    .foregroundStyle(Theme.bad)
            }
        }
    }

    private var editor: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Text")
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.primaryText)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Type or paste something to say…")
                                .foregroundStyle(Theme.tertiaryText)
                                .allowsHitTesting(false)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                        }
                    }
                HStack {
                    Text("\(text.count) characters")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer()
                    if !text.isEmpty {
                        Button("Clear") { text = "" }
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Card(padding: 12) {
                VStack(spacing: 0) {
                    ModelRow(title: "Model", selection: $ttsModel,
                             options: server.ttsModels.map(\.id),
                             allOptions: server.models.map(\.id),
                             emptyHint: "No models — check the server")
                    Divider().overlay(Theme.hairline)
                    NavigationLink {
                        VoicePickerView(selection: $voiceToken)
                    } label: {
                        HStack {
                            Text("Voice").foregroundStyle(Theme.primaryText)
                            Spacer()
                            Text(library.label(voice))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 4)
                    }
                }
            }

            BusyButton(title: player.isPlaying ? "Playing…" : "Generate and play",
                       systemImage: "play.fill",
                       busy: busy,
                       enabled: canGenerate) {
                generate()
            }

            if let loading = activity.label {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(Theme.warn)
                    Text(loading).font(.caption).monospacedDigit().foregroundStyle(Theme.warn)
                }
            }

            if !ttsModel.isEmpty && streamingTTS && !server.isStreaming(ttsModel) {
                Text("Streaming is on, but \"\(ttsModel)\" isn't configured with mode: \"streaming\" on the server. Vox will fall back to a normal request.")
                    .font(.caption)
                    .foregroundStyle(Theme.warn)
                    .padding(.horizontal, 4)
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

    private var resultCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "Last result")
                HStack(spacing: 14) {
                    Button {
                        if player.isPlaying { player.stop() } else if let lastWAV { player.play(wav: lastWAV) }
                    } label: {
                        Image(systemName: player.isPlaying ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(lastSeconds.clockString)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.primaryText)
                        if let generatedIn {
                            let ratio = lastSeconds > 0 ? generatedIn / lastSeconds : 0
                            Text(String(format: "generated in %.1f s · %.2fx realtime", generatedIn, ratio))
                                .font(.caption)
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                    Spacer()
                    Button {
                        share()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Actions

    private func generate() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        error = nil
        busy = true
        player.stop()
        let selection = library.selection(voice)
        let started = Date()

        Task {
            defer { busy = false }
            let client = AudioCPPClient.current
            do {
                let options = ModelOptionStore.shared.requestFields(model: ttsModel)
                if streamingTTS && server.isStreaming(ttsModel) {
                    let rate = AppSettings.streamPCMRate
                    try player.openStream(sampleRate: rate)
                    // Even if the stream throws mid-way, the player has to be told the
                    // audio has ended — otherwise it stays "playing" forever and the
                    // engine is left running on the audio session.
                    defer { player.endStream() }
                    var pcm = Data()
                    for try await chunk in client.speechStream(model: ttsModel, text: body,
                                                               voice: selection, options: options) {
                        pcm.append(chunk)
                        player.push(pcm: chunk)
                    }
                    guard !pcm.isEmpty else { throw VoxError.emptyResponse }
                    // Keep a playable copy so the result card can replay and share it.
                    lastWAV = WAV.encode(pcm16: pcm, sampleRate: rate, channels: 1)
                    lastSeconds = Double(pcm.count / 2) / Double(rate)
                } else {
                    let wav = try await client.speech(model: ttsModel, text: body,
                                                      voice: selection, options: options)
                    lastWAV = wav
                    lastSeconds = WAV.info(wav)?.duration ?? 0
                    player.play(wav: wav)
                }
                generatedIn = Date().timeIntervalSince(started)
            } catch is CancellationError {
                // nothing to report
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func share() {
        guard let lastWAV else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-speech-\(Int(Date().timeIntervalSince1970)).wav")
        do {
            try lastWAV.write(to: url, options: .atomic)
            exportURL = url
            showingShare = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A picker row that lists the likely models first but still offers everything the
/// server has, because the task guess is only a guess.
struct ModelRow: View {
    var title: String
    @Binding var selection: String
    var options: [String]
    var allOptions: [String]
    var emptyHint: String

    var body: some View {
        HStack {
            Text(title).foregroundStyle(Theme.primaryText)
            Spacer()
            if allOptions.isEmpty {
                Text(emptyHint).font(.caption).foregroundStyle(Theme.tertiaryText)
            } else {
                Menu {
                    if !options.isEmpty {
                        Section("Likely") {
                            ForEach(options, id: \.self) { id in
                                Button(id) { selection = id }
                            }
                        }
                    }
                    let rest = allOptions.filter { !options.contains($0) }
                    if !rest.isEmpty {
                        Section(options.isEmpty ? "Models" : "Other models") {
                            ForEach(rest, id: \.self) { id in
                                Button(id) { selection = id }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selection.isEmpty ? "Choose" : selection)
                            .foregroundStyle(selection.isEmpty ? Theme.tertiaryText : Theme.secondaryText)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
    }
}

/// UIActivityViewController, for saving or sending a generated clip.
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
