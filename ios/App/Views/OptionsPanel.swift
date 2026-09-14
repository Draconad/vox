import SwiftUI

/// The per-model controls, built from the model's own spec rather than guessed.
///
/// Every audio.cpp family declares what it accepts — name, type, range, default — so
/// this renders whatever the selected model actually offers and nothing it doesn't.
/// BreezeTTS gets a style prompt and a guidance slider; Higgs TTS, which declares no
/// request options at all, correctly gets nothing.
///
/// A control is only sent once you've touched it. Everything untouched stays at the
/// model's own default, so this app never freezes a snapshot of those defaults into
/// your requests.
struct OptionsPanel: View {

    let modelID: String
    let declaredFamily: String?

    @ObservedObject private var store = ModelOptionStore.shared
    @State private var showAdvanced = false

    private var spec: ModelFamilySpec? {
        ModelOptionCatalogue.family(forModelID: modelID, declared: declaredFamily)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                header

                if let spec {
                    if spec.options.isEmpty {
                        Text("\(spec.display) declares no request options — it takes the text and the voice, and nothing else.")
                            .font(.footnote)
                            .foregroundStyle(Theme.tertiaryText)
                    } else {
                        ForEach(spec.featured) { option in
                            control(option)
                            if option.id != spec.featured.last?.id { Divider().overlay(Theme.hairline) }
                        }
                        if !spec.advanced.isEmpty {
                            Button {
                                withAnimation { showAdvanced.toggle() }
                            } label: {
                                HStack(spacing: 5) {
                                    Text(showAdvanced ? "Fewer controls" : "\(spec.advanced.count) more")
                                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                                        .font(.caption2.weight(.bold))
                                }
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            if showAdvanced {
                                ForEach(spec.advanced) { option in
                                    Divider().overlay(Theme.hairline)
                                    control(option)
                                }
                            }
                        }
                    }
                } else if modelID.isEmpty {
                    Text("Pick a model to see what it can be told to do.")
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    Text("No spec on file for \"\(modelID)\". Re-run make-server-config.sh on the server and send me the new specs-dump.txt to add it.")
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            SectionLabel(text: spec.map { "\($0.display) controls" } ?? "Controls")
            Spacer()
            if store.count(model: modelID) > 0 {
                Button {
                    store.clear(model: modelID)
                } label: {
                    Text("Reset \(store.count(model: modelID))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: One control

    @ViewBuilder
    private func control(_ option: ModelOption) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(option.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                if option.required == true {
                    Text("required")
                        .font(.caption2)
                        .foregroundStyle(Theme.warn)
                }
                Spacer()
                if store.isSet(model: modelID, option: option.name) {
                    Button {
                        store.set(nil, model: modelID, option: option.name)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                } else if let d = option.defaultValue {
                    Text("default \(d.stringValue)")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }

            switch option.type {
            case "bool":
                boolControl(option)
            case "enum":
                enumControl(option)
            case "string":
                stringControl(option)
            default:
                numberControl(option)
            }

            if !option.desc.isEmpty {
                Text(option.desc)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func boolControl(_ option: ModelOption) -> some View {
        let current = store.value(model: modelID, option: option.name)?.boolValue
            ?? option.defaultValue?.boolValue ?? false
        Toggle("", isOn: Binding(
            get: { current },
            set: { store.set(.boolean($0), model: modelID, option: option.name) }
        ))
        .labelsHidden()
        .tint(Theme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func enumControl(_ option: ModelOption) -> some View {
        let current = store.value(model: modelID, option: option.name)?.stringValue
            ?? option.defaultValue?.stringValue ?? "—"
        Menu {
            ForEach(option.values ?? [], id: \.self) { value in
                Button {
                    store.set(.string(value), model: modelID, option: option.name)
                } label: {
                    if current == value { Label(value, systemImage: "checkmark") } else { Text(value) }
                }
            }
        } label: {
            HStack {
                Text(current).foregroundStyle(Theme.secondaryText)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardRaised))
        }
    }

    @ViewBuilder
    private func stringControl(_ option: ModelOption) -> some View {
        // The getter deliberately does NOT fall back to the spec default. It used to,
        // and that made the box impossible to clear: emptying it stored nil, the getter
        // then read the default back, and the text reinstated itself on the next redraw.
        // Empty now means "not set" — nothing is sent and the model applies its own
        // default — and the default is shown as a dimmed placeholder instead of as
        // editable content, so the two states are told apart at a glance.
        let placeholder = option.defaultValue?.stringValue ?? ""
        let text = Binding(
            get: { store.value(model: modelID, option: option.name)?.stringValue ?? "" },
            set: { new in
                store.set(new.isEmpty ? nil : .string(new), model: modelID, option: option.name)
            }
        )
        if option.isLongText {
            TextEditor(text: text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 62)
                .font(.system(size: 15))
                .foregroundStyle(Theme.primaryText)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardRaised))
                .overlay(alignment: .topLeading) {
                    // TextEditor has no placeholder of its own.
                    if text.wrappedValue.isEmpty && !placeholder.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.tertiaryText)
                            .allowsHitTesting(false)
                            .padding(.top, 14)
                            .padding(.leading, 11)
                    }
                }
            if text.wrappedValue.isEmpty && !placeholder.isEmpty {
                Button {
                    store.set(.string(placeholder), model: modelID, option: option.name)
                } label: {
                    Text("Start from the default")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        } else {
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 15))
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardRaised))
        }
    }

    @ViewBuilder
    private func numberControl(_ option: ModelOption) -> some View {
        let isInt = option.type == "int"
        let current = store.value(model: modelID, option: option.name)?.doubleValue
            ?? option.defaultValue?.doubleValue ?? option.min ?? 0

        if let range = option.sliderRange {
            VStack(spacing: 2) {
                HStack {
                    Text(format(current, isInt: isInt))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(store.isSet(model: modelID, option: option.name)
                                         ? Theme.accent : Theme.secondaryText)
                    Spacer()
                    Text("\(format(range.lowerBound, isInt: isInt))–\(format(range.upperBound, isInt: isInt))")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                }
                Slider(
                    value: Binding(
                        get: { Swift.min(Swift.max(current, range.lowerBound), range.upperBound) },
                        set: { new in
                            store.set(isInt ? .integer(Int(new.rounded())) : .number(rounded(new)),
                                      model: modelID, option: option.name)
                        }
                    ),
                    in: range,
                    step: isInt ? 1 : 0.01
                )
                .tint(Theme.accent)
            }
        } else {
            // Seeds and other unbounded integers: a slider would be meaningless.
            TextField(option.defaultValue?.stringValue ?? "", text: Binding(
                get: { store.value(model: modelID, option: option.name)?.stringValue ?? "" },
                set: { new in
                    if new.isEmpty { store.set(nil, model: modelID, option: option.name) }
                    else if isInt, let v = Int(new) { store.set(.integer(v), model: modelID, option: option.name) }
                    else if let v = Double(new) { store.set(.number(v), model: modelID, option: option.name) }
                }
            ))
            .keyboardType(isInt ? .numberPad : .decimalPad)
            .font(.system(size: 15))
            .monospacedDigit()
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardRaised))
        }
    }

    private func format(_ v: Double, isInt: Bool) -> String {
        isInt ? String(Int(v.rounded())) : String(format: "%.2f", v)
    }

    private func rounded(_ v: Double) -> Double {
        (v * 100).rounded() / 100
    }
}
