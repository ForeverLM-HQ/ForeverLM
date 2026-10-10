import Foundation

/// Lifts synthesized speech to podcast loudness before it reaches the phone's
/// speaker.
///
/// Measured on 2026-09-12 over the text-to-speech chunks in the library: the
/// narration sits between −18.6 and −25.6 LUFS integrated, with true peaks
/// from −1.3 to −7.5 dBFS. Podcasts are delivered around −16 LUFS, so at a volume-slider
/// position chosen for a podcast the narration plays 3–10 dB quieter — and
/// several files are already peak-normalized, so no plain volume multiplier
/// closes that gap without clipping. `AVPlayer`, `AVAudioPlayerNode` and the
/// mixers all cap their volume at 1.0 anyway.
///
/// Two stages, both stateful and sample-exact, so one instance serves one
/// stream. A slow, RMS-driven make-up gain lifts quiet speech toward the target
/// and never attenuates; it moves only while speech is present, so a pause
/// between sentences cannot wind the gain up and blast the first word after
/// it. A lookahead peak limiter then holds the boosted signal under the
/// ceiling: it sees each peak two milliseconds early, eases the gain down
/// ahead of it and back up after it, so there is no clipping and no click.
/// The loudest channel drives both stages and every channel receives the same
/// gain, so stereo stays balanced. The lookahead costs two milliseconds of
/// latency.
///
/// Measured on real narration (2026-09-12, three library chunks at −25.7,
/// −24.1 and −18.6 LUFS): each comes out within a decibel of −16 LUFS with a
/// true peak under the ceiling.
///
/// Foundation only: the Mac unit-test target compiles this file directly.
final class MobileSpeechLoudness {
    struct Tuning: Equatable {
        /// Speech-only RMS the make-up gain aims for, in dBFS. Integrated
        /// loudness lands about a decibel under it, so this is −16 LUFS, where
        /// podcasts are delivered.
        var targetRMSDecibels: Float = -15
        /// The make-up gain never lifts more than this.
        var maximumGainDecibels: Float = 10
        /// Below this level the make-up gain holds still. Judged by a fast
        /// tracker, so the gate closes within tens of milliseconds of a pause
        /// and the slow RMS is not read while it decays into the silence.
        var gateDecibels: Float = -45
        var gateWindowSeconds: Float = 0.01
        /// How fast the make-up gain rises toward the target and falls away
        /// from it. Falling is fast so a loud source is not squashed for long.
        var riseDecibelsPerSecond: Float = 6
        var fallDecibelsPerSecond: Float = 24
        /// The RMS averaging window.
        var rmsWindowSeconds: Float = 0.4
        /// The sample-peak ceiling the limiter holds the output under, in
        /// dBFS. A decibel of headroom is left under that for the peaks the
        /// DAC reconstructs between samples, which on limited speech measure
        /// up to 1.5 dB above the sample peaks.
        var ceilingDecibels: Float = -2
        /// How far ahead the limiter sees. Also its added latency.
        var lookaheadSeconds: Float = 0.002
        /// The limiter's release time constant.
        var limiterReleaseSeconds: Float = 0.08
    }

    let tuning: Tuning

    private var isPrepared = false
    private var preparedSampleRate: Double = 0
    private var targetRMS: Float = 0
    private var maximumGain: Float = 1
    private var gateMeanSquare: Float = 0
    private var ceiling: Float = 1
    private var rmsCoefficient: Float = 0
    private var gateCoefficient: Float = 0
    private var riseFactor: Float = 1
    private var fallFactor: Float = 1
    private var limiterReleaseStep: Float = 0

    private var meanSquare: Float = 0
    /// Speech samples the RMS has seen. For its first window the tracker is
    /// a plain running mean, so it reads the true level from the first cycle
    /// instead of charging up from zero and lifting the opening by mistake.
    private var measuredSamples = 0
    private var rmsWindowSamples = 1
    private var gateMeanSquareLevel: Float = 0
    private var gain: Float = 1

    // Limiter state. `lookahead` frames of boosted audio wait in `delay`
    // while the gain is planned for them: the required gain of every frame
    // enters a sliding-window minimum (`requiredGains` with the monotonic
    // `windowIndices` deque), the minimum is smoothed by the release and then
    // averaged over the lookahead (`smoothedGains`, `smoothedSum`), and the
    // result is applied to the frame leaving the delay. Every gain in that
    // average is a minimum over a window containing the leaving frame, so the
    // output never exceeds the ceiling. All storage is sized in `prepare`.
    private var lookahead = 0
    private var preparedChannelCount = 0
    private var delay: [Float] = []
    private var delayIndex = 0
    private var requiredGains: [Float] = []
    private var windowIndices: [Int] = []
    private var windowHead = 0
    private var windowCount = 0
    private var frameCounter = 0
    private var releasedGain: Float = 1
    private var smoothedGains: [Float] = []
    private var smoothedIndex = 0
    private var smoothedSum: Double = 0

    init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// The make-up gain currently applied, in dB. Read by tests; the limiter's
    /// momentary reduction is not included.
    var currentGainDecibels: Float {
        20 * log10(gain)
    }

    /// Fixes the time constants for `sampleRate`, sizes the limiter's storage
    /// for `channelCount` channels and clears every state variable. Call once
    /// per stream, before the first `process`.
    func prepare(sampleRate: Double, channelCount: Int = 1) {
        guard sampleRate > 0, sampleRate.isFinite, channelCount > 0 else {
            isPrepared = false
            return
        }
        preparedSampleRate = sampleRate
        let rate = Float(sampleRate)
        lookahead = max(1, Int(rate * tuning.lookaheadSeconds))
        preparedChannelCount = channelCount
        delay = [Float](repeating: 0, count: lookahead * channelCount)
        requiredGains = [Float](repeating: 1, count: lookahead + 1)
        windowIndices = [Int](repeating: 0, count: lookahead + 1)
        smoothedGains = [Float](repeating: 1, count: lookahead)
        targetRMS = Self.amplitude(decibels: tuning.targetRMSDecibels)
        maximumGain = Self.amplitude(decibels: tuning.maximumGainDecibels)
        let gate = Self.amplitude(decibels: tuning.gateDecibels)
        gateMeanSquare = gate * gate
        ceiling = Self.amplitude(decibels: tuning.ceilingDecibels)
        rmsWindowSamples = max(1, Int(rate * max(tuning.rmsWindowSeconds, 0.001)))
        rmsCoefficient = exp(-1 / Float(rmsWindowSamples))
        gateCoefficient = exp(-1 / (rate * max(tuning.gateWindowSeconds, 0.0005)))
        riseFactor = Self.amplitude(decibels: tuning.riseDecibelsPerSecond / rate)
        fallFactor = Self.amplitude(decibels: -tuning.fallDecibelsPerSecond / rate)
        limiterReleaseStep = 1 - exp(-1 / (rate * max(tuning.limiterReleaseSeconds, 0.001)))
        isPrepared = true
        reset()
    }

    /// Returns the gain stages to unity without changing the time constants.
    func reset() {
        meanSquare = 0
        measuredSamples = 0
        gateMeanSquareLevel = 0
        gain = 1
        for index in delay.indices { delay[index] = 0 }
        delayIndex = 0
        for index in requiredGains.indices { requiredGains[index] = 1 }
        windowHead = 0
        windowCount = 0
        frameCounter = 0
        releasedGain = 1
        for index in smoothedGains.indices { smoothedGains[index] = 1 }
        smoothedIndex = 0
        smoothedSum = Double(smoothedGains.count)
    }

    /// Processes one mono buffer in place.
    func process(mono samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: 1) { pointers in
            pointers.initializeElement(at: 0, to: samples)
            process(channels: UnsafeBufferPointer(pointers), frameCount: frameCount)
        }
    }

    /// Processes `frameCount` frames in place. Each entry of `channels` points
    /// at that channel's first sample; consecutive frames of a channel are
    /// `stride` samples apart, so non-interleaved audio passes one pointer per
    /// channel with a stride of 1, and interleaved audio passes `base + c` for
    /// each channel with a stride equal to the channel count.
    ///
    /// Nothing here allocates once prepared for this channel count: the caller
    /// may be on an audio render thread. A stream that changes its channel
    /// count is re-prepared on the spot, which allocates once.
    func process(
        channels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        stride: Int = 1
    ) {
        guard isPrepared, frameCount > 0, !channels.isEmpty, stride > 0 else { return }
        let channelCount = channels.count
        if channelCount != preparedChannelCount {
            prepare(sampleRate: preparedSampleRate, channelCount: channelCount)
        }
        var meanSquare = self.meanSquare
        var measuredSamples = self.measuredSamples
        var gateLevel = self.gateMeanSquareLevel
        var gain = self.gain
        var releasedGain = self.releasedGain
        var smoothedSum = self.smoothedSum
        let lookahead = self.lookahead
        let windowSize = lookahead + 1
        let averageScale = 1 / Float(lookahead)

        for frame in 0..<frameCount {
            let offset = frame * stride
            var peak: Float = 0
            for channel in 0..<channelCount {
                peak = max(peak, abs(channels[channel][offset]))
            }

            // Stage one: make-up gain from the input's own level, so it is
            // not a feedback loop and cannot hunt. Both the level and the gain
            // move only while speech is present: measuring across a pause
            // would let the RMS sink and the gain climb to meet it, and the
            // first word after the pause would be blasted.
            let square = peak * peak
            gateLevel = gateCoefficient * gateLevel + (1 - gateCoefficient) * square
            if gateLevel > gateMeanSquare {
                if measuredSamples < rmsWindowSamples {
                    measuredSamples += 1
                    meanSquare += (square - meanSquare) / Float(measuredSamples)
                } else {
                    meanSquare = rmsCoefficient * meanSquare + (1 - rmsCoefficient) * square
                }
                let desired = min(maximumGain, max(1, targetRMS / meanSquare.squareRoot()))
                if gain < desired {
                    gain = min(desired, gain * riseFactor)
                } else if gain > desired {
                    gain = max(desired, gain * fallFactor)
                }
            }

            // Stage two, planning: the gain this frame needs to sit under the
            // ceiling joins the sliding-window minimum over the lookahead.
            let boostedPeak = peak * gain
            let required: Float = boostedPeak > ceiling ? ceiling / boostedPeak : 1
            let slot = frameCounter % windowSize
            requiredGains[slot] = required
            while windowCount > 0 {
                let tail = (windowHead + windowCount - 1) % windowSize
                guard requiredGains[windowIndices[tail] % windowSize] >= required else { break }
                windowCount -= 1
            }
            windowIndices[(windowHead + windowCount) % windowSize] = frameCounter
            windowCount += 1
            if windowIndices[windowHead] <= frameCounter - windowSize {
                windowHead = (windowHead + 1) % windowSize
                windowCount -= 1
            }
            let windowMinimum = requiredGains[windowIndices[windowHead] % windowSize]
            frameCounter += 1

            // The minimum is followed down at once and up at the release rate,
            // then averaged over the lookahead so the fall is a ramp.
            releasedGain = min(windowMinimum, releasedGain + (1 - releasedGain) * limiterReleaseStep)
            smoothedSum += Double(releasedGain) - Double(smoothedGains[smoothedIndex])
            smoothedGains[smoothedIndex] = releasedGain
            smoothedIndex += 1
            if smoothedIndex == lookahead { smoothedIndex = 0 }
            let limiterGain = min(1, Float(smoothedSum) * averageScale)

            // Stage two, rendering: the frame that has waited `lookahead`
            // frames leaves the delay under the planned gain, and this frame's
            // boosted samples take its place.
            let delayBase = delayIndex * channelCount
            for channel in 0..<channelCount {
                let leaving = delay[delayBase + channel] * limiterGain
                delay[delayBase + channel] = channels[channel][offset] * gain
                channels[channel][offset] = min(1, max(-1, leaving))
            }
            delayIndex += 1
            if delayIndex == lookahead { delayIndex = 0 }
        }

        self.meanSquare = meanSquare
        self.measuredSamples = measuredSamples
        self.gateMeanSquareLevel = gateLevel
        self.gain = gain
        self.releasedGain = releasedGain
        self.smoothedSum = smoothedSum
    }

    private static func amplitude(decibels: Float) -> Float {
        pow(10, decibels / 20)
    }
}
