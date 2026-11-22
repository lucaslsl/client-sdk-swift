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

import Foundation

internal import LiveKitWebRTC

@objcMembers
public class LocalVideoTrack: Track, LocalTrackProtocol, @unchecked Sendable {
    public internal(set) var capturer: VideoCapturer

    var videoSource: LKRTCVideoSource

    init(name: String,
         source: Track.Source,
         capturer: VideoCapturer,
         videoSource: LKRTCVideoSource,
         reportStatistics: Bool)
    {
        let rtcTrack = RTC.createVideoTrack(source: videoSource)
        rtcTrack.isEnabled = true

        self.capturer = capturer
        self.videoSource = videoSource

        super.init(name: name,
                   kind: .video,
                   source: source,
                   track: rtcTrack,
                   reportStatistics: reportStatistics)
    }

    public func mute() async throws {
        try await super._mute()
    }

    public func unmute() async throws {
        try await super._unmute()
    }

    // MARK: - Internal

    override func startCapture() async throws {
        try await capturer.startCapture()
    }

    override func stopCapture() async throws {
        try await capturer.stopCapture()
    }
}

// MARK: - VideoTrack Protocol

extension LocalVideoTrack: VideoTrackProtocol {
    public func add(videoRenderer: VideoRenderer) {
        capturer.rendererDelegates.add(delegate: videoRenderer)
    }

    public func remove(videoRenderer: VideoRenderer) {
        capturer.rendererDelegates.remove(delegate: videoRenderer)
    }
}

public extension LocalVideoTrack {
    var publishOptions: TrackPublishOptions? { super._state.lastPublishOptions }
    var publishState: Track.PublishState { super._state.publishState }

    /// Convenience access to ``VideoCapturer/processor``.
    var processor: VideoProcessor? {
        get { capturer._state.processor }
        set { capturer._state.mutate { $0.processor = newValue } }
    }
}

public extension LocalVideoTrack {
    /// Sets how WebRTC degrades this track's video when bandwidth or CPU runs short, while it is published.
    ///
    /// The value goes to the track's senders and to every sender the track gets later,
    /// including the one created when the track is republished after a full reconnect. From the first call on,
    /// it takes the place of ``VideoPublishOptions/degradationPreference``.
    ///
    /// Safe to call from any thread, the main thread included: it returns without waiting for WebRTC, and the
    /// senders get the value set last.
    ///
    /// ```swift
    /// track.set(degradationPreference: .maintainFramerate)
    /// ```
    ///
    /// - Parameter degradationPreference: The preference to use. ``DegradationPreference/auto`` resolves as it does
    ///   at publish, to ``DegradationPreference/maintainResolution``.
    /// - Note: Calling this before the track is published, or after it is unpublished, stores the value for the
    ///   next publish.
    func set(degradationPreference: DegradationPreference) {
        _state.mutate { $0.degradationPreference = degradationPreference }

        Self.degradationPreferenceQueue.async {
            let senders = self._state.read { [$0.rtpSender].compactMap(\.self) + $0.rtpSenderForCodec.values }
            self.writeDegradationPreference(to: senders, publishOptions: nil)
        }
    }
}

extension LocalVideoTrack {
    /// Writing sender parameters blocks on WebRTC's signalling thread, so the setter's writes run here instead of
    /// on its caller. The setter's writes and those to each new sender go through this queue and read the stored
    /// value when they run, so an older value can't land after a newer one.
    static let degradationPreferenceQueue = DispatchQueue(label: "LiveKitSDK.degradationPreference")

    /// The preference a sender of this track uses: the value set last with ``set(degradationPreference:)``,
    /// else `publishOptions`' value, or `nil` to leave the sender's own.
    func senderDegradationPreference(publishOptions: VideoPublishOptions?) -> LKRTCDegradationPreference? {
        guard let preference = _state.degradationPreference ?? publishOptions?.degradationPreference else { return nil }
        return preference.toRTCType() ?? .maintainResolution
    }

    /// Call on every new sender of this track, after attaching it, so a value set meanwhile reaches it either way.
    /// Blocks until the sender has it.
    func applyDegradationPreference(to sender: LKRTCRtpSender, publishOptions: VideoPublishOptions?) {
        Self.degradationPreferenceQueue.sync {
            writeDegradationPreference(to: [sender], publishOptions: publishOptions)
        }
    }

    private func writeDegradationPreference(to senders: [LKRTCRtpSender], publishOptions: VideoPublishOptions?) {
        guard let preference = senderDegradationPreference(publishOptions: publishOptions) else { return }
        log("Setting degradationPreference to \(preference) on \(senders.count) sender(s)")
        for sender in senders {
            sender.set(degradationPreference: preference)
        }
    }
}

private extension LKRTCRtpSender {
    func set(degradationPreference: LKRTCDegradationPreference) {
        // Changing params directly doesn't work so we need to update params and set it back to sender.parameters
        let params = parameters
        params.degradationPreference = NSNumber(value: degradationPreference.rawValue)
        parameters = params
    }
}

public extension LocalVideoTrack {
    /// Clone with same ``VideoCapturer``.
    func clone() -> LocalVideoTrack {
        LocalVideoTrack(name: name,
                        source: source,
                        capturer: capturer,
                        videoSource: videoSource,
                        reportStatistics: _state.reportStatistics)
    }
}
