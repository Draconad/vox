import Foundation
import SwiftUI

/// What the app knows about the server right now: is it up, what models are configured,
/// what voices does it offer, and what will the LLM answer to.
@MainActor
final class ServerStore: ObservableObject {

    enum Connection: Equatable {
        case unknown
        case checking
        case online(models: Int)
        case offline(String)

        var isOnline: Bool { if case .online = self { return true }; return false }
    }

    @Published var connection: Connection = .unknown
    @Published var models: [ModelList.Entry] = []
    @Published var serverVoices: [String] = []
    @Published var llmConnection: Connection = .unknown
    @Published var llmModels: [String] = []

    /// Set when a refresh found the server but something else went wrong, e.g. the
    /// voices call failed. Shown as a note rather than an alert.
    @Published var note: String?

    private var refreshing = false

    // MARK: Refresh

    /// Checks the audio.cpp server and the LLM in parallel. Safe to call on every
    /// appearance of a screen; overlapping calls collapse into one.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        connection = .checking
        llmConnection = .checking
        note = nil

        async let audio: Void = refreshAudioServer()
        async let llm: Void = refreshLLM()
        _ = await (audio, llm)
    }

    private func refreshAudioServer() async {
        let client = AudioCPPClient.current
        do {
            let health = try await client.health()
            var list = try await client.models()
            // Keep a stable, readable order in every picker.
            list.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            models = list
            connection = .online(models: max(health.configuredModels, list.count))
            await refreshVoices()
        } catch {
            models = []
            serverVoices = []
            connection = .offline(error.localizedDescription)
        }
    }

    /// Voices depend on which TTS model is selected, so this is also called when it
    /// changes — from Settings and from the Talk screen's chip, sometimes both at once.
    /// The answer is discarded if the model moved on while it was in flight, so a slow
    /// reply for the old model can't overwrite a fast one for the new.
    func refreshVoices() async {
        let model = AppSettings.ttsModel
        guard !model.isEmpty else {
            serverVoices = []
            reconcileSelectedVoice()
            return
        }
        do {
            let voices = try await AudioCPPClient.current.voices(model: model).sorted()
            guard AppSettings.ttsModel == model else { return }
            serverVoices = voices
            note = nil
            // Only reconcile against a listing that actually arrived. Doing it after a
            // failure, or after a server that legitimately reports none, would throw
            // away a working model-native voice id.
            if !voices.isEmpty { reconcileSelectedVoice() }
        } catch {
            guard AppSettings.ttsModel == model else { return }
            serverVoices = []
            note = "Couldn't list voices: \(error.localizedDescription)"
        }
    }

    /// A server voice belongs to the model that offered it. After switching models, a
    /// selection the new one doesn't know would fail on the next request, so it's
    /// dropped back to the default here rather than at generation time.
    private func reconcileSelectedVoice() {
        if case .server(let name) = AppSettings.selectedVoice, !serverVoices.contains(name) {
            AppSettings.selectedVoice = .serverDefault
        }
    }

    private func refreshLLM() async {
        guard !AppSettings.llmURL.isEmpty else {
            llmConnection = .unknown
            llmModels = []
            return
        }
        do {
            let list = try await ChatClient.current.models()
            llmModels = list
            llmConnection = .online(models: list.count)
        } catch {
            llmModels = []
            llmConnection = .offline(error.localizedDescription)
        }
    }

    // MARK: Picking models

    /// audio.cpp sends `task` on its model entries when it can. When it doesn't, fall
    /// back to the family and id — these names are conventional enough to guess from,
    /// and the picker still lists everything so a wrong guess is recoverable.
    private static func looksLike(_ entry: ModelList.Entry, task: String, hints: [String]) -> Bool {
        if let declared = entry.task?.lowercased() {
            return declared == task
        }
        let haystack = (entry.id + " " + (entry.family ?? "")).lowercased()
        return hints.contains { haystack.contains($0) }
    }

    var ttsModels: [ModelList.Entry] {
        models.filter { Self.looksLike($0, task: "tts", hints: ["tts", "voice", "speech", "vox", "kokoro", "orpheus"]) }
    }

    var asrModels: [ModelList.Entry] {
        models.filter { Self.looksLike($0, task: "asr", hints: ["asr", "stt", "whisper", "parakeet", "nemotron", "voxtral", "transcri"]) }
    }

    /// Models the server says can stream. Used to warn when streaming TTS is switched
    /// on for a model that was configured `mode: "offline"`.
    func isStreaming(_ id: String) -> Bool {
        models.first { $0.id == id }?.mode?.lowercased() == "streaming"
    }

    /// Fills in any picker that is still empty but has an obvious single answer, so a
    /// fresh install is usable without visiting Settings first.
    func autoSelectModels() {
        if AppSettings.ttsModel.isEmpty, let first = (ttsModels.first ?? models.first) {
            AppSettings.defaults.set(first.id, forKey: SettingsKey.ttsModel)
        }
        if AppSettings.asrModel.isEmpty, let first = (asrModels.first ?? models.first) {
            AppSettings.defaults.set(first.id, forKey: SettingsKey.asrModel)
        }
        if AppSettings.llmModel.isEmpty, let first = llmModels.first {
            AppSettings.defaults.set(first, forKey: SettingsKey.llmModel)
        }
    }
}
