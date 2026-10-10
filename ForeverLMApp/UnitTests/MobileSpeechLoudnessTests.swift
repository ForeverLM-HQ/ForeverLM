import Foundation
import Testing

/// The gain and limiter stages that lift iPhone speech to podcast loudness.
/// `MobileSpeechLoudness` is compiled into this test module directly.
@Suite("Mobile speech loudness")
struct MobileSpeechLoudnessTests {
    private static let sampleRate = 24_000.0

    /// A sine at `rmsDecibels` dBFS RMS, `seconds` long.
    private static func sine(rmsDecibels: Float, seconds: Double, frequency: Double = 440) -> [Float] {
        let amplitude = pow(10, rmsDecibels / 20) * Float(2).squareRoot()
        let count = Int(sampleRate * seconds)
        return (0..<count).map { index in
            amplitude * Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }

    private static func rmsDecibels(_ samples: ArraySlice<Float>) -> Float {
        let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(samples.count, 1))
        return 10 * log10(max(meanSquare, 1e-12))
    }

    private static func process(_ samples: [Float], with loudness: MobileSpeechLoudness) -> [Float] {
        var output = samples
        output.withUnsafeMutableBufferPointer { buffer in
            // Feed it the way the audio layer does: in buffers of a few hundred frames.
            var offset = 0
            while offset < buffer.count {
                let frames = min(480, buffer.count - offset)
                loudness.process(mono: buffer.baseAddress! + offset, frameCount: frames)
                offset += frames
            }
        }
        return output
    }

    private static func prepared() -> MobileSpeechLoudness {
        let loudness = MobileSpeechLoudness()
        loudness.prepare(sampleRate: sampleRate)
        return loudness
    }

    @Test("Quiet speech is lifted to the target and never clipped")
    func quietSpeechReachesTarget() {
        let loudness = Self.prepared()
        let output = Self.process(Self.sine(rmsDecibels: -24, seconds: 3), with: loudness)
        let lastSecond = output.suffix(Int(Self.sampleRate))
        let level = Self.rmsDecibels(lastSecond)
        #expect(abs(level - loudness.tuning.targetRMSDecibels) < 0.5, "settled at \(level) dBFS")
        #expect(abs(loudness.currentGainDecibels - 9) < 0.5)
        let ceiling = pow(10, loudness.tuning.ceilingDecibels / 20)
        #expect(output.allSatisfy { abs($0) <= ceiling + 1e-4 })
    }

    @Test("The lift is capped at the maximum gain")
    func veryQuietSpeechGetsTheMaximumOnly() {
        let loudness = Self.prepared()
        _ = Self.process(Self.sine(rmsDecibels: -30, seconds: 4), with: loudness)
        #expect(abs(loudness.currentGainDecibels - loudness.tuning.maximumGainDecibels) < 0.05)
    }

    @Test("Loud speech is not lifted, and its peaks stay under the ceiling")
    func loudSpeechIsOnlyLimited() {
        let loudness = Self.prepared()
        let output = Self.process(Self.sine(rmsDecibels: -3, seconds: 2), with: loudness)
        #expect(loudness.currentGainDecibels == 0)
        let ceiling = pow(10, loudness.tuning.ceilingDecibels / 20)
        let peak = output.map(abs).max() ?? 0
        #expect(peak <= ceiling + 1e-4)
        #expect(peak > ceiling - 0.01, "the limiter holds the peak at the ceiling, not below it")
    }

    @Test("Silence is left silent and holds the gain where it was")
    func silenceHoldsTheGain() {
        let loudness = Self.prepared()
        _ = Self.process(Self.sine(rmsDecibels: -24, seconds: 3), with: loudness)
        let settled = loudness.currentGainDecibels
        #expect(settled > 5)
        // The gate closes within tens of milliseconds; whatever the gain did
        // in that instant, it then holds for the rest of the pause.
        let opening = Self.process([Float](repeating: 0, count: Int(Self.sampleRate * 0.2)), with: loudness)
        // The first two milliseconds are the sine's tail leaving the lookahead delay.
        #expect(opening.dropFirst(Int(Self.sampleRate * 0.002) + 1).allSatisfy { $0 == 0 })
        let held = loudness.currentGainDecibels
        #expect(abs(held - settled) < 0.5)
        let silence = Self.process([Float](repeating: 0, count: Int(Self.sampleRate * 2)), with: loudness)
        #expect(silence.allSatisfy { $0 == 0 })
        #expect(loudness.currentGainDecibels == held)
    }

    @Test("A noise floor under the gate does not wind the gain up")
    func noiseFloorStaysUnderTheGate() {
        let loudness = Self.prepared()
        _ = Self.process(Self.sine(rmsDecibels: -60, seconds: 4), with: loudness)
        #expect(loudness.currentGainDecibels == 0)
    }

    @Test("Interleaved stereo receives one gain on both channels")
    func interleavedStereoSharesTheGain() {
        let mono = Self.prepared()
        let reference = Self.process(Self.sine(rmsDecibels: -26, seconds: 2), with: mono)

        let stereo = Self.prepared()
        let left = Self.sine(rmsDecibels: -26, seconds: 2)
        var interleaved = [Float](repeating: 0, count: left.count * 2)
        for (index, sample) in left.enumerated() {
            interleaved[index * 2] = sample
            // The right channel carries the same signal at half amplitude, so
            // it must come out at exactly half of the left's output.
            interleaved[index * 2 + 1] = sample / 2
        }
        interleaved.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            let pointers = [base, base + 1]
            pointers.withUnsafeBufferPointer { channels in
                stereo.process(channels: channels, frameCount: left.count, stride: 2)
            }
        }
        for index in stride(from: 0, to: left.count, by: 997) {
            #expect(abs(interleaved[index * 2] - reference[index]) < 1e-5)
            #expect(abs(interleaved[index * 2 + 1] - reference[index] / 2) < 1e-5)
        }
    }

    @Test("Unprepared and reset instances pass audio through at unity")
    func unpreparedIsPassThrough() {
        let untouched = MobileSpeechLoudness()
        let input = Self.sine(rmsDecibels: -26, seconds: 0.1)
        #expect(Self.process(input, with: untouched) == input)

        // Prepared but unity: loud enough that nothing is lifted, quiet enough
        // that nothing is limited — the output is the input, two milliseconds late.
        let unity = Self.prepared()
        let steady = Self.sine(rmsDecibels: -8, seconds: 0.5)
        let output = Self.process(steady, with: unity)
        let lookahead = Int(Self.sampleRate * 0.002)
        // The RMS reads the level from the first cycle; skip that cycle.
        for index in stride(from: Int(Self.sampleRate * 0.005), to: steady.count, by: 97) {
            #expect(abs(output[index] - steady[index - lookahead]) < 1e-6)
        }

        let loudness = Self.prepared()
        _ = Self.process(Self.sine(rmsDecibels: -26, seconds: 2), with: loudness)
        #expect(loudness.currentGainDecibels > 5)
        loudness.reset()
        #expect(loudness.currentGainDecibels == 0)
    }
}
