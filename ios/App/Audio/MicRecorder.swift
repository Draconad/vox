import AVFoundation
import Combine
import Foundation

/// The microphone, in one object.
///
/// A single `AVAudioEngine` tap serves all three things the app needs from the mic at
/// once — the accumulating recording, the level for the waveform, and (when asked) a
/// live chunk callback for streaming straight to the server — so there is never a
/// second recorder competing for the input node.
///
/// Everything comes out as 16 kHz mono 16-bit PCM, which is what audio.cpp's ASR models
/// want and what the live endpoint is told to expect.
///
/// Not marked `@MainActor`: the tap callback arrives on a realtime audio thread, so the
/// state it touches is guarded by a lock and every `@Published` change is hopped to the
/// main queue instead.
final class MicRecorder: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var duration: Double = 0
    /// 0...1, already smoothed, ready to drive a meter.
    @Published private(set) var level: Double = 0
    /// Rolling history for the waveform view, newest last.
    @Published private(set) var levels: [Double] = []

    let sampleRate = WAV.defaultSampleRate

    /// `$level` isn't reachable from outside because the property is `private(set)`,
    /// and the call screen needs the meter to drive its orb.
    var levelPublisher: Published<Double>.Publisher { $level }

    private let engine = AVAudioEngine()
    private let lock = NSLock()

    // All of these are touched from the audio thread, so they live behind `lock`.
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    private var inputFormat: AVAudioFormat?
    private var pcm = Data()
    private var chunkHandler: ((Data) -> Void)?
    private var running = false

    private var silenceHandler: (() -> Void)?
    private var silenceThreshold: Double = 0.045
    private var silenceSecondsNeeded: Double = 1.4
    private var heardSpeech = false
    private var silentSeconds: Double = 0
    private var firedSilence = false

    private static let maxLevels = 48

    /// Three screens each hold their own recorder, but iOS has one input node. Whoever
    /// starts last wins, and the previous one is stopped rather than left running with
    /// an engine that would fail to start or hand back a 0 Hz format.
    private static weak var active: MicRecorder?

    // MARK: Start / stop

    /// - Parameters:
    ///   - onChunk: called on the audio thread with each converted PCM chunk. Used for
    ///     live transcription; keep the work inside it small.
    ///   - onSilence: called on the main queue once the speaker has clearly stopped.
    func start(onChunk: ((Data) -> Void)? = nil, onSilence: (() -> Void)? = nil) throws {
        guard !isRecording else { return }
        if let other = Self.active, other !== self { other.cancel() }
        try AudioSessionManager.activate(.converse)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw VoxError.unreachable("The microphone isn't available right now.")
        }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: Double(sampleRate),
                                              channels: 1,
                                              interleaved: true),
              let conv = AVAudioConverter(from: format, to: targetFormat)
        else { throw VoxError.unreachable("Couldn't set up audio conversion.") }
        conv.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

        lock.lock()
        converter = conv
        target = targetFormat
        inputFormat = format
        pcm.removeAll(keepingCapacity: true)
        chunkHandler = onChunk
        silenceHandler = onSilence
        heardSpeech = false
        silentSeconds = 0
        firedSilence = false
        running = true
        lock.unlock()

        duration = 0
        level = 0
        levels = []

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock(); running = false; lock.unlock()
            throw VoxError.unreachable(error.localizedDescription)
        }
        isRecording = true
        Self.active = self
    }

    /// Stops and returns the whole recording as WAV bytes. Nil if nothing usable was captured.
    @discardableResult
    func stop() -> Data? {
        guard isRecording else { return nil }
        lock.lock()
        running = false
        chunkHandler = nil
        silenceHandler = nil
        let captured = pcm
        lock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        level = 0
        if Self.active === self { Self.active = nil }

        guard captured.count > 1600 else { return nil }     // under 50 ms is a stray tap
        return WAV.encode(pcm16: captured, sampleRate: sampleRate, channels: 1)
    }

    func cancel() {
        _ = stop()
        lock.lock(); pcm.removeAll(); lock.unlock()
        duration = 0
        levels = []
    }

    /// Tune the auto-stop. A longer `seconds` suits dictating with pauses in it.
    func configureSilenceDetection(threshold: Double, seconds: Double) {
        lock.lock()
        silenceThreshold = threshold
        silenceSecondsNeeded = seconds
        lock.unlock()
    }

    // MARK: Tap (audio thread)

    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard running, let conv = converter, let targetFormat = target, let format = inputFormat else {
            lock.unlock(); return
        }
        let handler = chunkHandler
        lock.unlock()

        // Level from the float data the tap handed us.
        var rms: Double = 0
        if let floats = buffer.floatChannelData, buffer.frameLength > 0 {
            let n = Int(buffer.frameLength)
            var sum: Double = 0
            for i in 0..<n {
                let v = Double(floats[0][i])
                sum += v * v
            }
            rms = (sum / Double(n)).squareRoot()
        }

        let ratio = targetFormat.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }

        let byteCount = Int(out.frameLength) * 2
        var chunk = Data(count: byteCount)
        chunk.withUnsafeMutableBytes { dst in
            if let base = dst.baseAddress { memcpy(base, channel[0], byteCount) }
        }

        lock.lock()
        pcm.append(chunk)
        let totalBytes = pcm.count
        lock.unlock()

        handler?(chunk)

        let chunkSeconds = Double(out.frameLength) / targetFormat.sampleRate
        DispatchQueue.main.async { [weak self] in
            self?.absorb(rms: rms, chunkSeconds: chunkSeconds, totalBytes: totalBytes)
        }
    }

    // MARK: Meter (main queue)

    private func absorb(rms: Double, chunkSeconds: Double, totalBytes: Int) {
        guard isRecording else { return }
        // Perceptual-ish curve: raw RMS from a phone mic sits very low, and a linear
        // meter looks dead even when you're talking normally.
        let shaped = min(1, (rms * 6).squareRoot())
        level = level * 0.6 + shaped * 0.4
        levels.append(level)
        if levels.count > Self.maxLevels { levels.removeFirst(levels.count - Self.maxLevels) }
        duration = Double(totalBytes / 2) / Double(sampleRate)

        lock.lock()
        let threshold = silenceThreshold
        let needed = silenceSecondsNeeded
        let handler = silenceHandler
        if rms > threshold {
            heardSpeech = true
            silentSeconds = 0
        } else if heardSpeech {
            silentSeconds += chunkSeconds
        }
        let shouldFire = heardSpeech && silentSeconds >= needed && !firedSilence
        if shouldFire { firedSilence = true }
        lock.unlock()

        if shouldFire { handler?() }
    }
}
