import Combine
import Foundation

/// One named system prompt.
///
/// Built-in presets ship with the app and can't be edited in place — you duplicate one
/// and change the copy — so there is always a known-good starting point to come back to.
struct PromptPreset: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var text: String
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, text: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.text = text
        self.isBuiltIn = isBuiltIn
    }
}

/// The personalities you can pick between.
///
/// Every preset keeps the instruction about plain spoken sentences, because all of them
/// are read aloud: a model that answers in markdown makes the TTS recite asterisks and
/// hyphens. That line is the one thing worth keeping when you write your own.
@MainActor
final class PromptLibrary: ObservableObject {

    static let shared = PromptLibrary()

    @Published private(set) var custom: [PromptPreset] = []
    @Published private(set) var selectedID: UUID

    private let storeKey = "promptPresets"

    // MARK: Built-ins

    /// Appended to every built-in. Kept separate so the intent is obvious when you read
    /// one, and so a custom prompt can borrow the same wording.
    static let spokenRule =
        "Your replies are read aloud, so answer in plain spoken sentences: no markdown, "
        + "no bullet points, no code blocks, no emoji, no headings."

    static let builtIns: [PromptPreset] = [
        PromptPreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!,
            name: "Concise assistant",
            text: "You are a concise voice assistant. \(spokenRule) Keep it to a few "
                + "sentences unless asked for more.",
            isBuiltIn: true),

        PromptPreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!,
            name: "Straight answers",
            text: "Answer the question directly and stop. \(spokenRule) No preamble, no "
                + "restating the question, no offers of further help. If you don't know, "
                + "say so in one sentence. If something is genuinely ambiguous, ask one "
                + "short question instead of guessing.",
            isBuiltIn: true),

        PromptPreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A003")!,
            name: "Explain it",
            text: "You explain things clearly to someone smart who is new to the topic. "
                + "\(spokenRule) Build up from what the listener already knows, use a "
                + "concrete example or an analogy, and say what the common "
                + "misunderstanding is. Around a minute of speech unless asked for more.",
            isBuiltIn: true),

        PromptPreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A004")!,
            name: "Think it through",
            text: "You are a thinking partner, not an answer machine. \(spokenRule) "
                + "Offer two or three real options with the trade-off of each, say which "
                + "you'd pick and why, and name the thing most likely to go wrong. "
                + "Disagree when you disagree.",
            isBuiltIn: true),

        PromptPreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A005")!,
            name: "Workshop",
            text: "You are a practical help for hands-on work: machining, tooling, "
                + "electronics, home servers and the like. \(spokenRule) Be specific "
                + "about numbers, units and tolerances, and say which units you're using. "
                + "Give the practical answer first and the reasoning after. Flag anything "
                + "that is a safety issue before anything else.",
            isBuiltIn: true),

        PromptPreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A006")!,
            name: "Just chat",
            text: "You are good company in conversation. \(spokenRule) Talk like a person "
                + "who finds things interesting: react to what was actually said, follow "
                + "the thread, ask a question when you're curious rather than out of "
                + "habit. Don't lecture, and don't end every turn with a question.",
            isBuiltIn: true),
    ]

    // MARK: Lifecycle

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: storeKey),
           let decoded = try? JSONDecoder().decode([PromptPreset].self, from: data) {
            custom = decoded
        }
        let stored = defaults.string(forKey: SettingsKey.selectedPromptID).flatMap(UUID.init(uuidString:))
        selectedID = stored ?? Self.builtIns[0].id
        // Whatever was selected last time has to be written through on launch: the rest
        // of the app reads the resolved text straight out of UserDefaults, so it must
        // never be able to drift from the selection.
        applySelection()
    }

    var all: [PromptPreset] { Self.builtIns + custom }

    var selected: PromptPreset {
        all.first { $0.id == selectedID } ?? Self.builtIns[0]
    }

    // MARK: Selection

    func select(_ preset: PromptPreset) {
        selectedID = preset.id
        applySelection()
    }

    /// Pushes the active preset's text into the plain `systemPrompt` value.
    ///
    /// The conversation reads that string from a non-isolated context on every request,
    /// so resolving it here — once, at the moment the selection changes — keeps the read
    /// side trivial and impossible to get wrong.
    private func applySelection() {
        let preset = selected
        UserDefaults.standard.set(preset.id.uuidString, forKey: SettingsKey.selectedPromptID)
        UserDefaults.standard.set(preset.text, forKey: SettingsKey.systemPrompt)
    }

    // MARK: Editing

    @discardableResult
    func add(name: String, text: String) -> PromptPreset {
        let preset = PromptPreset(name: name.isEmpty ? "Untitled" : name, text: text)
        custom.append(preset)
        save()
        return preset
    }

    /// Built-ins are read-only, so "edit" on one means "start from this".
    @discardableResult
    func duplicate(_ preset: PromptPreset) -> PromptPreset {
        let copy = PromptPreset(name: uniqueName(from: preset.name), text: preset.text)
        custom.append(copy)
        save()
        return copy
    }

    func update(_ preset: PromptPreset, name: String, text: String) {
        guard let i = custom.firstIndex(where: { $0.id == preset.id }) else { return }
        custom[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        custom[i].text = text
        save()
        if selectedID == preset.id { applySelection() }
    }

    func delete(_ preset: PromptPreset) {
        guard !preset.isBuiltIn else { return }
        custom.removeAll { $0.id == preset.id }
        if selectedID == preset.id { selectedID = Self.builtIns[0].id }
        save()
        applySelection()
    }

    private func uniqueName(from base: String) -> String {
        var name = "\(base) copy"
        var n = 2
        let taken = Set(all.map(\.name))
        while taken.contains(name) {
            name = "\(base) copy \(n)"
            n += 1
        }
        return name
    }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}
