import Foundation

/// UserDefaults keys, shared between `@AppStorage` in the views and plain code.
enum SettingsKey {
    static let serverURL = "serverURL"
    static let apiKey = "apiKey"
    static let llmURL = "llmURL"
    static let llmKey = "llmKey"

    static let ttsModel = "ttsModel"
    static let asrModel = "asrModel"
    static let llmModel = "llmModel"

    static let language = "language"
    static let systemPrompt = "systemPrompt"

    static let selectedVoice = "selectedVoice"
    static let streamingTTS = "streamingTTS"
    static let streamPCMRate = "streamPCMRate"
    static let liveDictation = "liveDictation"

    static let autoStop = "autoStopOnSilence"
    static let silenceSeconds = "silenceSeconds"
    static let autoSpeakReplies = "autoSpeakReplies"
    static let handsFreeLoop = "handsFreeLoop"
    static let autoReferenceText = "autoReferenceText"
    static let showCaptions = "showCaptions"
    static let selectedPromptID = "selectedPromptID"
}

/// How a TTS request should choose its voice. Stored as a single string so it fits
/// in `@AppStorage` and survives a voice being deleted.
enum VoiceToken {
    case serverDefault
    /// A name the server knows: a config preset, a `voice_dir` wav, or a cached voice id.
    case server(String)
    /// A clip in the on-device library, cloned inline on every request.
    case local(UUID)

    var stored: String {
        switch self {
        case .serverDefault: return ""
        case .server(let name): return "server:" + name
        case .local(let id): return "local:" + id.uuidString
        }
    }

    init(stored: String) {
        if stored.hasPrefix("server:") {
            self = .server(String(stored.dropFirst(7)))
        } else if stored.hasPrefix("local:"), let id = UUID(uuidString: String(stored.dropFirst(6))) {
            self = .local(id)
        } else {
            self = .serverDefault
        }
    }
}

enum AppSettings {
    static let defaults = UserDefaults.standard

    static let defaultSystemPrompt =
        "You are a concise voice assistant. Your replies are read aloud, so answer in "
        + "plain spoken sentences: no markdown, no bullet points, no code blocks, no "
        + "emoji. Keep it to a few sentences unless asked for more."

    static func registerDefaults() {
        defaults.register(defaults: [
            SettingsKey.serverURL: "http://tower.local:8080",
            SettingsKey.apiKey: "",
            SettingsKey.llmURL: "http://tower.local:11434",
            SettingsKey.llmKey: "",
            SettingsKey.ttsModel: "",
            SettingsKey.asrModel: "",
            SettingsKey.llmModel: "",
            SettingsKey.language: "",
            SettingsKey.systemPrompt: defaultSystemPrompt,
            SettingsKey.selectedVoice: "",
            SettingsKey.streamingTTS: false,
            SettingsKey.streamPCMRate: 24_000,
            SettingsKey.liveDictation: false,
            SettingsKey.autoStop: true,
            SettingsKey.silenceSeconds: 1.4,
            SettingsKey.autoSpeakReplies: true,
            SettingsKey.handsFreeLoop: true,
            SettingsKey.autoReferenceText: true,
            SettingsKey.showCaptions: true,
        ])
    }

    static var serverURL: String { defaults.string(forKey: SettingsKey.serverURL) ?? "" }
    static var apiKey: String { defaults.string(forKey: SettingsKey.apiKey) ?? "" }
    static var llmURL: String { defaults.string(forKey: SettingsKey.llmURL) ?? "" }
    static var llmKey: String { defaults.string(forKey: SettingsKey.llmKey) ?? "" }

    static var ttsModel: String { defaults.string(forKey: SettingsKey.ttsModel) ?? "" }
    static var asrModel: String { defaults.string(forKey: SettingsKey.asrModel) ?? "" }
    static var llmModel: String { defaults.string(forKey: SettingsKey.llmModel) ?? "" }

    /// Empty means "let the model decide", which is what audio.cpp does with no `language`.
    static var language: String { defaults.string(forKey: SettingsKey.language) ?? "" }
    static var systemPrompt: String { defaults.string(forKey: SettingsKey.systemPrompt) ?? defaultSystemPrompt }

    static var selectedVoice: VoiceToken {
        get { VoiceToken(stored: defaults.string(forKey: SettingsKey.selectedVoice) ?? "") }
        set { defaults.set(newValue.stored, forKey: SettingsKey.selectedVoice) }
    }

    static var streamingTTS: Bool { defaults.bool(forKey: SettingsKey.streamingTTS) }
    static var streamPCMRate: Int { max(8_000, defaults.integer(forKey: SettingsKey.streamPCMRate)) }
    static var liveDictation: Bool { defaults.bool(forKey: SettingsKey.liveDictation) }

    static var autoStop: Bool { defaults.bool(forKey: SettingsKey.autoStop) }
    static var silenceSeconds: Double { max(0.4, defaults.double(forKey: SettingsKey.silenceSeconds)) }
    static var autoSpeakReplies: Bool { defaults.bool(forKey: SettingsKey.autoSpeakReplies) }
    static var handsFreeLoop: Bool { defaults.bool(forKey: SettingsKey.handsFreeLoop) }
    static var autoReferenceText: Bool { defaults.bool(forKey: SettingsKey.autoReferenceText) }
    static var showCaptions: Bool { defaults.bool(forKey: SettingsKey.showCaptions) }
}
