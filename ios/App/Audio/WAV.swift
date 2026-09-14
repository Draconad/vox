import Foundation

/// Minimal RIFF/WAV reading and writing.
///
/// The app builds WAV bytes itself rather than letting AVFoundation pick a container,
/// because audio.cpp's core routes decode WAV in memory and nothing else (MP3 and FLAC
/// only work when the server was built with the optional `audio_decode` frontend).
/// Owning the header means every clip the app uploads or inlines is one the server can
/// certainly read.
enum WAV {

    static let defaultSampleRate = 16_000

    /// Wraps raw little-endian 16-bit PCM in a canonical 44-byte WAV header.
    static func encode(pcm16: Data, sampleRate: Int = defaultSampleRate, channels: Int = 1) -> Data {
        var out = Data(capacity: pcm16.count + 44)
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        func ascii(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { var le = UInt32(truncatingIfNeeded: v).littleEndian
                             withUnsafeBytes(of: &le) { out.append(contentsOf: $0) } }
        func u16(_ v: Int) { var le = UInt16(truncatingIfNeeded: v).littleEndian
                             withUnsafeBytes(of: &le) { out.append(contentsOf: $0) } }

        ascii("RIFF")
        u32(36 + pcm16.count)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)                 // PCM chunk size
        u16(1)                  // format = PCM
        u16(channels)
        u32(sampleRate)
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        ascii("data")
        u32(pcm16.count)
        out.append(pcm16)
        return out
    }

    /// Sample rate, channel count and duration of a WAV, read straight from its header.
    /// Used to show clip lengths without decoding the audio.
    struct Info {
        var sampleRate: Int
        var channels: Int
        var bitsPerSample: Int
        var dataBytes: Int
        var duration: Double {
            let bytesPerFrame = max(1, channels * bitsPerSample / 8)
            guard sampleRate > 0 else { return 0 }
            return Double(dataBytes) / Double(bytesPerFrame) / Double(sampleRate)
        }
    }

    static func info(_ data: Data) -> Info? {
        guard data.count >= 44,
              data[data.startIndex..<data.startIndex+4].elementsEqual(Array("RIFF".utf8)),
              data[data.startIndex+8..<data.startIndex+12].elementsEqual(Array("WAVE".utf8))
        else { return nil }

        func u32(_ at: Int) -> Int {
            let i = data.startIndex + at
            guard i + 4 <= data.endIndex else { return 0 }
            return Int(UInt32(data[i]) | UInt32(data[i+1]) << 8 | UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24)
        }
        func u16(_ at: Int) -> Int {
            let i = data.startIndex + at
            guard i + 2 <= data.endIndex else { return 0 }
            return Int(UInt16(data[i]) | UInt16(data[i+1]) << 8)
        }

        var cursor = 12
        var rate = 0, channels = 0, bits = 0, dataBytes = 0
        while cursor + 8 <= data.count {
            let idStart = data.startIndex + cursor
            let id = String(decoding: data[idStart..<min(idStart+4, data.endIndex)], as: UTF8.self)
            let size = u32(cursor + 4)
            if id == "fmt " {
                channels = u16(cursor + 10)
                rate = u32(cursor + 12)
                bits = u16(cursor + 22)
            } else if id == "data" {
                dataBytes = min(size, data.count - cursor - 8)
                break
            }
            cursor += 8 + size + (size % 2)     // chunks are word-aligned
            if size <= 0 { break }
        }
        guard rate > 0, channels > 0 else { return nil }
        if dataBytes == 0 { dataBytes = max(0, data.count - 44) }
        return Info(sampleRate: rate, channels: channels, bitsPerSample: bits == 0 ? 16 : bits, dataBytes: dataBytes)
    }

    /// The PCM payload of a WAV, without its header. Used when handing audio to a
    /// raw-PCM consumer such as the live transcription endpoint.
    static func pcmPayload(_ data: Data) -> Data? {
        guard data.count > 44 else { return nil }
        var cursor = 12
        while cursor + 8 <= data.count {
            let idStart = data.startIndex + cursor
            let id = String(decoding: data[idStart..<min(idStart+4, data.endIndex)], as: UTF8.self)
            let i = data.startIndex + cursor + 4
            guard i + 4 <= data.endIndex else { return nil }
            let size = Int(UInt32(data[i]) | UInt32(data[i+1]) << 8 | UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24)
            if id == "data" {
                let start = data.startIndex + cursor + 8
                let end = min(start + size, data.endIndex)
                guard start < end else { return nil }
                return Data(data[start..<end])
            }
            cursor += 8 + size + (size % 2)
            if size <= 0 { return nil }
        }
        return nil
    }
}
