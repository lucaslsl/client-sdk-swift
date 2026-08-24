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

@preconcurrency import AVFoundation
import Foundation
@testable import LiveKit
import Testing

@Suite(.serialized, .tags(.audio)) struct ManualMicrophoneCaptureTests {
    @Test func aDisconnectedGraphRejectsMicrophoneFrames() throws {
        let mixer = MixerEngineObserver()
        let buffer = try makeConstantBuffer(duration: 0.01, value: 0.1)

        #expect(mixer.capture(microphoneAudio: buffer) == .notReady)
        #expect(mixer.manualMicrophoneCaptureMetrics.notReadyBufferCount == 1)
        #expect(mixer.manualMicrophoneCaptureMetrics.acceptedBufferCount == 0)
        #expect(mixer.manualMicrophoneCaptureMetrics.queuedFrames == 0)
    }

    @Test func aFastProducerIsBoundedAtOneHundredMilliseconds() throws {
        try prepareManualAudio()
        defer { resetAudioManager() }
        try AudioManager.shared.startLocalRecording(audioProcessingOptions: .noProcessing)

        let oneHundredMilliseconds = try makeConstantBuffer(duration: 0.1, value: 0.1)
        #expect(AudioManager.shared.mixer.capture(microphoneAudio: oneHundredMilliseconds) == .acceptedWithBackpressure)
        #expect(AudioManager.shared.mixer.capture(microphoneAudio: oneHundredMilliseconds) == .droppedQueueFull)

        let metrics = AudioManager.shared.mixer.manualMicrophoneCaptureMetrics
        #expect(metrics.queuedDuration <= metrics.maximumQueueDuration)
        #expect(metrics.highWaterMarkDuration <= metrics.maximumQueueDuration)
        #expect(metrics.acceptedBufferCount == 1)
        #expect(metrics.backpressuredBufferCount == 1)
        #expect(metrics.droppedBufferCount == 1)
        #expect(metrics.droppedFrames > 0)
    }

    @Test func framesBelowCapacityReserveInSubmissionOrder() {
        // AVAudioPlayerNode exposes no scheduled-buffer inspection before transport rendering.
        var queue = MixerEngineObserver.ManualMicrophoneQueueState()
        queue.reset(sampleRate: 48000)

        let reservations = (0 ..< 3).map { _ in queue.reserve(frameCount: 480) }
        #expect(reservations.map(\.0) == [.accepted, .accepted, .accepted])
        #expect(reservations.compactMap(\.1) == [1, 2, 3])
    }

    @Test func consumedFramesAndGraphStopResetQueueMetrics() async throws {
        try prepareManualAudio()
        defer { resetAudioManager() }
        try AudioManager.shared.startLocalRecording(audioProcessingOptions: .noProcessing)

        let buffer = try makeConstantBuffer(duration: 0.01, value: 0.1)
        #expect(AudioManager.shared.mixer.capture(microphoneAudio: buffer) == .accepted)
        try await waitUntil {
            AudioManager.shared.mixer.manualMicrophoneCaptureMetrics.queuedFrames == 0
        }
        #expect(AudioManager.shared.mixer.manualMicrophoneCaptureMetrics.highWaterMarkFrames > 0)

        try AudioManager.shared.stopLocalRecording()
        let metrics = AudioManager.shared.mixer.manualMicrophoneCaptureMetrics
        #expect(metrics.queuedFrames == 0)
        #expect(metrics.highWaterMarkFrames == 0)
        #expect(metrics.acceptedBufferCount == 0)
        #expect(metrics.droppedBufferCount == 0)
    }

    @Test func supportedFormatChangesAreConvertedAndEmptyPCMIsRejected() async throws {
        try prepareManualAudio()
        defer { resetAudioManager() }
        try AudioManager.shared.startLocalRecording(audioProcessingOptions: .noProcessing)

        let mono16K = try makeConstantBuffer(duration: 0.01, sampleRate: 16000, channels: 1, value: 0.1)
        #expect(AudioManager.shared.mixer.capture(microphoneAudio: mono16K) == .accepted)
        try await waitUntil {
            AudioManager.shared.mixer.manualMicrophoneCaptureMetrics.queuedFrames == 0
        }

        let stereo48K = try makeConstantBuffer(duration: 0.01, sampleRate: 48000, channels: 2, value: 0.2)
        #expect(AudioManager.shared.mixer.capture(microphoneAudio: stereo48K) == .accepted)

        let empty = try makeConstantBuffer(duration: 0, value: 0)
        #expect(AudioManager.shared.mixer.capture(microphoneAudio: empty) == .rejectedFormat)
        #expect(AudioManager.shared.mixer.manualMicrophoneCaptureMetrics.rejectedFormatBufferCount == 1)
    }

    @Test func restartRejectsStoppedFramesAndStartsWithFreshMetrics() throws {
        try prepareManualAudio()
        defer { resetAudioManager() }
        let buffer = try makeConstantBuffer(duration: 0.01, value: 0.1)

        try AudioManager.shared.startLocalRecording(audioProcessingOptions: .noProcessing)
        #expect(AudioManager.shared.mixer.capture(microphoneAudio: buffer) == .accepted)
        try AudioManager.shared.stopLocalRecording()
        #expect(AudioManager.shared.mixer.capture(microphoneAudio: buffer) == .notReady)
        #expect(AudioManager.shared.mixer.manualMicrophoneCaptureMetrics.notReadyBufferCount == 1)

        try AudioManager.shared.startLocalRecording(audioProcessingOptions: .noProcessing)
        let metrics = AudioManager.shared.mixer.manualMicrophoneCaptureMetrics
        #expect(metrics.queuedFrames == 0)
        #expect(metrics.acceptedBufferCount == 0)
        #expect(metrics.notReadyBufferCount == 0)
        #expect(AudioManager.shared.mixer.capture(microphoneAudio: buffer) == .accepted)
    }

    private func prepareManualAudio() throws {
        resetAudioManager()
        AudioManager.shared.set(engineObservers: [AudioManager.shared.mixer])
        try AudioManager.shared.setManualRenderingMode(true)
    }

    private func resetAudioManager() {
        try? AudioManager.shared.stopLocalRecording()
        _ = AudioManager.shared.stopPlayout()
        try? AudioManager.shared.setManualRenderingMode(false)
        AudioManager.shared.set(engineObservers: [AudioManager.shared.mixer])
    }

    private func makeConstantBuffer(
        duration: TimeInterval,
        sampleRate: Double = 48000,
        channels: AVAudioChannelCount = 1,
        value: Float,
    ) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false,
        ))
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channelData = try #require(buffer.floatChannelData)

        for channel in 0 ..< Int(channels) {
            for frame in 0 ..< Int(frameCount) {
                channelData[channel][frame] = value
            }
        }
        return buffer
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: () -> Bool,
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition())
    }
}
