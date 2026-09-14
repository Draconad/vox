import Combine
import Foundation

/// A reference clip kept on this phone, used to clone a voice.
///
/// The audio itself is a 16 kHz mono WAV in the app's Application Support folder; this
/// record is the index entry. `referenceText` is the transcript of the clip, which the
/// cloning models use to line up what they hear with what was said — leaving it blank
/// still works on most models but clones noticeably worse.
struct StoredVoice: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var referenceText: String
    var filename: String
    var duration: Double
    var byteCount: Int
    var createdAt: Date

    init(id: UUID = UUID(), name: String, referenceText: String, filename: String,
         duration: Double, byteCount: Int, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.referenceText = referenceText
        self.filename = filename
        self.duration = duration
        self.byteCount = byteCount
        self.createdAt = createdAt
    }
}

/// The on-device voice library.
///
/// Deliberately local-only. Because `/v1/audio/speech` accepts an inline base64
/// `voice_ref`, cloning from a clip on the phone needs nothing staged on the server
/// and no companion container — which is the whole reason this app has no server half.
@MainActor
final class VoiceLibrary: ObservableObject {

    @Published private(set) var voices: [StoredVoice] = []

    private let folder: URL
    private let indexURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folder = base.appendingPathComponent("Voices", isDirectory: true)
        indexURL = folder.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        voices = (try? decoder.decode([StoredVoice].self, from: data)) ?? []
        // Drop entries whose audio has gone missing (restored backup, manual cleanup).
        voices.removeAll { !FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(voices) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    func url(for voice: StoredVoice) -> URL {
        folder.appendingPathComponent(voice.filename)
    }

    func wav(for voice: StoredVoice) -> Data? {
        try? Data(contentsOf: url(for: voice))
    }

    func voice(id: UUID) -> StoredVoice? {
        voices.first { $0.id == id }
    }

    // MARK: Mutating

    /// Stores already-converted 16 kHz mono WAV bytes under a new voice.
    @discardableResult
    func add(wav: Data, name: String, referenceText: String, duration: Double) throws -> StoredVoice {
        let id = UUID()
        let filename = "\(id.uuidString).wav"
        let destination = folder.appendingPathComponent(filename)
        try wav.write(to: destination, options: .atomic)
        let voice = StoredVoice(id: id,
                                name: name.isEmpty ? "Voice \(voices.count + 1)" : name,
                                referenceText: referenceText,
                                filename: filename,
                                duration: duration,
                                byteCount: wav.count)
        voices.append(voice)
        save()
        return voice
    }

    func rename(_ voice: StoredVoice, to name: String) {
        guard let i = voices.firstIndex(of: voice) else { return }
        voices[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func setReferenceText(_ voice: StoredVoice, _ text: String) {
        guard let i = voices.firstIndex(of: voice) else { return }
        voices[i].referenceText = text
        save()
    }

    func delete(_ voice: StoredVoice) {
        try? FileManager.default.removeItem(at: url(for: voice))
        voices.removeAll { $0.id == voice.id }
        save()
        // Don't leave the app pointed at a voice that no longer exists.
        if case .local(let id) = AppSettings.selectedVoice, id == voice.id {
            AppSettings.selectedVoice = .serverDefault
        }
    }

    /// Resolves the stored selection into something the client can send.
    func selection(_ token: VoiceToken) -> VoiceSelection {
        switch token {
        case .serverDefault:
            return .serverDefault
        case .server(let name):
            return .named(name)
        case .local(let id):
            guard let voice = voice(id: id), let data = wav(for: voice) else { return .serverDefault }
            return .inline(wav: data, referenceText: voice.referenceText)
        }
    }

    /// A human label for the current selection, for the pickers and the Speak screen.
    func label(_ token: VoiceToken) -> String {
        switch token {
        case .serverDefault: return "Server default"
        case .server(let name): return name
        case .local(let id): return voice(id: id)?.name ?? "Missing voice"
        }
    }
}
