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

/// Unpublishing a video track must free its resources, whatever the surrounding negotiation is
/// doing; unpublishing audio must leave its transceiver alone.
///
/// The leaked resources are native ones that only releasing the transceiver frees, so a release
/// that never happens is the leak. `isStopped`, on transceivers each test holds a reference to,
/// is the observable proxy for it.
@Suite(.serialized, .tags(.media))
struct TransportUnpublishVideoTrackReleaseTests {
    /// Enough rounds that a release covering only part of a batch cannot hide.
    private static let publishUnpublishRounds = 20

    /// Unpublishing several video tracks back to back must release every one of them on the next
    /// offer, not just the first or the last.
    ///
    /// - Note: the audio track is a bystander. The release runs in the same negotiation and must
    ///   skip it: the release is video-only and must stay that way.
    @Test func unpublishingReleasesEveryVideoTrackAndLeavesAudioAlone() async throws {
        let delegate = NoopTransportDelegate()
        let transport = try Transport(config: .liveKitDefault(),
                                      target: .publisher,
                                      primary: true,
                                      delegate: delegate)
        defer { Task { await transport.close() } }

        await transport.set(onOfferBlock: { _, _ in })

        var videoTransceivers: [LKRTCRtpTransceiver] = []
        for _ in 0 ..< 3 {
            let track = LocalVideoTrack.createBufferTrack()
            let transceiver = try await transport.addTransceiver(
                with: track.mediaTrack,
                transceiverInit: makeSendOnlyTransceiverInit(),
            )
            videoTransceivers.append(transceiver)
            try await transport.remove(track: transceiver.sender)
        }

        let audioTrack = RTC.createAudioTrack(source: RTC.createAudioSource(nil))
        let audioTransceiver = try await transport.addTransceiver(
            with: audioTrack,
            transceiverInit: makeSendOnlyTransceiverInit(),
        )
        try await transport.remove(track: audioTransceiver.sender)

        try await transport.negotiate(force: true)

        let live = videoTransceivers.filter { !$0.isStopped }
        #expect(live.isEmpty, "\(live.count) of 3 unpublished video tracks were never released")

        #expect(!audioTransceiver.isStopped, "the audio track must not be released")
    }

    /// Sustained churn: every video track ever published must end up released, not just the most
    /// recent one.
    @Test func repeatedPublishUnpublishReleasesEveryVideoTrack() async throws {
        let delegate = NoopTransportDelegate()
        let transport = try Transport(config: .liveKitDefault(),
                                      target: .publisher,
                                      primary: true,
                                      delegate: delegate)
        defer { Task { await transport.close() } }

        let sentOffers = StateSync<[(LKRTCSessionDescription, UInt32)]>([])
        await transport.set(onOfferBlock: { sd, offerId in
            sentOffers.mutate { $0.append((sd, offerId)) }
        })

        let answerer = LoopbackAnswerer()
        var transceivers: [LKRTCRtpTransceiver] = []

        for _ in 0 ..< Self.publishUnpublishRounds {
            let track = LocalVideoTrack.createBufferTrack()
            let transceiver = try await transport.addTransceiver(
                with: track.mediaTrack,
                transceiverInit: makeSendOnlyTransceiverInit(sendEncodings: makeSimulcastEncodings()),
            )
            transceivers.append(transceiver)

            try await completeNegotiation(on: transport, answeredBy: answerer, offers: sentOffers)
            try await transport.remove(track: transceiver.sender)
            try await completeNegotiation(on: transport, answeredBy: answerer, offers: sentOffers)
        }

        let live = transceivers.enumerated().filter { !$0.element.isStopped }.map(\.offset)
        #expect(live.isEmpty,
                "\(live.count) of \(Self.publishUnpublishRounds) unpublished video tracks were never released (rounds \(live))")

        #expect(await transport.signalingState == .stable,
                "the transport must be idle at the end of the churn")
    }

    /// A publisher whose offer is never answered cannot renegotiate, so tracks unpublished in that
    /// window stay held until an ICE restart re-applies the last remote description. Every
    /// reconnect performs one.
    @Test func videoTracksUnpublishedDuringAnUnansweredOfferAreReleasedAfterIceRestart() async throws {
        let delegate = NoopTransportDelegate()
        let transport = try Transport(config: .liveKitDefault(),
                                      target: .publisher,
                                      primary: true,
                                      delegate: delegate)
        defer { Task { await transport.close() } }

        let sentOffers = StateSync<[(LKRTCSessionDescription, UInt32)]>([])
        await transport.set(onOfferBlock: { sd, offerId in
            sentOffers.mutate { $0.append((sd, offerId)) }
        })

        var transceivers: [LKRTCRtpTransceiver] = []
        for _ in 0 ..< 3 {
            let track = LocalVideoTrack.createBufferTrack()
            let transceiver = try await transport.addTransceiver(
                with: track.mediaTrack,
                transceiverInit: makeSendOnlyTransceiverInit(sendEncodings: makeSimulcastEncodings()),
            )
            transceivers.append(transceiver)
        }

        // One complete negotiation first: the ICE restart needs a remote description to re-apply,
        // so a publisher stuck on its very first offer has no way out.
        let answerer = LoopbackAnswerer()
        try await completeNegotiation(on: transport, answeredBy: answerer, offers: sentOffers)
        #expect(await transport.signalingState == .stable)

        // This offer is never answered.
        try await transport.negotiate(force: true)
        #expect(await transport.signalingState == .haveLocalOffer,
                "the second offer must be left outstanding for this test to mean anything")

        // Three unpublishes land while the transaction is open.
        for transceiver in transceivers {
            try await transport.remove(track: transceiver.sender)
        }

        // The recovery a reconnect performs.
        try await transport.createAndSendOffer(iceRestart: true)

        let live = transceivers.filter { !$0.isStopped }
        #expect(live.isEmpty,
                "\(live.count) of 3 video tracks were still held after the ICE restart")

        let restartOffer = try #require(sentOffers.copy().last?.0, "the ICE restart sent no offer")
        #expect(restartOffer.sdp.countLines(startingWith: "m=video 0 ") == 3,
                "the post-restart offer must describe all three m-lines as rejected")
    }

    // MARK: - Helpers

    /// One full offer/answer round trip, driven from the test rather than a server.
    private func completeNegotiation(on transport: Transport,
                                     answeredBy answerer: LoopbackAnswerer,
                                     offers: StateSync<[(LKRTCSessionDescription, UInt32)]>) async throws
    {
        try await transport.negotiate(force: true)
        let (offer, offerId) = try #require(offers.copy().last, "onOfferBlock was never called")
        let answer = try await answerer.answer(to: offer)
        try await transport.set(remoteDescription: answer, offerId: offerId)
    }
}

// MARK: - Answering half

/// A single long-lived `LKRTCPeerConnection` answering every offer, as a real remote peer does.
///
/// - Note: it does not narrow the simulcast layer list, so it never triggers an encoding update.
private final class LoopbackAnswerer: @unchecked Sendable {
    private let pc: LKRTCPeerConnection

    init() {
        guard let pc = RTC.createPeerConnection(.liveKitDefault(), constraints: .defaultPCConstraints) else {
            fatalError("Failed to create answerer PeerConnection")
        }
        self.pc = pc
    }

    deinit { pc.close() }

    func answer(to offer: LKRTCSessionDescription) async throws -> LKRTCSessionDescription {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(offer) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        let answer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            pc.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sd, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let sd {
                    continuation.resume(returning: sd)
                } else {
                    continuation.resume(throwing: LiveKitError(.invalidState, message: "No answer and no error were provided."))
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(answer) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        return answer
    }
}

// MARK: - Transport scaffolding

/// Minimal ``TransportDelegate`` for offline ``Transport`` tests that never exercise callbacks.
/// `MulticastDelegate` holds delegates weakly, so tests must keep this alive themselves.
private final class NoopTransportDelegate: TransportDelegate {
    func transport(_: Transport, didUpdateState _: LKRTCPeerConnectionState) {}
    func transport(_: Transport, didGenerateIceCandidate _: IceCandidate) {}
    func transport(_: Transport, didOpenDataChannel _: LKRTCDataChannel) {}
    func transport(_: Transport, didAddTrack _: LKRTCMediaStreamTrack, rtpReceiver _: LKRTCRtpReceiver, streams _: [LKRTCMediaStream]) {}
    func transport(_: Transport, didRemoveTrack _: LKRTCMediaStreamTrack) {}
    func transportShouldNegotiate(_: Transport) {}
}

private func makeSendOnlyTransceiverInit(sendEncodings: [LKRTCRtpEncodingParameters]? = nil) -> LKRTCRtpTransceiverInit {
    let transInit = DispatchQueue.liveKitWebRTC.sync { LKRTCRtpTransceiverInit() }
    transInit.direction = .sendOnly
    if let sendEncodings {
        transInit.sendEncodings = sendEncodings
    }
    return transInit
}

/// Simulcast send encodings shaped like `Dimensions.encodings(from:)` produces for a three-layer
/// screen share: low → high, each rid scaled down from the top layer.
private func makeSimulcastEncodings(rids: [String] = VideoQuality.RIDs) -> [LKRTCRtpEncodingParameters] {
    let scaleDownFactors = [4.0, 2.0, 1.0]
    return rids.enumerated().map { index, rid in
        RTC.createRtpEncodingParameters(rid: rid, scaleDownBy: scaleDownFactors[safe: index] ?? 1.0)
    }
}

private extension String {
    func countLines(startingWith prefix: String) -> Int {
        components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }
            .count
    }
}
