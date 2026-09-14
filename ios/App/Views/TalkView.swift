import SwiftUI

/// A phone call with the machine.
///
/// Deliberately not a chat log: hands-free means the phone is face-down or in a pocket,
/// and a scrolling transcript is something you can only read, not use. So the screen is
/// a call — one orb that reacts to your voice, what it's doing, how long you've been at
/// it, and a single line of caption so a misheard word is obvious. The conversation is
/// still kept in full underneath; it just isn't the interface.
struct TalkView: View {

    @EnvironmentObject private var server: ServerStore
    @EnvironmentObject private var library: VoiceLibrary
    @EnvironmentObject private var chat: ChatStore

    @AppStorage(SettingsKey.handsFreeLoop) private var handsFree = true
    @AppStorage(SettingsKey.selectedVoice) private var voiceToken = ""
    @AppStorage(SettingsKey.llmModel) private var llmModel = ""
    @AppStorage(SettingsKey.asrModel) private var asrModel = ""
    @AppStorage(SettingsKey.ttsModel) private var ttsModel = ""
    @AppStorage(SettingsKey.showCaptions) private var showCaptions = true

    @ObservedObject private var activity = ServerActivity.shared
    @ObservedObject private var prompts = PromptLibrary.shared

    @State private var typed = ""
    @State private var showingTextEntry = false
    @State private var elapsed: String = "0:00"
    /// Mirrored from the recorder: MicRecorder is its own ObservableObject, so without
    /// this the orb would only redraw on the once-a-second call timer.
    @State private var micLevel: Double = 0

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var ready: Bool { !asrModel.isEmpty && !llmModel.isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chips
                Spacer(minLength: 0)
                orb
                statusLine
                captions
                Spacer(minLength: 0)
                controls
            }
            .voxBackground()
            .navigationTitle("Talk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Keep listening after each reply", isOn: $handsFree)
                        Toggle("Show captions", isOn: $showCaptions)
                        Divider()
                        Button("Type a message instead") { showingTextEntry = true }
                        Button("Clear conversation", role: .destructive) { chat.clearConversation() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { chat.error != nil },
                set: { if !$0 { chat.error = nil } }
            )) {
                Button("OK") { chat.error = nil }
            } message: {
                Text(chat.error ?? "")
            }
            .sheet(isPresented: $showingTextEntry) { typeSheet }
            .task {
                // `task` gives a @Sendable closure, which does not inherit the main
                // actor, so even reading this needs an await.
                let online = await server.connection.isOnline
                if !online { await server.refresh() }
            }
            .onChange(of: ttsModel) { _, _ in
                Task { await server.refreshVoices() }
            }
            .onReceive(tick) { _ in
                let now = callDuration
                if now != elapsed { elapsed = now }
            }
            .onReceive(chat.mic.levelPublisher) { micLevel = $0 }
        }
    }

    // MARK: Model chips

    private var chips: some View {
        // Two rows on purpose. Five chips in one scroller pushed the two you change
        // most — who it sounds like, and how it behaves — off the right edge where
        // nobody would find them. Models are set once; personality and voice are not.
        VStack(spacing: 6) {
            // Scrolls rather than an HStack: two chips with long names ("Straight
            // answers" plus a voice called "Angela White 2") overflow a phone's width,
            // and a plain HStack squeezes them both instead of letting them scroll.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    LinkChip(icon: "theatermasks.fill", text: prompts.selected.name) {
                        PromptsView()
                    }
                    LinkChip(icon: "person.wave.2.fill",
                             text: library.label(VoiceToken(stored: voiceToken))) {
                        VoicePickerView(selection: $voiceToken)
                    }
                }
                .padding(.horizontal, 16)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PickerChip(icon: "ear", stage: "Hear",
                               selection: $asrModel,
                               likely: server.asrModels.map(\.id),
                               all: server.models.map(\.id),
                               connection: server.connection,
                               onRetry: { Task { await server.refresh() } })
                    PickerChip(icon: "brain", stage: "Think",
                               selection: $llmModel,
                               likely: server.llmModels,
                               all: server.llmModels,
                               connection: server.llmConnection,
                               onRetry: { Task { await server.refresh() } })
                    PickerChip(icon: "speaker.wave.2.fill", stage: "Speak",
                               selection: $ttsModel,
                               likely: server.ttsModels.map(\.id),
                               all: server.models.map(\.id),
                               connection: server.connection,
                               onRetry: { Task { await server.refresh() } })
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 6)
        // Out of the way during a call — the chips are for setting up, not for talking.
        .opacity(chat.inCall ? 0.35 : 1)
    }

    // MARK: Orb

    private var orb: some View {
        CallOrb(phase: chat.phase, level: micLevel)
            .frame(width: 220, height: 220)
            .padding(.bottom, 14)
    }

    private var statusLine: some View {
        VStack(spacing: 6) {
            Text(chat.phase == .idle && !chat.inCall ? "Ready" : chat.phase.label)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .contentTransition(.opacity)
            if let loading = activity.label {
                // The server says nothing while it swaps a model in, so a long silence
                // here would be indistinguishable from a hang.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(Theme.warn)
                    Text(loading)
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.warn)
                }
            } else if chat.inCall {
                Text(elapsed)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            } else if !ready {
                Text("Set Hear and Think above to start")
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
    }

    // MARK: Captions

    @ViewBuilder
    private var captions: some View {
        if showCaptions {
            VStack(spacing: 8) {
                if !chat.lastHeard.isEmpty && chat.phase != .listening {
                    Text(chat.lastHeard)
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Text(chat.caption)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .animation(.easeInOut(duration: 0.2), value: chat.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .top)
            .padding(.horizontal, 28)
            .padding(.top, 16)
        } else {
            Color.clear.frame(height: 78)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 40) {
                secondary(icon: "keyboard", label: "Type") { showingTextEntry = true }

                Button(action: primaryTapped) {
                    ZStack {
                        Circle()
                            .fill(primaryTint)
                            .frame(width: 76, height: 76)
                            .shadow(color: primaryTint.opacity(0.45), radius: 16, y: 6)
                        Image(systemName: primaryIcon)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!ready)
                .opacity(ready ? 1 : 0.4)

                // Hanging up is its own button, available in every state of a call.
                // It used to share the primary, which meant that while the mic was
                // open there was no way to end the call at all.
                secondary(icon: "phone.down.fill", label: "End", tint: Theme.bad) {
                    chat.stopEverything()
                }
                .disabled(!chat.inCall)
                .opacity(chat.inCall ? 1 : 0.3)
            }
            Text(primaryHint)
                .font(.caption2)
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.bottom, 18)
    }

    private func secondary(icon: String, label: String, tint: Color = Theme.primaryText,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(Theme.cardRaised).frame(width: 52, height: 52)
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(tint)
                }
                Text(label).font(.caption2).foregroundStyle(Theme.tertiaryText)
            }
        }
        .buttonStyle(.plain)
    }

    private var typeSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextEditor(text: $typed)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                Spacer()
            }
            .padding(16)
            .voxBackground()
            .navigationTitle("Type a message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { typed = ""; showingTextEntry = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send") {
                        chat.send(text: typed)
                        typed = ""
                        showingTextEntry = false
                    }
                    .fontWeight(.semibold)
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: Actions

    /// The primary button is whatever you most want next; ending the call is the
    /// separate red button, so this never has to double as the way out.
    private func primaryTapped() {
        switch chat.phase {
        case .listening:
            chat.finishListening()              // send what you've said
        case .speaking:
            chat.startListening(continuous: handsFree)   // cut in
        case .transcribing, .thinking:
            chat.cancelTurn()                   // drop this exchange, stay in the call
        case .idle:
            chat.startListening(continuous: handsFree)
        }
    }

    private var primaryIcon: String {
        switch chat.phase {
        case .listening:               return "arrow.up"
        case .speaking:                return "mic.fill"
        case .transcribing, .thinking: return "xmark"
        case .idle:                    return chat.inCall ? "mic.fill" : "phone.fill"
        }
    }

    private var primaryTint: Color {
        switch chat.phase {
        case .listening:               return Theme.accent
        case .speaking:                return Theme.accent
        case .transcribing, .thinking: return Theme.warn
        case .idle:                    return chat.inCall ? Theme.accent : Theme.good
        }
    }

    private var primaryHint: String {
        switch chat.phase {
        case .listening:               return "Tap to send what you've said"
        case .speaking:                return "Tap the mic to cut in"
        case .transcribing, .thinking: return "Tap to drop this one and carry on"
        case .idle:                    return chat.inCall ? "Tap to talk" : "Tap to start a conversation"
        }
    }

    private var callDuration: String {
        guard let start = chat.callStartedAt else { return "0:00" }
        return Date().timeIntervalSince(start).clockString
    }
}

/// The thing you look at during a call: rings that swell with your voice while it
/// listens and breathe slowly while it talks, so you can tell across the room whether
/// it heard you.
struct CallOrb: View {
    var phase: ChatStore.Phase
    var level: Double

    private var tint: Color {
        switch phase {
        case .idle:         return Theme.accentDim
        case .listening:    return Theme.accent
        case .transcribing: return Theme.warn
        case .thinking:     return Theme.accentDim
        case .speaking:     return Theme.good
        }
    }

    private var symbol: String {
        switch phase {
        case .idle:         return "phone"
        case .listening:    return "mic.fill"
        case .transcribing: return "waveform"
        case .thinking:     return "ellipsis"
        case .speaking:     return "speaker.wave.2.fill"
        }
    }

    var body: some View {
        ZStack {
            // Your voice, while it is listening. Keyed to `level`, which only ever
            // animates a scale — it can't capture layout.
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .stroke(tint.opacity(0.28 - Double(ring) * 0.07), lineWidth: 2)
                    .scaleEffect(1 + CGFloat(level) * CGFloat(0.10 + Double(ring) * 0.13))
            }
            .opacity(phase == .listening ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: level)

            // The ambient pulse, computed from the clock rather than animated.
            //
            // Implicit animation is the wrong tool here and twice proved it: a
            // `withAnimation` in onAppear animated the view's first layout, so the
            // screen slid in from the corner; moving it to a `repeatForever` keyed on a
            // flag made that capture permanent, and the ring oscillated between the
            // centre and the origin forever. A TimelineView opens no transaction at
            // all — the scale is simply a function of the current time — so there is
            // nothing for a layout change to get caught up in. Paused while listening,
            // where the voice rings take over.
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: phase == .listening)) { timeline in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let pulse = 0.5 + 0.5 * sin(seconds * 2 * Double.pi / 3.2)
                Circle()
                    .stroke(tint.opacity(0.10 + 0.20 * pulse), lineWidth: 2)
                    .scaleEffect(CGFloat(0.95 + 0.13 * pulse))
            }
            .opacity(phase == .listening ? 0 : 1)

            Circle()
                .fill(
                    RadialGradient(colors: [tint.opacity(0.55), tint.opacity(0.08)],
                                   center: .center, startRadius: 4, endRadius: 110)
                )
            Circle()
                .fill(
                    LinearGradient(colors: [tint, tint.opacity(0.65)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 92, height: 92)
                .shadow(color: tint.opacity(0.5), radius: 22, y: 8)
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
