import Combine
import Foundation

/// One value the user has set for a request option. audio.cpp's specs mix types, so
/// this carries whichever it is and knows how to become JSON.
enum OptionValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case integer(Int)
    case boolean(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .boolean(b); return }
        if let i = try? c.decode(Int.self) { self = .integer(i); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        self = .string(try c.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .boolean(let v): try c.encode(v)
        }
    }

    var jsonValue: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v
        case .integer(let v): return v
        case .boolean(let v): return v
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let v): return v
        case .integer(let v): return Double(v)
        case .string(let v): return Double(v)
        case .boolean: return nil
        }
    }

    var stringValue: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return String(format: "%g", v)
        case .integer(let v): return String(v)
        case .boolean(let v): return v ? "true" : "false"
        }
    }

    var boolValue: Bool {
        if case .boolean(let v) = self { return v }
        return false
    }
}

/// One request option a family accepts, as its own spec describes it.
struct ModelOption: Decodable, Identifiable, Equatable {
    var name: String
    var type: String            // string | int | float | enum | bool
    var desc: String
    var featured: Bool
    var required: Bool?
    var min: Double?
    var max: Double?
    var values: [String]?
    var defaultValue: OptionValue?

    var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name, type, desc, featured, required, min, max, values
        case defaultValue = "default"
    }

    /// A readable label from a snake_case option name.
    var title: String {
        switch name {
        case "instruction":      return "Style prompt"
        case "reference_text":   return "Reference transcript"
        case "temperature":      return "Temperature"
        case "depth_temperature":return "Depth temperature"
        case "guidance_scale", "flow_guidance_scale": return "Guidance"
        case "speaker_scale":    return "Speaker strength"
        case "repetition_penalty": return "Repetition penalty"
        case "num_inference_steps": return "Inference steps"
        case "num_beams":        return "Beams"
        case "template_name":    return "Template"
        case "max_tokens":       return "Max tokens"
        case "seed":             return "Seed"
        case "language":         return "Language"
        case "enable_thinking":  return "Thinking"
        default:
            return name.replacingOccurrences(of: "_", with: " ")
                .prefix(1).uppercased() + name.replacingOccurrences(of: "_", with: " ").dropFirst()
        }
    }

    /// Long free text gets a multi-line box; short strings a single field.
    var isLongText: Bool {
        type == "string" && (name == "instruction" || name == "reference_text")
    }

    /// A slider needs both ends. Several options declare only a minimum, so a
    /// sensible ceiling is supplied here rather than showing an unbounded control.
    var sliderRange: ClosedRange<Double>? {
        guard type == "float" || type == "int" else { return nil }
        let low = min ?? 0
        if let max { return low...Swift.max(max, low + 0.0001) }
        switch name {
        case "temperature", "depth_temperature": return low...2
        case "guidance_scale", "flow_guidance_scale": return low...10
        case "speaker_scale":       return low...4
        case "repetition_penalty":  return low...20
        case "num_inference_steps": return low...60
        case "num_beams":           return low...8
        case "top_k":               return low...100
        case "max_tokens":          return low...4000
        default: return nil     // seed and the byte-size knobs get a text field instead
        }
    }
}

struct ModelFamilySpec: Decodable {
    var display: String
    var category: String
    var tasks: [String]
    var modes: [String]
    var options: [ModelOption]

    var featured: [ModelOption] { options.filter(\.featured) }
    var advanced: [ModelOption] { options.filter { !$0.featured } }
    var canClone: Bool { tasks.contains("clone") }
    /// A model that insists on a transcript alongside its reference audio.
    var requiresReferenceText: Bool {
        options.contains { $0.name == "reference_text" && $0.required == true }
    }
}

/// What the user has set, per model.
///
/// Only options they actually touched are stored, and only those are sent — so every
/// other value stays whatever the model's own default is, rather than this app
/// freezing a snapshot of the defaults into every request.
@MainActor
final class ModelOptionStore: ObservableObject {

    static let shared = ModelOptionStore()

    @Published private(set) var values: [String: [String: OptionValue]] = [:]

    private let key = "modelRequestOptions"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: [String: OptionValue]].self, from: data) {
            values = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func value(model: String, option: String) -> OptionValue? {
        values[model]?[option]
    }

    func isSet(model: String, option: String) -> Bool {
        values[model]?[option] != nil
    }

    func set(_ value: OptionValue?, model: String, option: String) {
        var forModel = values[model] ?? [:]
        if let value { forModel[option] = value } else { forModel.removeValue(forKey: option) }
        if forModel.isEmpty { values.removeValue(forKey: model) } else { values[model] = forModel }
        save()
    }

    func clear(model: String) {
        values.removeValue(forKey: model)
        save()
    }

    func count(model: String) -> Int { values[model]?.count ?? 0 }

    /// The body fields to add to a request. These go in at the top level: the specs'
    /// `options.request` list and the documented top-level speech fields are the same
    /// set — `reference_text` appears in both — so nesting them would do nothing.
    func requestFields(model: String) -> [String: Any] {
        (values[model] ?? [:]).mapValues { $0.jsonValue }
    }
}
