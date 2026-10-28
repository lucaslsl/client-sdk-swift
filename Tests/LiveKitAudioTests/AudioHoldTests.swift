/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import AVFoundation
@testable import LiveKit
import LiveKitWebRTC
import Testing

@Suite(.serialized, .tags(.audio)) struct AudioHoldTests {
    @Test func aHeldTrackIsSignalledMutedButKeepsCapturing() async throws {
        let track = LocalAudioTrack.createTrack()
        defer { AudioManager.shared.isCaptureSilenced = false }

        try await track.hold()

        #expect(track.isHeld)
        #expect(track.isMuted)
        #expect(track.mediaTrack.isEnabled)
        #expect(AudioManager.shared.isCaptureSilenced)
    }

    @Test func holdingAMutedTrackEnablesItsCapture() async throws {
        let track = LocalAudioTrack.createTrack()
        defer { AudioManager.shared.isCaptureSilenced = false }
        try await track.mute()

        try await track.hold()

        #expect(track.isMuted)
        #expect(track.mediaTrack.isEnabled)
    }

    @Test func muteEndsAHoldAsAPlainMute() async throws {
        let track = LocalAudioTrack.createTrack()
        defer { AudioManager.shared.isCaptureSilenced = false }
        try await track.hold()

        try await track.mute()

        #expect(!track.isHeld)
        #expect(track.isMuted)
        #expect(!track.mediaTrack.isEnabled)
        #expect(!AudioManager.shared.isCaptureSilenced)
    }

    @Test func unmuteEndsAHoldAndSendsTheMicrophoneAgain() async throws {
        let track = LocalAudioTrack.createTrack()
        defer { AudioManager.shared.isCaptureSilenced = false }
        try await track.hold()

        try await track.unmute()

        #expect(!track.isHeld)
        #expect(!track.isMuted)
        #expect(track.mediaTrack.isEnabled)
        #expect(!AudioManager.shared.isCaptureSilenced)
    }

    // LocalTrackPublication.mute() and unmute() call these directly, so a
    // hold must end through them as well as through the track's own methods.
    @Test func mutingThroughThePublicationPathEndsAHold() async throws {
        let track = LocalAudioTrack.createTrack()
        defer { AudioManager.shared.isCaptureSilenced = false }
        try await track.hold()

        try await track._mute()

        #expect(!track.isHeld)
        #expect(!track.mediaTrack.isEnabled)
        #expect(!AudioManager.shared.isCaptureSilenced)
    }

    @Test func unmutingThroughThePublicationPathEndsAHold() async throws {
        let track = LocalAudioTrack.createTrack()
        defer { AudioManager.shared.isCaptureSilenced = false }
        try await track.hold()

        try await track._unmute()

        #expect(!track.isHeld)
        #expect(!track.isMuted)
        #expect(!AudioManager.shared.isCaptureSilenced)
    }

    @Test func unpublishingAHeldTrackLiftsTheSilence() async throws {
        let track = LocalAudioTrack.createTrack()
        defer { AudioManager.shared.isCaptureSilenced = false }
        try await track.hold()
        try await track.onPublish()

        try await track.onUnpublish()

        #expect(!track.isHeld)
        #expect(!AudioManager.shared.isCaptureSilenced)
    }

    @Test func endingATrackThatIsNotHeldLeavesAnotherTracksHold() async throws {
        let held = LocalAudioTrack.createTrack()
        defer { AudioManager.shared.isCaptureSilenced = false }
        try await held.hold()

        try await LocalAudioTrack.createTrack().mute()

        #expect(held.isHeld)
        #expect(AudioManager.shared.isCaptureSilenced)
    }

    @Test func aSilencedCaptureReachesRenderersButLeavesOnlySilence() async throws {
        // WebRTC hands the adapter its buffers; a subclass stands in for one.
        let adapter = AudioCustomProcessingDelegateAdapter(label: "test", rtcDelegateSetter: { _ in })
        let renderer = PeakRenderer()
        adapter.add(delegate: renderer)
        adapter.isSilenced = true
        let buffer = FakeAudioBuffer(sample: 1000)

        adapter.audioProcessingProcess(audioBuffer: buffer)

        #expect(await renderer.nextPeak() == 1000)
        #expect(buffer.samples.allSatisfy { $0 == 0 })
    }

    @Test func anUnsilencedCaptureIsLeftAsItIs() async throws {
        let adapter = AudioCustomProcessingDelegateAdapter(label: "test", rtcDelegateSetter: { _ in })
        let buffer = FakeAudioBuffer(sample: 1000)

        adapter.audioProcessingProcess(audioBuffer: buffer)

        #expect(buffer.samples.allSatisfy { $0 == 1000 })
    }
}

private final class FakeAudioBuffer: LKRTCAudioBuffer, @unchecked Sendable {
    var samples: [Float]

    init(sample: Float) {
        samples = Array(repeating: sample, count: 480)
    }

    override var channels: Int { 1 }
    override var frames: Int { samples.count }
    override var framesPerBand: Int { samples.count }
    override var bands: Int { 1 }

    override func rawBuffer(forChannel _: Int) -> UnsafeMutablePointer<Float> {
        samples.withUnsafeMutableBufferPointer { $0.baseAddress! }
    }
}

private final class PeakRenderer: NSObject, AudioRenderer, @unchecked Sendable {
    private let peaks = AsyncStream<Int16>.makeStream()

    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard let data = pcmBuffer.int16ChannelData else { return }
        let peak = (0 ..< Int(pcmBuffer.frameLength)).map { abs(data[0][$0]) }.max() ?? 0
        peaks.continuation.yield(peak)
    }

    func nextPeak() async -> Int16? {
        var iterator = peaks.stream.makeAsyncIterator()
        return await iterator.next()
    }
}
