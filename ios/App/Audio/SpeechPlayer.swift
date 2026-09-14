import AVFoundation
import Combine
import Foundation

/// Plays generated speech.
///
/// Two modes, because the server offers two shapes of answer:
///  - `play(wav:)` for a finished WAV, which is what a normal `/v1/audio/speech`
///    request returns. Clips queue, so the conversation can start speaking sentence
///    one while sentence two is still being generated.
///  - `openStream(sampleRate:)` + `push(pcm:)` for a model configured with
///    `mode: "streaming"`, where audio arrives as raw PCM chunks over SSE.
final class SpeechPlayer: NSObject, ObservableObject {

    @Published private(set) var isPlaying = false
    /// How many finished clips are waiting behind the one playing.
    @Published private(set) var queued = 0

    private var player: AVAudioPlayer?
    private var pending: [Data] = []
    private var onFinishedAll: (() -> Void)?

    // Streaming side
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var streamFormat: AVAudioFormat?
    private var streamAttached = false
    private var outstandingBuffers = 0
    private var streamEnded = false
    /// Bumped on every close. `node.stop()` fires the pending completion handlers, but
    /// they land a main-queue hop later — by which time a new stream may already be
    /// open, and their decrements would push its counter negative.
    private var streamEpoch = 0
    /// SSE chunks are base64 payloads that can split mid-sample, so a trailing odd
    /// byte is carried into the next chunk instead of being dropped (an audible click).
    private var pcmRemainder = Data()

    // MARK: Finished clips

    /// Queues a WAV clip. Playing starts immediately if nothing else is.
    func play(wav: Data) {
        pending.append(wav)
        queued = max(0, pending.count - (player != nil ? 0 : 1))
        if player == nil { startNext() }
    }

    /// Called once the queue empties naturally (not on `stop()`).
    func onDrained(_ handler: (() -> Void)?) {
        onFinishedAll = handler
    }

    private func startNext() {
        guard !pending.isEmpty else {
            isPlaying = false
            queued = 0
            let handler = onFinishedAll
            handler?()
            return
        }
        let data = pending.removeFirst()
        queued = pending.count
        do {
            try AudioSessionManager.activate(.playback)
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            player = p
            isPlaying = true
            p.play()
        } catch {
            player = nil
            // A clip that won't decode shouldn't wedge the queue.
            startNext()
        }
    }

    /// Stops playing and throws away anything queued behind it.
    func stop() {
        player?.stop()
        player = nil
        pending.removeAll()
        queued = 0
        isPlaying = false
        closeStream()
    }

    var hasWork: Bool { isPlaying || !pending.isEmpty }

    // MARK: Streaming PCM

    /// - Parameter sampleRate: the rate the model's PCM is actually at. audio.cpp does
    ///   not announce it, so this comes from Settings; wrong rate means the voice plays
    ///   at the wrong pitch, which is the tell.
    func openStream(sampleRate: Int) throws {
        closeStream()
        try AudioSessionManager.activate(.playback)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: Double(sampleRate),
                                        channels: 1,
                                        interleaved: false)
        else { throw VoxError.unreachable("Couldn't open the audio output.") }
        streamFormat = format
        outstandingBuffers = 0
        streamEnded = false
        pcmRemainder.removeAll()
        if !streamAttached {
            engine.attach(node)
            streamAttached = true
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        node.play()
        isPlaying = true
    }

    /// Feeds one chunk of little-endian 16-bit PCM.
    func push(pcm: Data) {
        guard let format = streamFormat, !pcm.isEmpty else { return }
        var work = pcmRemainder
        work.append(pcm)
        let frames = work.count / 2
        // Re-based with Data(...) so the next chunk's byte offsets start at zero.
        pcmRemainder = frames * 2 < work.count ? Data(work.suffix(from: work.startIndex + frames * 2)) : Data()
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.floatChannelData
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        work.withUnsafeBytes { raw in
            // loadUnaligned, not bindMemory: a chunk's base address carries no
            // alignment guarantee, and binding it would be undefined behaviour.
            for i in 0..<frames {
                let sample = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                dst[0][i] = Float(Int16(littleEndian: sample)) / 32768.0
            }
        }
        outstandingBuffers += 1
        let epoch = streamEpoch
        node.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                guard let self, epoch == self.streamEpoch else { return }
                self.outstandingBuffers -= 1
                if self.outstandingBuffers <= 0 && self.streamEnded { self.isPlaying = false }
            }
        }
    }

    /// No more chunks coming. Playback continues until the scheduled audio runs out,
    /// and `isPlaying` clears when the last buffer finishes.
    func endStream() {
        streamEnded = true
        if outstandingBuffers <= 0 { isPlaying = false }
    }

    private func closeStream() {
        if engine.isRunning {
            node.stop()
            engine.stop()
        }
        streamFormat = nil
        streamEnded = false
        outstandingBuffers = 0
        streamEpoch &+= 1
        pcmRemainder.removeAll()
    }
}

extension SpeechPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        startNext()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        self.player = nil
        startNext()
    }
}
