import SwiftUI

@main
struct VoxApp: App {

    @StateObject private var server = ServerStore()
    @StateObject private var library: VoiceLibrary
    @StateObject private var chat: ChatStore

    init() {
        AppSettings.registerDefaults()
        // Touching the library resolves the saved selection into the plain
        // `systemPrompt` value the conversation reads on every request.
        _ = PromptLibrary.shared
        // The conversation needs the voice library to resolve a cloned voice on every
        // request, so both are made here and the same instance is shared.
        let library = VoiceLibrary()
        _library = StateObject(wrappedValue: library)
        _chat = StateObject(wrappedValue: ChatStore(library: library))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(server)
                .environmentObject(library)
                .environmentObject(chat)
                .task {
                    // `task` hands you a @Sendable closure, which does NOT inherit the
                    // main actor, so every call into these stores is cross-isolation
                    // and has to be awaited. refresh() already loads the voices for
                    // whatever model was picked; autoSelect may change that, so the
                    // voices are refreshed once more after it.
                    await server.refresh()
                    await server.autoSelectModels()
                    await server.refreshVoices()
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var server: ServerStore

    var body: some View {
        TabView {
            SpeakView()
                .tabItem { Label("Speak", systemImage: "text.bubble") }
            ListenView()
                .tabItem { Label("Listen", systemImage: "waveform") }
            TalkView()
                .tabItem { Label("Talk", systemImage: "bubble.left.and.bubble.right") }
            VoicesView()
                .tabItem { Label("Voices", systemImage: "person.wave.2") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}
