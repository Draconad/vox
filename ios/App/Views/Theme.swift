import SwiftUI

/// The app's look, in one place. Near-black ground, one violet accent, generous
/// corner radii, and colour used only to mean something (state, error, activity).
enum Theme {
    static let accent = Color(red: 0.486, green: 0.424, blue: 1.0)
    static let accentDim = Color(red: 0.33, green: 0.29, blue: 0.72)

    static let ground = Color(red: 0.043, green: 0.043, blue: 0.055)
    static let card = Color(red: 0.094, green: 0.094, blue: 0.114)
    static let cardRaised = Color(red: 0.137, green: 0.137, blue: 0.165)
    static let hairline = Color.white.opacity(0.08)

    static let primaryText = Color(white: 0.96)
    static let secondaryText = Color(white: 0.62)
    static let tertiaryText = Color(white: 0.42)

    static let good = Color(red: 0.31, green: 0.80, blue: 0.53)
    static let warn = Color(red: 0.98, green: 0.71, blue: 0.24)
    static let bad = Color(red: 0.96, green: 0.35, blue: 0.38)

    static let radius: CGFloat = 18
}

/// A padded panel on the dark ground. Used instead of `GroupBox` so the corner radius
/// and hairline are consistent everywhere.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Theme.tertiaryText)
    }
}

/// Connection state as a small coloured pill.
struct StatusPill: View {
    let connection: ServerStore.Connection
    var name: String

    private var colour: Color {
        switch connection {
        case .online: return Theme.good
        case .checking, .unknown: return Theme.warn
        case .offline: return Theme.bad
        }
    }

    private var text: String {
        switch connection {
        case .unknown: return "\(name) —"
        case .checking: return "Checking \(name)…"
        case .online(let n): return "\(name) · \(n) model\(n == 1 ? "" : "s")"
        case .offline: return "\(name) unreachable"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.cardRaised))
    }
}

/// Live microphone level as a row of bars. Newest sample on the right.
struct WaveformView: View {
    var levels: [Double]
    var active: Bool
    var barCount: Int = 40

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let width = max(2, (geo.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let level = value(at: i)
                    Capsule()
                        .fill(active ? Theme.accent.opacity(0.35 + level * 0.65) : Theme.tertiaryText.opacity(0.25))
                        .frame(width: width,
                               height: max(3, geo.size.height * CGFloat(0.06 + level * 0.94)))
                }
            }
            .frame(height: geo.size.height, alignment: .center)
            .animation(.linear(duration: 0.08), value: levels.count)
        }
    }

    /// Right-aligns the history so the newest bar is always at the right edge.
    private func value(at index: Int) -> Double {
        let offset = barCount - levels.count
        let i = index - offset
        guard i >= 0, i < levels.count else { return 0 }
        return min(1, max(0, levels[i]))
    }
}

/// The big round talk button, with a ring that breathes while it's live.
struct TalkButton: View {
    var phase: ChatStore.Phase
    var level: Double
    var action: () -> Void

    private var symbol: String {
        switch phase {
        case .idle:         return "mic.fill"
        case .listening:    return "stop.fill"
        case .transcribing: return "waveform"
        case .thinking:     return "ellipsis"
        case .speaking:     return "speaker.wave.2.fill"
        }
    }

    private var tint: Color {
        switch phase {
        case .idle:         return Theme.accent
        case .listening:    return Theme.bad
        case .transcribing: return Theme.warn
        case .thinking:     return Theme.accentDim
        case .speaking:     return Theme.good
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.25), lineWidth: 2)
                    .scaleEffect(1 + CGFloat(level) * 0.22)
                    .animation(.easeOut(duration: 0.12), value: level)
                Circle()
                    .fill(
                        LinearGradient(colors: [tint, tint.opacity(0.62)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 84, height: 84)
                    .shadow(color: tint.opacity(0.45), radius: 18, y: 6)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 116, height: 116)
        }
        .buttonStyle(.plain)
    }
}

/// A compact chip that picks a model inline, without a trip to Settings.
///
/// Connection state is folded into the chip's own colour rather than sitting in a
/// separate status pill: if the server behind this stage is unreachable, the chip
/// turns red, which says the same thing in less space.
struct PickerChip: View {
    var icon: String
    var stage: String
    @Binding var selection: String
    var likely: [String]
    var all: [String]
    /// The connection itself, not a Bool: "still checking" and "no address set" have
    /// to read differently from "unreachable", or every launch looks like a failure.
    var connection: ServerStore.Connection
    /// Called when the chip is tapped while there is nothing to offer.
    var onRetry: () -> Void = {}

    private var tint: Color {
        switch connection {
        case .offline:            return Theme.bad
        case .unknown, .checking: return Theme.warn
        case .online:             return selection.isEmpty ? Theme.warn : Theme.accent
        }
    }

    private var text: String {
        if case .offline = connection { return "\(stage) offline" }
        return selection.isEmpty ? stage : selection
    }

    /// Colour alone shouldn't carry the meaning — for a red or amber state the chip
    /// also changes its glyph, and VoiceOver gets it in words.
    private var trailingGlyph: String {
        switch connection {
        case .offline:            return "exclamationmark.triangle.fill"
        case .unknown, .checking: return "ellipsis"
        case .online:             return "chevron.down"
        }
    }

    private var spokenState: String {
        switch connection {
        case .offline:  return "server unreachable"
        case .checking: return "checking"
        case .unknown:  return "not configured"
        case .online:   return selection.isEmpty ? "no model chosen" : selection
        }
    }

    var body: some View {
        Group {
            if all.isEmpty {
                // A Menu with no items opens nothing and looks broken, and a bare Text
                // inside one is dropped by UIKit — so the empty case is a plain button
                // that retries instead.
                Button(action: onRetry) { chipLabel }
                    .buttonStyle(.plain)
            } else {
                Menu {
                    if !selection.isEmpty {
                        Button("None") { selection = "" }
                    }
                    if !likely.isEmpty {
                        Section("Likely") {
                            ForEach(likely, id: \.self) { id in item(id) }
                        }
                    }
                    let rest = all.filter { !likely.contains($0) }
                    if !rest.isEmpty {
                        Section(likely.isEmpty ? stage : "Other") {
                            ForEach(rest, id: \.self) { id in item(id) }
                        }
                    }
                } label: {
                    chipLabel
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel("\(stage) model")
        .accessibilityValue(spokenState)
    }

    private func item(_ id: String) -> some View {
        Button {
            selection = id
        } label: {
            if selection == id { Label(id, systemImage: "checkmark") } else { Text(id) }
        }
    }

    private var chipLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(all.isEmpty && connection.isOnline ? "No models" : text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Image(systemName: trailingGlyph)
                .font(.system(size: 8, weight: .bold))
                .opacity(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.cardRaised))
        .foregroundStyle(tint)
    }
}

/// A chip that pushes a picker screen. The navigating sibling of `PickerChip`.
struct LinkChip<Destination: View>: View {
    var icon: String
    var text: String
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.cardRaised))
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
    }
}

/// A filled action button that shows a spinner while its work is in flight.
struct BusyButton: View {
    var title: String
    var systemImage: String
    var busy: Bool
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: systemImage)
                }
                Text(busy ? "Working…" : title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(enabled && !busy ? Theme.accent : Theme.cardRaised)
            )
            .foregroundStyle(enabled && !busy ? Color.white : Theme.tertiaryText)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
    }
}

extension View {
    /// The dark ground every screen sits on.
    func voxBackground() -> some View {
        background(Theme.ground.ignoresSafeArea())
    }
}

extension Double {
    /// "1:04" / "0:07" for clip lengths and recording timers.
    var clockString: String {
        let total = Int(rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
