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

@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif
@preconcurrency import LiveKitWebRTC

/// A live degradation preference reaches the track's sender, and every later sender the
/// track gets, while a track that never had one keeps the preference its publish options give.
///
/// Publishing and republishing need a server, so these tests stand in for the publish path with
/// the two steps it takes on each new sender: attaching it to the track and applying the track's
/// preference to it. Senders come from a real, offline publisher `Transport`.
@Suite(.serialized, .tags(.media))
struct LiveDegradationPreferenceTests {
    @Test func settingThePreferenceChangesThePublishedSender() async throws {
        let (transport, delegate) = try makePublisher()
        defer { Task { await transport.close() } }
        _ = delegate

        let track = LocalVideoTrack.createBufferTrack()
        let sender = try await publish(track, on: transport, publishOptions: VideoPublishOptions())
        #expect(sender.degradationPreference == .maintainResolution)

        track.set(degradationPreference: .maintainFramerate)
        waitForSenderWrites()
        #expect(sender.degradationPreference == .maintainFramerate)

        track.set(degradationPreference: .maintainResolution)
        waitForSenderWrites()
        #expect(sender.degradationPreference == .maintainResolution)
    }

    @Test func settingThePreferenceReturnsWithoutWaitingForWebRTC() async throws {
        let (transport, delegate) = try makePublisher()
        defer { Task { await transport.close() } }
        _ = delegate

        let track = LocalVideoTrack.createBufferTrack()
        let sender = try await publish(track, on: transport, publishOptions: VideoPublishOptions(degradationPreference: .maintainResolution))

        // Holding the queue the setter hands its sender writes to shows the call returns before the write.
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        LocalVideoTrack.degradationPreferenceQueue.async { gate.wait() }

        track.set(degradationPreference: .maintainFramerate)
        #expect(sender.degradationPreference == .maintainResolution)

        gate.signal()
        waitForSenderWrites()
        #expect(sender.degradationPreference == .maintainFramerate)
    }

    @Test func aRepublishedTrackGetsTheValueSetLastOnItsNewSender() async throws {
        let (transport, delegate) = try makePublisher()
        defer { Task { await transport.close() } }
        _ = delegate

        let publishOptions = VideoPublishOptions(degradationPreference: .maintainResolution)
        let track = LocalVideoTrack.createBufferTrack()
        let firstSender = try await publish(track, on: transport, publishOptions: publishOptions)

        track.set(degradationPreference: .balanced)
        track.set(degradationPreference: .maintainFramerate)

        // A republish adds a new transceiver for the same track, with the original publish options.
        try await transport.remove(track: firstSender)
        let newSender = try await publish(track, on: transport, publishOptions: publishOptions)

        #expect(newSender.degradationPreference == .maintainFramerate)
    }

    @Test func aPreferenceSetBeforePublishAppliesAtPublish() async throws {
        let (transport, delegate) = try makePublisher()
        defer { Task { await transport.close() } }
        _ = delegate

        let track = LocalVideoTrack.createBufferTrack()
        track.set(degradationPreference: .maintainFramerate)

        let sender = try await publish(track, on: transport, publishOptions: VideoPublishOptions(degradationPreference: .maintainResolution))

        #expect(sender.degradationPreference == .maintainFramerate)
    }

    @Test(arguments: [
        (DegradationPreference.auto, LKRTCDegradationPreference.maintainResolution),
        (.maintainFramerate, .maintainFramerate),
        (.balanced, .balanced),
    ])
    func aTrackNeverSetUsesItsPublishOptions(publishOptionsPreference: DegradationPreference,
                                             expected: LKRTCDegradationPreference) async throws
    {
        let (transport, delegate) = try makePublisher()
        defer { Task { await transport.close() } }
        _ = delegate

        let track = LocalVideoTrack.createBufferTrack()
        let sender = try await publish(track, on: transport, publishOptions: VideoPublishOptions(degradationPreference: publishOptionsPreference))

        #expect(sender.degradationPreference == expected)
    }

    @Test func autoResolvesToMaintainResolution() async throws {
        let (transport, delegate) = try makePublisher()
        defer { Task { await transport.close() } }
        _ = delegate

        let track = LocalVideoTrack.createBufferTrack()
        let sender = try await publish(track, on: transport, publishOptions: VideoPublishOptions(degradationPreference: .maintainFramerate))

        track.set(degradationPreference: .auto)
        waitForSenderWrites()

        #expect(sender.degradationPreference == .maintainResolution)
    }

    @Test func aBackupCodecSenderFollowsThePreferenceToo() async throws {
        let (transport, delegate) = try makePublisher()
        defer { Task { await transport.close() } }
        _ = delegate

        let track = LocalVideoTrack.createBufferTrack()
        _ = try await publish(track, on: transport, publishOptions: VideoPublishOptions())
        track.set(degradationPreference: .maintainFramerate)

        // The backup-codec path needs a server; this is the sender it attaches and the step it takes on it.
        let transInit = DispatchQueue.liveKitWebRTC.sync { LKRTCRtpTransceiverInit() }
        transInit.direction = .sendOnly
        let backupSender = try await transport.addTransceiver(with: track.mediaTrack, transceiverInit: transInit).sender
        track._state.mutate { $0.rtpSenderForCodec[.vp8] = backupSender }
        track.applyDegradationPreference(to: backupSender, publishOptions: nil)
        #expect(backupSender.degradationPreference == .maintainFramerate)

        track.set(degradationPreference: .balanced)
        waitForSenderWrites()
        #expect(backupSender.degradationPreference == .balanced)
    }

    // MARK: - Helpers

    /// What `LocalParticipant` does with each new sender of a video track: attach it to the track,
    /// then apply the track's preference. Both steps are internal; the public path needs a server.
    private func publish(_ track: LocalVideoTrack,
                         on transport: Transport,
                         publishOptions: VideoPublishOptions) async throws -> LKRTCRtpSender
    {
        let transInit = DispatchQueue.liveKitWebRTC.sync { LKRTCRtpTransceiverInit() }
        transInit.direction = .sendOnly
        let transceiver = try await transport.addTransceiver(with: track.mediaTrack, transceiverInit: transInit)
        await track.set(transport: transport, rtpSender: transceiver.sender)
        track.applyDegradationPreference(to: transceiver.sender, publishOptions: publishOptions)
        return transceiver.sender
    }

    /// The setter returns before WebRTC has the value; this waits for the writes it queued.
    private func waitForSenderWrites() {
        LocalVideoTrack.degradationPreferenceQueue.sync {}
    }

    /// `MulticastDelegate` holds the delegate weakly, so the caller keeps it alive.
    private func makePublisher() throws -> (Transport, TransportDelegate) {
        let delegate = NoopTransportDelegate()
        let transport = try Transport(config: .liveKitDefault(),
                                      target: .publisher,
                                      primary: true,
                                      delegate: delegate)
        return (transport, delegate)
    }
}

private extension LKRTCRtpSender {
    var degradationPreference: LKRTCDegradationPreference? {
        parameters.degradationPreference.flatMap { LKRTCDegradationPreference(rawValue: $0.intValue) }
    }
}

private final class NoopTransportDelegate: TransportDelegate {
    func transport(_: Transport, didUpdateState _: LKRTCPeerConnectionState) {}
    func transport(_: Transport, didGenerateIceCandidate _: IceCandidate) {}
    func transport(_: Transport, didOpenDataChannel _: LKRTCDataChannel) {}
    func transport(_: Transport, didAddTrack _: LKRTCMediaStreamTrack, rtpReceiver _: LKRTCRtpReceiver, streams _: [LKRTCMediaStream]) {}
    func transport(_: Transport, didRemoveTrack _: LKRTCMediaStreamTrack) {}
    func transportShouldNegotiate(_: Transport) {}
}
