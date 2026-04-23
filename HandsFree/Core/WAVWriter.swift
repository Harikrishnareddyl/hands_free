import AVFoundation
import Foundation

/// Streaming 16-bit PCM WAV writer. Placeholder header on init, int16 samples
/// appended as buffers arrive, size fields fixed up on `close()`.
/// Accepts either int16 PCM buffers (preferred — no conversion) or float32
/// buffers (legacy fallback, does a float→int16 conversion per-sample).
final class WAVWriter {
    let url: URL
    private let handle: FileHandle
    private let sampleRate: UInt32
    private let channels: UInt16
    private var dataBytes: UInt32 = 0

    init(url: URL, sampleRate: Double, channels: AVAudioChannelCount) throws {
        self.url = url
        self.sampleRate = UInt32(sampleRate)
        self.channels = UInt16(channels)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        try writeHeader()
    }

    private func writeHeader() throws {
        var header = Data()
        header.append("RIFF".asciiData)
        header.append(UInt32(0).leData)                              // file size - 8, fixed on close
        header.append("WAVE".asciiData)
        header.append("fmt ".asciiData)
        header.append(UInt32(16).leData)                             // PCM chunk size
        header.append(UInt16(1).leData)                              // format = PCM
        header.append(channels.leData)
        header.append(sampleRate.leData)
        header.append((sampleRate * UInt32(channels) * 2).leData)    // byte rate
        header.append((channels * 2).leData)                         // block align
        header.append(UInt16(16).leData)                             // bits per sample
        header.append("data".asciiData)
        header.append(UInt32(0).leData)                              // data size, fixed on close
        try handle.write(contentsOf: header)
    }

    /// Append a PCM buffer. Handles int16 (fast path — just memcpy) and
    /// float32 (converts per-sample to int16).
    func append(_ buffer: AVAudioPCMBuffer) throws {
        switch buffer.format.commonFormat {
        case .pcmFormatInt16:
            try appendInt16(buffer)
        default:
            if buffer.floatChannelData != nil { try appendFloat(buffer) }
        }
    }

    private func appendInt16(_ buffer: AVAudioPCMBuffer) throws {
        guard let channelData = buffer.int16ChannelData else { return }
        let frames = Int(buffer.frameLength)
        let chans = Int(channels)
        let bytes = frames * chans * 2
        var data = Data(count: bytes)

        data.withUnsafeMutableBytes { raw in
            guard let dst = raw.bindMemory(to: Int16.self).baseAddress else { return }
            if buffer.format.isInterleaved {
                // One contiguous block of interleaved samples.
                dst.update(from: channelData[0], count: frames * chans)
            } else {
                // Interleave on the fly.
                for f in 0..<frames {
                    for c in 0..<chans { dst[f * chans + c] = channelData[c][f] }
                }
            }
        }

        try handle.write(contentsOf: data)
        dataBytes &+= UInt32(bytes)
    }

    private func appendFloat(_ buffer: AVAudioPCMBuffer) throws {
        guard let floats = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let chans = Int(channels)
        var out = Data(count: frames * chans * 2)

        out.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for f in 0..<frames {
                for c in 0..<chans {
                    let sample = max(-1.0, min(1.0, floats[c][f]))
                    base[f * chans + c] = Int16(sample * 32767.0)
                }
            }
        }

        try handle.write(contentsOf: out)
        dataBytes &+= UInt32(out.count)
    }

    func close() throws {
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: (36 &+ dataBytes).leData)
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: dataBytes.leData)
        try handle.close()
    }
}

private extension FixedWidthInteger {
    var leData: Data {
        var v = self.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}

private extension String {
    var asciiData: Data { data(using: .ascii) ?? Data() }
}
