import AVFoundation
import Foundation

/// One place that owns the shared `AVAudioSession`, because recording and playback
/// want different categories and fighting over them is how you end up with a silent
/// app or a microphone that won't start.
enum AudioSessionManager {

    enum Use {
        /// Playing back generated speech only.
        case playback
        /// Capturing the microphone, and playing the reply through the speaker.
        case converse
    }

    private static var current: Use?

    static func activate(_ use: Use) throws {
        let session = AVAudioSession.sharedInstance()
        if current != use {
            switch use {
            case .playback:
                try session.setCategory(.playback, mode: .spokenAudio, options: [])
            case .converse:
                // .voiceChat gives echo cancellation, which matters when the reply is
                // coming out of the speaker while the mic is still open.
                try session.setCategory(.playAndRecord, mode: .voiceChat,
                                        options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            }
            current = use
        }
        try session.setActive(true, options: [])
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        current = nil
    }

    /// Asks for the microphone. `false` means the user said no, and the caller should
    /// say so rather than silently recording nothing.
    /// (The deployment target is 17.0, so this is the modern API with no fallback —
    /// `AVAudioSession.requestRecordPermission` is deprecated from 17.0 anyway.)
    static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static var microphoneDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }
}
