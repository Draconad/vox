import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var server: ServerStore
    @EnvironmentObject private var library: VoiceLibrary

    @AppStorage(SettingsKey.serverURL) private var serverURL = ""
    @AppStorage(SettingsKey.apiKey) private var apiKey = ""
    @AppStorage(SettingsKey.llmURL) private var llmURL = ""
    @AppStorage(SettingsKey.llmKey) private var llmKey = ""

    @AppStorage(SettingsKey.ttsModel) private var ttsModel = ""
    @AppStorage(SettingsKey.asrModel) private var asrModel = ""
    @AppStorage(SettingsKey.llmModel) private var llmModel = ""
    @AppStorage(SettingsKey.language) private var language = ""

    @AppStorage(SettingsKey.autoStop) private var autoStop = true
    @AppStorage(SettingsKey.silenceSeconds) private var silenceSeconds = 1.4
    @AppStorage(SettingsKey.autoSpeakReplies) private var autoSpeakReplies = true
    @AppStorage(SettingsKey.handsFreeLoop) private var handsFreeLoop = true
    @AppStorage(SettingsKey.autoReferenceText) private var autoReferenceText = true

    @AppStorage(SettingsKey.liveDictation) private var liveDictation = false
    @AppStorage(SettingsKey.streamingTTS) private var streamingTTS = false
    @AppStorage(SettingsKey.streamPCMRate) private var streamPCMRate = 24_000

    @ObservedObject private var prompts = PromptLibrary.shared

    @State private var testing = false
    @State private var testResult: String?
    @State private var unloading = false

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                modelSection
                conversationSection
                dictationSection
                advancedSection
                maintenanceSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .voxBackground()
            .navigationTitle("Settings")
            .onChange(of: ttsModel) { _, _ in
                Task { await server.refreshVoices() }
            }
        }
    }

    // MARK: Server

    private var serverSection: some View {
        Section {
            LabeledContent("audio.cpp") {
                TextField("http://tower.local:8080", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("API key") {
                SecureField("none", text: $apiKey)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("LLM (Ollama)") {
                TextField("http://tower.local:11434", text: $llmURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("LLM key") {
                SecureField("none", text: $llmKey)
                    .multilineTextAlignment(.trailing)
            }

            Button {
                test()
            } label: {
                HStack {
                    if testing { ProgressView().controlSize(.small) }
                    Text(testing ? "Testing…" : "Test both servers")
                }
            }
            .disabled(testing)

            if let testResult {
                Text(testResult).font(.footnote).foregroundStyle(
                    testResult.contains("unreachable") || testResult.contains("Couldn't")
                        ? Theme.bad : Theme.good)
            }
        } header: {
            Text("Servers")
        } footer: {
            Text("audio.cpp has no authentication of its own — leave the key blank unless you've put a reverse proxy in front of it. Plain http on your LAN is fine; Vox is built to allow it.")
        }
    }

    // MARK: Models

    private var modelSection: some View {
        Section {
            picker("Text to speech", selection: $ttsModel,
                   likely: server.ttsModels.map(\.id), all: server.models.map(\.id))
            picker("Transcription", selection: $asrModel,
                   likely: server.asrModels.map(\.id), all: server.models.map(\.id))
            picker("Language model", selection: $llmModel,
                   likely: server.llmModels, all: server.llmModels)
            LabeledContent("Language") {
                TextField("auto", text: $language)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            Button("Reload models and voices") {
                Task {
                    await server.refresh()
                    server.autoSelectModels()
                    await server.refreshVoices()
                }
            }
        } header: {
            Text("Models")
        } footer: {
            Text("Only models listed in the server's server.json appear here. Leave Language blank to let the model decide, or set a code like en or en-US.")
        }
    }

    private func picker(_ title: String, selection: Binding<String>,
                        likely: [String], all: [String]) -> some View {
        LabeledContent(title) {
            if all.isEmpty {
                Text("—").foregroundStyle(.secondary)
            } else {
                Menu {
                    Button("None") { selection.wrappedValue = "" }
                    if !likely.isEmpty {
                        Section("Likely") {
                            ForEach(likely, id: \.self) { id in Button(id) { selection.wrappedValue = id } }
                        }
                    }
                    let rest = all.filter { !likely.contains($0) }
                    if !rest.isEmpty {
                        Section(likely.isEmpty ? "Models" : "Other") {
                            ForEach(rest, id: \.self) { id in Button(id) { selection.wrappedValue = id } }
                        }
                    }
                } label: {
                    Text(selection.wrappedValue.isEmpty ? "Choose" : selection.wrappedValue)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: Conversation

    private var conversationSection: some View {
        Section {
            Toggle("Speak replies out loud", isOn: $autoSpeakReplies)
            Toggle("Keep listening after each reply", isOn: $handsFreeLoop)
            NavigationLink {
                PromptsView()
            } label: {
                LabeledContent("Personality") {
                    Text(prompts.selected.name).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Conversation")
        } footer: {
            Text("Replies are spoken a sentence at a time, so the first sentence starts playing while the rest is still being written.")
        }
    }

    // MARK: Dictation

    private var dictationSection: some View {
        Section {
            Toggle("Stop when I stop talking", isOn: $autoStop)
            if autoStop {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Pause before stopping")
                        Spacer()
                        Text(String(format: "%.1f s", silenceSeconds))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $silenceSeconds, in: 0.6...4.0, step: 0.1)
                }
            }
            Toggle("Transcribe new voice clips automatically", isOn: $autoReferenceText)
        } header: {
            Text("Listening")
        } footer: {
            Text("A longer pause suits dictating something you have to think about mid-sentence.")
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section {
            Toggle("Live transcription while speaking", isOn: $liveDictation)
            Toggle("Streaming speech", isOn: $streamingTTS)
            if streamingTTS {
                LabeledContent("Streamed PCM rate") {
                    Picker("", selection: $streamPCMRate) {
                        Text("16000").tag(16_000)
                        Text("22050").tag(22_050)
                        Text("24000").tag(24_000)
                        Text("44100").tag(44_100)
                        Text("48000").tag(48_000)
                    }
                    .labelsHidden()
                }
            }
        } header: {
            Text("Streaming")
        } footer: {
            Text("Both need a model configured with mode: \"streaming\" in server.json — an offline model ignores them. Streamed audio carries no header, so if the voice comes out too low or too high, the PCM rate above is the thing to change.")
        }
    }

    // MARK: Maintenance

    private var maintenanceSection: some View {
        Section {
            Button {
                unloadAll()
            } label: {
                HStack {
                    if unloading { ProgressView().controlSize(.small) }
                    Text("Free the GPU (unload all models)")
                }
            }
            .disabled(unloading || !server.connection.isOnline)
        } header: {
            Text("Server")
        } footer: {
            Text("Unloads every resident model so the 3090 gets its VRAM back. The next request reloads what it needs on its own.")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Build") {
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Voice clips stored") {
                Text("\(library.voices.count)").foregroundStyle(.secondary)
            }
        } header: {
            Text("About")
        } footer: {
            Text("Vox talks straight to audio.cpp and Ollama. Nothing runs in between, and reference clips never leave this phone as files — they're inlined in each request.")
        }
    }

    // MARK: Actions

    private func test() {
        testing = true
        testResult = nil
        Task {
            defer { testing = false }
            var lines: [String] = []
            do {
                let health = try await AudioCPPClient.current.health()
                let models = try await AudioCPPClient.current.models()
                lines.append("audio.cpp: ready, \(max(health.configuredModels, models.count)) model(s)")
            } catch {
                lines.append("audio.cpp unreachable — \(error.localizedDescription)")
            }
            if llmURL.isEmpty {
                lines.append("LLM: no address set")
            } else {
                do {
                    let list = try await ChatClient.current.models()
                    lines.append("LLM: ready, \(list.count) model(s)")
                } catch {
                    lines.append("LLM unreachable — \(error.localizedDescription)")
                }
            }
            testResult = lines.joined(separator: "\n")
            await server.refresh()
            server.autoSelectModels()
            await server.refreshVoices()
        }
    }

    private func unloadAll() {
        unloading = true
        testResult = nil
        Task {
            defer { unloading = false }
            do {
                let result = try await AudioCPPClient.current.unloadAllModels()
                let names = result.unloaded ?? []
                testResult = names.isEmpty ? "Nothing was loaded." : "Unloaded \(names.joined(separator: ", "))."
            } catch {
                testResult = "Couldn't unload — \(error.localizedDescription)"
            }
        }
    }
}
