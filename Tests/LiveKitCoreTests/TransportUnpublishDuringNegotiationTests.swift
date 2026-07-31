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

/// Unpublishing a track while an offer is still unanswered must leave the connection usable.
///
/// An SFU answers with a narrower simulcast layer list than it was offered, so applying the answer
/// updates the sender's encodings. Against a sender the unpublish already made terminal that fails
/// with `"Cannot disable encodings on a stopped sender."`, and `Transport` has no rollback — the
/// PeerConnection is left in `.haveLocalOffer`.
///
/// These tests drive both halves of the exchange themselves, so the ordering is fixed rather than
/// raced; a failure here is real, not flake.
@Suite(.serialized, .tags(.media))
struct TransportUnpublishDuringNegotiationTests {
    @Test func unpublishingMidNegotiationLeavesTheConnectionUsable() async throws {
        let publisher = try await makePublisherWithOpenOffer()
        defer { Task { await publisher.transport.close() } }

        let answer = try await answer(to: publisher.offer, withoutRid: "f")

        try await publisher.transport.remove(track: publisher.transceiver.sender)

        do {
            try await publisher.transport.set(remoteDescription: answer, offerId: publisher.offerId)
        } catch {
            let state = await publisher.transport.signalingState
            Issue.record("setRemoteDescription failed after unpublish: \(error) — publisher stranded in .\(state.name)")
        }

        let state = await publisher.transport.signalingState
        #expect(state == .stable, "publisher must return to .stable, was .\(state.name)")
    }

    /// Control: the same answer applies cleanly when no unpublish intervenes, so the failure above
    /// is caused by the unpublish and not by a malformed SDP.
    @Test func answerNarrowingSimulcastAppliesWhenNothingIsUnpublished() async throws {
        let publisher = try await makePublisherWithOpenOffer()
        defer { Task { await publisher.transport.close() } }

        let answer = try await answer(to: publisher.offer, withoutRid: "f")

        try await publisher.transport.set(remoteDescription: answer, offerId: publisher.offerId)

        #expect(await publisher.transport.signalingState == .stable)
    }

    /// The connection surviving is only half of it — the video track's resources must still be
    /// freed, or unpublishing leaks them.
    @Test func unpublishingMidNegotiationStillReleasesTheVideoTrack() async throws {
        let delegate = NoopTransportDelegate()
        let transport = try Transport(config: .liveKitDefault(),
                                      target: .publisher,
                                      primary: true,
                                      delegate: delegate)
        defer { Task { await transport.close() } }

        let track = LocalVideoTrack.createBufferTrack()
        let transceiver = try await transport.addTransceiver(
            with: track.mediaTrack,
            transceiverInit: makeSendOnlyTransceiverInit(sendEncodings: makeSimulcastEncodings()),
        )

        let sentOffers = StateSync<[(LKRTCSessionDescription, UInt32)]>([])
        await transport.set(onOfferBlock: { sd, offerId in
            sentOffers.mutate { $0.append((sd, offerId)) }
        })

        // The offer goes out and stays unanswered.
        try await transport.negotiate(force: true)
        let (offer, offerId) = try #require(sentOffers.copy().last, "onOfferBlock was never called")
        #expect(await transport.signalingState == .haveLocalOffer)

        // The unpublish lands inside the open transaction.
        try await transport.remove(track: transceiver.sender)

        let answer = try await answer(to: offer, withoutRid: "f")
        try await transport.set(remoteDescription: answer, offerId: offerId)
        #expect(await transport.signalingState == .stable,
                "the answer must apply cleanly and return the publisher to .stable")

        // Unpublishing always requests a renegotiation.
        try await transport.negotiate(force: true)

        #expect(transceiver.isStopped, "the video track's resources were never released")

        let followUp = try #require(sentOffers.copy().last?.0, "no follow-up offer was sent")
        #expect(followUp.sdp != offer.sdp)
        #expect(followUp.sdp.contains("m=video 0 "),
                "the follow-up offer must reject the m-line so the SFU drops the track")
    }

    // MARK: - Publisher under test

    private struct PublisherWithOpenOffer {
        let transport: Transport
        let delegate: NoopTransportDelegate
        let transceiver: LKRTCRtpTransceiver
        let offer: LKRTCSessionDescription
        let offerId: UInt32
    }

    /// Drives a fresh publisher `Transport` to `.haveLocalOffer` with one simulcast video sender.
    private func makePublisherWithOpenOffer() async throws -> PublisherWithOpenOffer {
        let delegate = NoopTransportDelegate()
        let transport = try Transport(config: .liveKitDefault(),
                                      target: .publisher,
                                      primary: true,
                                      delegate: delegate)

        let track = LocalVideoTrack.createBufferTrack()
        let transceiver = try await transport.addTransceiver(
            with: track.mediaTrack,
            transceiverInit: makeSendOnlyTransceiverInit(sendEncodings: makeSimulcastEncodings()),
        )

        // `createOffer` is private; the offer is observed through `onOfferBlock`, which also
        // yields the offerId the answer has to echo back.
        let sentOffer = StateSync<(LKRTCSessionDescription, UInt32)?>(nil)
        await transport.set(onOfferBlock: { sd, offerId in
            sentOffer.mutate { $0 = (sd, offerId) }
        })
        try await transport.negotiate(force: true)

        let (offer, offerId) = try #require(sentOffer.copy(), "onOfferBlock was never called")
        #expect(offer.sdp.contains("a=simulcast:send"), "offer must carry simulcast for this repro")
        #expect(await transport.signalingState == .haveLocalOffer)

        return PublisherWithOpenOffer(transport: transport, delegate: delegate,
                                      transceiver: transceiver, offer: offer, offerId: offerId)
    }
}

// MARK: - Answering half

private enum AnswerError: Error {
    case offerHasNoSimulcastSection
    case ridNotOffered(available: String)
}

/// Answers `offer` while echoing back a narrower simulcast layer list than was offered, which is
/// what makes libwebrtc update the sender's encodings as the answer is applied.
///
/// - Note: a plain answerer drops the `a=rid`/`a=simulcast` lines and libwebrtc then skips the
///   layer update entirely, so the rewrite below is required.
private func answer(to offer: LKRTCSessionDescription, withoutRid rid: String) async throws -> LKRTCSessionDescription {
    let offeredRids = try parseSimulcastSendRids(offer.sdp)
    guard offeredRids.contains(rid) else {
        throw AnswerError.ridNotOffered(available: offeredRids.joined(separator: ";"))
    }
    let keptRids = offeredRids.filter { $0 != rid }

    guard let answerer = RTC.createPeerConnection(.liveKitDefault(), constraints: .defaultPCConstraints) else {
        throw LiveKitError(.webRTC, message: "Failed to create answerer PeerConnection")
    }
    defer { answerer.close() }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        answerer.setRemoteDescription(offer) { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    let rawAnswer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
        answerer.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sd, error in
            if let error {
                continuation.resume(throwing: error)
            } else if let sd {
                continuation.resume(returning: sd)
            } else {
                continuation.resume(throwing: LiveKitError(.invalidState, message: "No answer and no error were provided."))
            }
        }
    }

    return RTC.createSessionDescription(type: .answer,
                                        sdp: appendRecvSimulcast(rids: keptRids, to: rawAnswer.sdp))
}

/// `a=simulcast:send q;h;f` → `["q", "h", "f"]`
private func parseSimulcastSendRids(_ sdp: String) throws -> [String] {
    let prefix = "a=simulcast:send "
    for line in sdp.components(separatedBy: .newlines) {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix(prefix) else { continue }
        return line.dropFirst(prefix.count)
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    throw AnswerError.offerHasNoSimulcastSection
}

/// Appends `a=rid:<rid> recv` lines and the matching `a=simulcast:recv` list to the last media
/// section. Callers offer a single video m-section, so appending at the end is safe.
private func appendRecvSimulcast(rids: [String], to sdp: String) -> String {
    let eol = sdp.contains("\r\n") ? "\r\n" : "\n"
    var lines = sdp.components(separatedBy: eol)

    var insertAt = lines.count
    while insertAt > 0, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
        insertAt -= 1
    }

    let added = rids.map { "a=rid:\($0) recv" } + ["a=simulcast:recv \(rids.joined(separator: ";"))"]
    lines.insert(contentsOf: added, at: insertAt)
    return lines.joined(separator: eol)
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

private extension LKRTCSignalingState {
    /// Readable name for failure messages; the ObjC enum has no `CustomStringConvertible`.
    var name: String {
        switch self {
        case .stable: "stable"
        case .haveLocalOffer: "haveLocalOffer"
        case .haveLocalPrAnswer: "haveLocalPrAnswer"
        case .haveRemoteOffer: "haveRemoteOffer"
        case .haveRemotePrAnswer: "haveRemotePrAnswer"
        case .closed: "closed"
        @unknown default: "unknown(\(rawValue))"
        }
    }
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
