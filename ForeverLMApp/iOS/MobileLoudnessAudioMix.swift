import AVFoundation
import MediaToolbox

/// Runs an `AVPlayerItem`'s audio through `MobileSpeechLoudness`.
///
/// `AVPlayer.volume` and `AVAudioMixInputParameters.setVolume` both stop at
/// 1.0, so the only way to make text-to-speech narration louder than its file is
/// an `MTAudioProcessingTap` on the item's audio mix, which hands every
/// rendered buffer to our code before it reaches the output. The tap is
/// created pre-effects, so it sees the file's own samples whatever playback
/// rate the listener chose; the loudness stages' time constants then run at
/// the file's clock, which at 1.5× is a difference nobody hears.
///
/// AirPlay routes may render without running the tap. Nothing fails in that
/// case; the narration plays at its stored level, as before.
enum MobileLoudnessAudioMix {
    /// A player item for `asset` whose audio track is boosted. Falls back to a
    /// plain item when the asset has no audio track or the tap cannot be made.
    @MainActor
    static func playerItem(for asset: AVAsset) async -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.audioMix = await audioMix(for: asset)
        return item
    }

    static func audioMix(for asset: AVAsset) async -> AVAudioMix? {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let tap = makeTap() else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    /// The tap's storage: the loudness stages plus what `prepare` learned
    /// about the processing format. Retained by the tap from `init` to
    /// `finalize`; the C callbacks reach it through `MTAudioProcessingTapGetStorage`.
    private final class TapState {
        let loudness = MobileSpeechLoudness()
        private var isFloat32 = false
        private var isInterleaved = false

        func prepare(_ format: AudioStreamBasicDescription) {
            let flags = format.mFormatFlags
            isFloat32 = format.mFormatID == kAudioFormatLinearPCM
                && flags & kAudioFormatFlagIsFloat != 0
                && format.mBitsPerChannel == 32
            isInterleaved = flags & kAudioFormatFlagIsNonInterleaved == 0
            loudness.prepare(sampleRate: format.mSampleRate, channelCount: max(1, Int(format.mChannelsPerFrame)))
        }

        func process(_ list: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
            guard isFloat32, frameCount > 0 else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count > 0 else { return }
            if isInterleaved {
                let first = buffers[0]
                guard let base = first.mData?.assumingMemoryBound(to: Float.self) else { return }
                let channelCount = max(1, Int(first.mNumberChannels))
                let available = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channelCount
                let frames = min(frameCount, available)
                withUnsafeTemporaryAllocation(
                    of: UnsafeMutablePointer<Float>.self,
                    capacity: channelCount
                ) { pointers in
                    for channel in 0..<channelCount {
                        pointers.initializeElement(at: channel, to: base + channel)
                    }
                    loudness.process(
                        channels: UnsafeBufferPointer(pointers),
                        frameCount: frames,
                        stride: channelCount
                    )
                }
            } else {
                var frames = frameCount
                withUnsafeTemporaryAllocation(
                    of: UnsafeMutablePointer<Float>.self,
                    capacity: buffers.count
                ) { pointers in
                    var count = 0
                    for buffer in buffers {
                        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        frames = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                        pointers.initializeElement(at: count, to: data)
                        count += 1
                    }
                    guard count > 0 else { return }
                    loudness.process(
                        channels: UnsafeBufferPointer(rebasing: pointers[0..<count]),
                        frameCount: frames
                    )
                }
            }
        }
    }

    private static func state(of tap: MTAudioProcessingTap) -> TapState {
        Unmanaged<TapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    }

    private static func makeTap() -> MTAudioProcessingTap? {
        let state = Unmanaged.passRetained(TapState())
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: state.toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<TapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                MobileLoudnessAudioMix.state(of: tap).prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frameCount, _, bufferList, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, frameCount, bufferList, flagsOut, nil, framesOut
                )
                guard status == noErr else { return }
                MobileLoudnessAudioMix.state(of: tap).process(bufferList, frameCount: Int(framesOut.pointee))
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tap
        )
        guard status == noErr, let tap else {
            // `finalize` never runs for a tap that was not created.
            state.release()
            return nil
        }
        return tap
    }
}
