import AppKit

/// The short "HUD ping" played when "Hey Jarvis" starts a session: a bright chord ping
/// (G6 + D7 + G7) with a softer C7 echo 70 ms later, about 0.22 s in all. Synthesized once
/// in memory, so there is no audio file to bundle.
enum WakeChime {
    private static let sound: NSSound? = {
        let sound = NSSound(data: wavData())
        sound?.volume = 0.4
        return sound
    }()

    static func play() {
        guard let sound else { return }
        sound.stop()
        sound.play()
    }

    private static let sampleRate = 44_100.0

    /// Linear attack, then exponential decay over `length`.
    private static func envelope(_ t: Double, length: Double, attack: Double = 0.002) -> Double {
        min(1, t / attack) * exp(-5 * t / length)
    }

    private static func samples() -> [Double] {
        let count = Int(sampleRate * 0.22)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            var s = 0.0
            for (freq, gain) in [(1568.0, 1.0), (2349.0, 0.45), (3136.0, 0.2)] {
                s += gain * sin(2 * .pi * freq * t)
            }
            s *= envelope(t, length: 0.12)
            let echo = t - 0.07
            if echo > 0 { s += 0.35 * envelope(echo, length: 0.12) * sin(2 * .pi * 2093 * echo) }
            return s
        }
    }

    /// 16-bit mono PCM WAV, normalized to 80% of full scale.
    private static func wavData() -> Data {
        let raw = samples()
        let peak = raw.map(abs).max() ?? 1
        let pcm = raw.map { Int16(($0 / peak * 0.8 * 32767).rounded()) }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))                    // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)) // sample rate, byte rate
        append(UInt16(2)); append(UInt16(16))                   // block align, bits per sample
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        pcm.forEach { append($0) }
        return data
    }
}
