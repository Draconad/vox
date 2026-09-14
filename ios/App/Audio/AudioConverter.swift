import AVFoundation
import Foundation

/// Turns anything the Files app will hand over — a Voice Memo .m4a, an .mp3, a
/// 48 kHz stereo .wav, a .caf — into the one shape the server wants: 16 kHz mono
/// 16-bit WAV.
///
/// Two reasons this matters more than it looks:
///  - audio.cpp's core transcription and cloning routes read WAV only;
///  - an inline `voice_ref` is capped at 5 MiB decoded, and a reference clip only
///    wants to be 10-15 seconds anyway, so trimming here is what keeps cloning
///    working from a phone.
enum AudioConverter {

    struct Result {
        var wav: Data
        var duration: Double
        var originalDuration: Double
        var wasTrimmed: Bool { originalDuration - duration > 0.05 }
    }

    /// A reference clip longer than this is trimmed. The cloning models want a short,
    /// clean sample; more audio makes the request bigger without making the voice better.
    static let referenceClipSeconds: Double = 15

    /// Reads `url` and returns 16 kHz mono 16-bit WAV bytes.
    /// `maxSeconds` nil means keep the whole thing.
    static func toWAV(url: URL, sampleRate: Int = WAV.defaultSampleRate,
                      maxSeconds: Double? = nil) throws -> Result {
        // A file picked from iCloud Drive or another app's container needs a
        // coordinated read; a security-scoped URL needs the scope held open.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw VoxError.notWAV
        }

        let sourceFormat = file.processingFormat            // always float32, deinterleaved
        // A zero rate would make the capacity maths below evaluate to infinity, and
        // AVAudioFrameCount(infinity) traps rather than returning nil.
        guard sourceFormat.sampleRate > 0 else { throw VoxError.notWAV }
        let originalDuration = Double(file.length) / sourceFormat.sampleRate

        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Double(sampleRate),
                                         channels: 1,
                                         interleaved: true),
              let converter = AVAudioConverter(from: sourceFormat, to: target)
        else { throw VoxError.notWAV }

        // AVAudioConverter downmixes to mono and resamples on its own; asking for high
        // quality matters because a badly resampled reference clip clones badly.
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let framesWanted: AVAudioFramePosition = {
            guard let maxSeconds, maxSeconds > 0 else { return file.length }
            return min(file.length, AVAudioFramePosition(maxSeconds * sourceFormat.sampleRate))
        }()

        let readChunk: AVAudioFrameCount = 16_384
        var framesRead: AVAudioFramePosition = 0
        var pcm = Data()
        var sourceExhausted = false

        let inputBlock: AVAudioConverterInputBlock = { requested, outStatus in
            _ = requested
            if sourceExhausted || framesRead >= framesWanted {
                outStatus.pointee = .endOfStream
                return nil
            }
            let remaining = AVAudioFrameCount(min(AVAudioFramePosition(readChunk), framesWanted - framesRead))
            guard remaining > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: remaining)
            else {
                outStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: buffer, frameCount: remaining)
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
            if buffer.frameLength == 0 {
                sourceExhausted = true
                outStatus.pointee = .endOfStream
                return nil
            }
            framesRead += AVAudioFramePosition(buffer.frameLength)
            outStatus.pointee = .haveData
            return buffer
        }

        // Output buffer sized for the worst case: the converter can hand back more
        // frames than it took when it is resampling upwards.
        let outCapacity = AVAudioFrameCount(Double(readChunk) * (Double(sampleRate) / sourceFormat.sampleRate) + 4096)
        var emptyPasses = 0
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(outCapacity, 4096)) else { break }
            var convError: NSError?
            let status = converter.convert(to: out, error: &convError, withInputFrom: inputBlock)
            if let convError { throw VoxError.unreachable(convError.localizedDescription) }
            if out.frameLength > 0, let channel = out.int16ChannelData {
                let byteCount = Int(out.frameLength) * Int(target.channelCount) * 2
                channel[0].withMemoryRebound(to: UInt8.self, capacity: byteCount) { bytes in
                    pcm.append(bytes, count: byteCount)
                }
                emptyPasses = 0
            } else {
                emptyPasses += 1
                if emptyPasses > 4 { break }        // belt and braces against a stuck converter
            }
            if status == .endOfStream || status == .error { break }
            if status == .inputRanDry && (sourceExhausted || framesRead >= framesWanted) { break }
        }

        guard !pcm.isEmpty else { throw VoxError.notWAV }
        let duration = Double(pcm.count / 2) / Double(sampleRate)
        return Result(wav: WAV.encode(pcm16: pcm, sampleRate: sampleRate, channels: 1),
                      duration: duration,
                      originalDuration: originalDuration)
    }

    /// Convenience for reference clips: 16 kHz mono, trimmed to 15 s.
    static func toReferenceWAV(url: URL) throws -> Result {
        try toWAV(url: url, sampleRate: WAV.defaultSampleRate, maxSeconds: referenceClipSeconds)
    }
}
