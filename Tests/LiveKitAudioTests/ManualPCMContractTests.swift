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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.serialized, .tags(.audio)) struct ManualPCMContractTests {
    @Test func manualModeConnectsNoPhysicalInputOrOutputNodes() throws {
        let probe = ManualGraphProbe()
        try prepareManualAudio(observer: probe)
        defer { resetAudioManager() }

        try AudioManager.shared.startLocalRecording(audioProcessingOptions: .noProcessing)
        #expect(AudioManager.shared.initPlayout() == 0)
        #expect(AudioManager.shared.startPlayout() == 0)

        let snapshot = probe.snapshot
        #expect(snapshot.inputConnections > 0)
        #expect(snapshot.outputConnections == 0)
        #expect(snapshot.allEnginesWereManual)
        #expect(!snapshot.physicalInputSourceSeen)
        #expect(!snapshot.physicalOutputDestinationSeen)
        #expect(!snapshot.callbackRanOnMainThread)
    }

    @Test func aFastProducerCanQueueMoreThanOneSecondOfManualAudio() async throws {
        try prepareManualAudio()
        defer { resetAudioManager() }

        try AudioManager.shared.startLocalRecording(audioProcessingOptions: .noProcessing)

        let silence = try makeConstantBuffer(sampleRate: 16000, channels: 1, value: 0)
        for _ in 0 ..< 120 {
            AudioManager.shared.mixer.capture(appAudio: silence)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let playerNode = AudioManager.shared.mixer.appAudioNode
        let renderTime = try #require(playerNode.lastRenderTime)
        let playerTime = try #require(playerNode.playerTime(forNodeTime: renderTime))
        let renderedDuration = Double(playerTime.sampleTime) / playerTime.sampleRate
        let queuedDuration = 1.2 - renderedDuration

        #expect(queuedDuration > 1.0)
    }

    @Test(.tags(.e2e))
    func manualMicrophonePublishesAndResumesOnTheSameSource() async throws {
        let probe = ManualGraphProbe()
        try prepareManualAudio(observer: probe)
        let combinedRenderer = PCMObservationRenderer()
        let trackRenderer = PCMObservationRenderer()
        AudioManager.shared.add(remoteAudioRenderer: combinedRenderer)
        defer {
            AudioManager.shared.remove(remoteAudioRenderer: combinedRenderer)
            resetAudioManager()
        }

        try await TestEnvironment.withRooms([
            RoomTestingOptions(canSubscribe: true),
            RoomTestingOptions(canPublish: true),
        ]) { rooms in
            let subscriber = try #require(rooms.first)
            let publisher = try #require(rooms.last)
            try await runManualMicrophoneContract(
                subscriber: subscriber,
                publisher: publisher,
                probe: probe,
                combinedRenderer: combinedRenderer,
                trackRenderer: trackRenderer,
            )
        }
    }

    private func runManualMicrophoneContract(
        subscriber: Room,
        publisher: Room,
        probe: ManualGraphProbe,
        combinedRenderer: PCMObservationRenderer,
        trackRenderer: PCMObservationRenderer,
    ) async throws {
        #expect(subscriber.localParticipant.audioTracks.isEmpty)
        let publication = try #require(try await publisher.localParticipant.setMicrophone(
            enabled: true,
            captureOptions: .noProcessing,
            publishOptions: AudioPublishOptions(dtx: false),
        ))
        let remoteTrack = try await remoteAudioTrack(in: subscriber, from: publisher)
        remoteTrack.add(audioRenderer: trackRenderer)
        defer { remoteTrack.remove(audioRenderer: trackRenderer) }

        let signal = try makeSineBuffer(sampleRate: 16000, channels: 1)
        try await assertRemotePCMContract(
            signal: signal,
            probe: probe,
            combinedRenderer: combinedRenderer,
            trackRenderer: trackRenderer,
        )
        try await assertMuteContract(
            publication: publication,
            subscriber: subscriber,
            publisher: publisher,
            combinedRenderer: combinedRenderer,
            trackRenderer: trackRenderer,
        )
        await publisher.localParticipant.unpublishAll()
        try await waitUntil { publisher.localParticipant.audioTracks.isEmpty }
    }

    private func assertRemotePCMContract(
        signal: AVAudioPCMBuffer,
        probe: ManualGraphProbe,
        combinedRenderer: PCMObservationRenderer,
        trackRenderer: PCMObservationRenderer,
    ) async throws {
        try await feedUntil(signal) { trackRenderer.snapshot.maximumMagnitude > 0.05 }
        try await waitUntil { combinedRenderer.snapshot.count >= 5 }

        #expect(probe.snapshot.allEnginesWereManual)
        #expect(!probe.snapshot.physicalInputSourceSeen)
        #expect(probe.snapshot.outputConnections == 0)
        #expect(!probe.snapshot.physicalOutputDestinationSeen)
        #expect(trackRenderer.snapshot.frameDurations.allSatisfy { abs($0 - 0.01) < 0.000_1 })
        #expect(combinedRenderer.snapshot.frameDurations.allSatisfy { abs($0 - 0.01) < 0.000_1 })
        #expect(Set(trackRenderer.snapshot.sampleRates) == [48000])
        #expect(Set(trackRenderer.snapshot.channelCounts) == [1])
        #expect(Set(trackRenderer.snapshot.commonFormats) == [.pcmFormatInt16])
        #expect(Set(combinedRenderer.snapshot.sampleRates) == [48000])
        #expect(Set(combinedRenderer.snapshot.channelCounts) == [1])
        #expect(Set(combinedRenderer.snapshot.commonFormats) == [.pcmFormatInt16])
        #expect(!trackRenderer.snapshot.callbackRanOnMainThread)
        #expect(!combinedRenderer.snapshot.callbackRanOnMainThread)

        trackRenderer.reset()
        let hardwareFormat = try makeSineBuffer(sampleRate: 48000, channels: 2)
        try await feedUntil(hardwareFormat) { trackRenderer.snapshot.maximumMagnitude > 0.05 }
    }

    private func assertMuteContract(
        publication: LocalTrackPublication,
        subscriber: Room,
        publisher: Room,
        combinedRenderer: PCMObservationRenderer,
        trackRenderer: PCMObservationRenderer,
    ) async throws {
        let mutedPublication = try #require(try await publisher.localParticipant.setMicrophone(enabled: false))
        #expect(mutedPublication.sid == publication.sid)
        #expect(AudioManager.shared.mixer.appAudioNode.engine?.isRunning == true)

        let publisherIdentity = try #require(publisher.localParticipant.identity)
        let remotePublication = try #require(subscriber.remoteParticipants[publisherIdentity]?.firstAudioPublication)
        try await waitUntil { remotePublication.isMuted }
        try await Task.sleep(nanoseconds: 300_000_000)

        let signal = try makeSineBuffer(sampleRate: 16000, channels: 1)
        trackRenderer.reset()
        let combinedCountBeforeMutedFeed = combinedRenderer.snapshot.count
        try await feed(signal, count: 50)
        try await waitUntil { combinedRenderer.snapshot.count > combinedCountBeforeMutedFeed }
        #expect(trackRenderer.snapshot.maximumMagnitude < 0.05)

        let resumedPublication = try #require(try await publisher.localParticipant.setMicrophone(enabled: true))
        #expect(resumedPublication.sid == publication.sid)
        try await feedUntil(signal) { trackRenderer.snapshot.maximumMagnitude > 0.05 }

        let callbacksBeforeRemoval = combinedRenderer.snapshot.count
        AudioManager.shared.remove(remoteAudioRenderer: combinedRenderer)
        try await feed(signal, count: 20)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(combinedRenderer.snapshot.count == callbacksBeforeRemoval)
    }

    private func prepareManualAudio(observer: (any AudioEngineObserver)? = nil) throws {
        resetAudioManager()
        let observers: [any AudioEngineObserver] = if let observer {
            [AudioManager.shared.mixer, observer]
        } else {
            [AudioManager.shared.mixer]
        }
        AudioManager.shared.set(engineObservers: observers)
        try AudioManager.shared.setManualRenderingMode(true)
        #expect(AudioManager.shared.isManualRenderingMode)
    }

    private func resetAudioManager() {
        try? AudioManager.shared.stopLocalRecording()
        _ = AudioManager.shared.stopPlayout()
        try? AudioManager.shared.setManualRenderingMode(false)
        AudioManager.shared.set(engineObservers: [AudioManager.shared.mixer])
    }

    private func makeSineBuffer(sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(sampleRate / 100)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false,
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channelData = try #require(buffer.floatChannelData)

        for channel in 0 ..< Int(channels) {
            for frame in 0 ..< Int(frameCount) {
                channelData[channel][frame] = 0.25 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        return buffer
    }

    private func makeConstantBuffer(sampleRate: Double, channels: AVAudioChannelCount, value: Float) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(sampleRate / 100)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false,
        ))
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

    private func feed(_ buffer: AVAudioPCMBuffer, count: Int) async throws {
        for _ in 0 ..< count {
            AudioManager.shared.mixer.capture(appAudio: buffer)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func feedUntil(
        _ buffer: AVAudioPCMBuffer,
        condition: () -> Bool,
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !condition() {
            AudioManager.shared.mixer.capture(appAudio: buffer)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition())
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        condition: () -> Bool,
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(condition())
    }

    private func remoteAudioTrack(in subscriber: Room, from publisher: Room) async throws -> RemoteAudioTrack {
        let publisherIdentity = try #require(publisher.localParticipant.identity)
        let remoteParticipant = try #require(subscriber.remoteParticipants[publisherIdentity])
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let track = remoteParticipant.firstAudioPublication?.track as? RemoteAudioTrack {
                return track
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw LiveKitError(.timedOut, message: "Remote manual microphone was not subscribed")
    }
}

private final class ManualGraphProbe: AudioEngineObserver, @unchecked Sendable {
    struct Snapshot {
        var inputConnections = 0
        var outputConnections = 0
        var allEnginesWereManual = true
        var physicalInputSourceSeen = false
        var physicalOutputDestinationSeen = false
        var callbackRanOnMainThread = false
    }

    var next: (any AudioEngineObserver)?
    var snapshot: Snapshot { state.copy() }

    private let state = StateSync(Snapshot())

    func engineWillConnectInput(
        _ engine: AVAudioEngine,
        src: AVAudioNode?,
        dst _: AVAudioNode,
        format _: AVAudioFormat,
        context _: [AnyHashable: Any],
    ) -> Int {
        state.mutate {
            $0.inputConnections += 1
            $0.allEnginesWereManual = $0.allEnginesWereManual && engine.isInManualRenderingMode
            $0.physicalInputSourceSeen = $0.physicalInputSourceSeen || src != nil
            $0.callbackRanOnMainThread = $0.callbackRanOnMainThread || Thread.isMainThread
        }
        return 0
    }

    func engineWillConnectOutput(
        _ engine: AVAudioEngine,
        src _: AVAudioNode,
        dst: AVAudioNode?,
        format _: AVAudioFormat,
        context _: [AnyHashable: Any],
    ) -> Int {
        state.mutate {
            $0.outputConnections += 1
            $0.allEnginesWereManual = $0.allEnginesWereManual && engine.isInManualRenderingMode
            $0.physicalOutputDestinationSeen = $0.physicalOutputDestinationSeen || dst != nil
            $0.callbackRanOnMainThread = $0.callbackRanOnMainThread || Thread.isMainThread
        }
        return 0
    }
}

private final class PCMObservationRenderer: AudioRenderer, @unchecked Sendable {
    struct Snapshot {
        var count = 0
        var sampleRates: [Double] = []
        var channelCounts: [AVAudioChannelCount] = []
        var commonFormats: [AVAudioCommonFormat] = []
        var frameDurations: [TimeInterval] = []
        var maximumMagnitude: Float = 0
        var callbackRanOnMainThread = false
    }

    var snapshot: Snapshot { state.copy() }

    private let state = StateSync(Snapshot())

    func reset() {
        state.mutate { $0 = Snapshot() }
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        var magnitude: Float = 0
        if let channels = pcmBuffer.floatChannelData {
            for channel in 0 ..< Int(pcmBuffer.format.channelCount) {
                for frame in 0 ..< Int(pcmBuffer.frameLength) {
                    magnitude = max(magnitude, abs(channels[channel][frame]))
                }
            }
        } else if let channels = pcmBuffer.int16ChannelData {
            for channel in 0 ..< Int(pcmBuffer.format.channelCount) {
                for frame in 0 ..< Int(pcmBuffer.frameLength) {
                    magnitude = max(magnitude, abs(Float(channels[channel][frame])) / Float(Int16.max))
                }
            }
        }

        state.mutate {
            $0.count += 1
            $0.sampleRates.append(pcmBuffer.format.sampleRate)
            $0.channelCounts.append(pcmBuffer.format.channelCount)
            $0.commonFormats.append(pcmBuffer.format.commonFormat)
            $0.frameDurations.append(Double(pcmBuffer.frameLength) / pcmBuffer.format.sampleRate)
            $0.maximumMagnitude = max($0.maximumMagnitude, magnitude)
            $0.callbackRanOnMainThread = $0.callbackRanOnMainThread || Thread.isMainThread
        }
    }
}
