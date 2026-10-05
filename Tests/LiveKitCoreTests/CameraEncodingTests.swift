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

import CoreVideo
@testable import LiveKit
import LiveKitTestSupport
import Testing

@Suite(.serialized)
struct CameraEncodingTests {
    @Test func encodingLimitsFollowSizeChangesAndRepublishing() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true), RoomTestingOptions(canSubscribe: true)]) { rooms in
            let track = LocalVideoTrack.createBufferTrack(name: "camera", source: .camera, options: .init(dimensions: .h720_169))
            let capturer = try #require(track.capturer as? BufferCapturer)
            let dimensions = StateSync(Dimensions.h720_169)
            let frames = Task {
                while !Task.isCancelled {
                    let size = dimensions.copy()
                    var buffer: CVPixelBuffer?
                    let status = CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                                                     [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
                    if status == kCVReturnSuccess, let buffer { capturer.capture(buffer) }
                    try await Task.sleep(nanoseconds: 33_333_333)
                }
            }
            defer { frames.cancel() }
            let publication = try await rooms[0].localParticipant.publish(videoTrack: track, options: .init(
                encoding: .init(maxBitrate: 1_000_000, maxFps: 30), simulcast: false, preferredCodec: .vp8,
            ))
            let identity = try #require(rooms[0].localParticipant.identity)
            let remote = try #require(rooms[1].remoteParticipants[identity])
            try await eventually { remote.videoTracks.first?.track != nil }
            let received = try #require(remote.videoTracks.first?.track as? RemoteVideoTrack)
            let renderer = CameraFrameObserver()
            received.add(videoRenderer: renderer)
            try await eventually { renderer.size == .h720_169 }
            #expect(throws: LiveKitError.self) { try publication.setCameraEncoding(.init(maxBitrate: 0, maxFps: 30)) }
            try publication.setCameraEncoding(.init(maxBitrate: 500_000, maxFps: 30))
            dimensions.mutate { $0 = .h360_169 }
            try await eventually { renderer.size == .h360_169 }
            // Sender limits have no public getter; frame dimensions alone cannot prove the bitrate ceiling.
            try await eventually { track._state.rtpSender?.parameters.encodings.first?.maxBitrateBps?.intValue == 500_000 }
            #expect((track.publishOptions as? VideoPublishOptions)?.encoding?.maxBitrate == 500_000)
            try await rooms[0].debug_simulate(scenario: .quickReconnect)
            try await eventually { track._state.rtpSender?.parameters.encodings.first?.maxBitrateBps?.intValue == 500_000 }
            try await rooms[0].debug_simulate(scenario: .fullReconnect)
            try await eventually {
                rooms[0].localParticipant.videoTracks.first.map { $0.sid != publication.sid } ?? false
            }
            try await eventually { track._state.rtpSender?.parameters.encodings.first?.maxBitrateBps?.intValue == 500_000 }
            let republished = try #require(rooms[0].localParticipant.videoTracks.first as? LocalTrackPublication)
            try republished.setCameraEncoding(.init(maxBitrate: 1_000_000, maxFps: 30))
            dimensions.mutate { $0 = .h720_169 }
            try await eventually { track._state.rtpSender?.parameters.encodings.first?.maxBitrateBps?.intValue == 1_000_000 }
            try await eventually { rooms[1].remoteParticipants[identity]?.videoTracks.first?.track != nil }
            let nextReceived = try #require(rooms[1].remoteParticipants[identity]?.videoTracks.first?.track as? RemoteVideoTrack)
            let nextRenderer = CameraFrameObserver()
            nextReceived.add(videoRenderer: nextRenderer)
            try await eventually { nextRenderer.size == .h720_169 }
            #expect(track._state.rtpSender?.parameters.encodings.count == 1)
        }
    }

    private func eventually(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(condition(), sourceLocation: sourceLocation)
        guard condition() else { throw LiveKitError(.timedOut) }
    }
}

private final class CameraFrameObserver: VideoRenderer, @unchecked Sendable {
    private let latest = StateSync<Dimensions?>(nil)
    var size: Dimensions? { latest.copy() }
    var isAdaptiveStreamEnabled: Bool { false }
    var adaptiveStreamSize: CGSize { .zero }
    func render(frame: VideoFrame) { latest.mutate { $0 = frame.dimensions } }
}
