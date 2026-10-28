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

internal import LiveKitWebRTC

public let kLiveKitKrispAudioProcessorName = "livekit_krisp_noise_cancellation"

/// Used to modify audio buffers before they are sent to the network or played to the user
@objc
public protocol AudioCustomProcessingDelegate: Sendable {
    /// An optional identifier for the audio processor implementation.
    /// This can be used to identify different types of audio processing (e.g. noise cancellation).
    /// Generally you can leave this as the default value.
    @objc optional
    var audioProcessingName: String { get }

    /// Provides the sample rate and number of channels to configure your delegate for processing
    @objc
    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int)

    /// Provides a chunk of audio data that can be modified in place
    @objc
    func audioProcessingProcess(audioBuffer: LKAudioBuffer)

    /// Called when the audio processing is no longer needed so it may clean up any resources
    @objc
    func audioProcessingRelease()
}

class AudioCustomProcessingDelegateAdapter: MulticastDelegate<AudioRenderer>, @unchecked Sendable, LKRTCAudioCustomProcessingDelegate {
    // MARK: - Public

    let label: String
    var target: AudioCustomProcessingDelegate? { _state.target }

    // MARK: - Private

    private struct State {
        var target: AudioCustomProcessingDelegate?
        var isAttached: Bool = false
        var isSilenced: Bool = false
    }

    private var _state = StateSync(State())

    /// While true, each buffer is zeroed after the renderers have taken their
    /// copy, so they still hear the processed capture and WebRTC encodes silence.
    var isSilenced: Bool {
        get { _state.isSilenced }
        set {
            _state.mutate { $0.isSilenced = newValue }
            updateRTCAttachment()
        }
    }

    private let rtcDelegateSetter: (LKRTCAudioCustomProcessingDelegate?) -> Void

    func set(target: AudioCustomProcessingDelegate?, oldTarget: AudioCustomProcessingDelegate? = nil) {
        // Clear WebRTC delegate first if there's an old target - this triggers audioProcessingRelease() on it
        if oldTarget != nil {
            rtcDelegateSetter(nil)
            _state.mutate { $0.isAttached = false }
        }
        _state.mutate { $0.target = target }
        updateRTCAttachment()
    }

    init(label: String,
         rtcDelegateSetter: @escaping (LKRTCAudioCustomProcessingDelegate?) -> Void)
    {
        self.label = label
        self.rtcDelegateSetter = rtcDelegateSetter
        super.init(label: "AudioCustomProcessingDelegateAdapter.\(label)")
        log("label: \(label)")
    }

    // Override add/remove to manage RTC attachment
    override func add(delegate: AudioRenderer) {
        super.add(delegate: delegate)
        updateRTCAttachment()
    }

    override func remove(delegate: AudioRenderer) {
        super.remove(delegate: delegate)
        updateRTCAttachment()
    }

    private func updateRTCAttachment() {
        let result = _state.mutate { state -> (didChange: Bool, delegate: LKRTCAudioCustomProcessingDelegate?) in
            let shouldAttach = state.target != nil || isDelegatesNotEmpty || state.isSilenced
            guard shouldAttach != state.isAttached else { return (false, nil) }
            state.isAttached = shouldAttach
            return (true, shouldAttach ? self : nil)
        }

        guard result.didChange else { return }

        // Call into WebRTC outside the lock to avoid re-entrancy from callbacks.
        rtcDelegateSetter(result.delegate)
    }

    // MARK: - AudioCustomProcessingDelegate

    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        target?.audioProcessingInitialize(sampleRate: sampleRateHz, channels: channels)
    }

    func audioProcessingProcess(audioBuffer: LKRTCAudioBuffer) {
        let (target, isSilenced) = _state.read { ($0.target, $0.isSilenced) }
        let lkAudioBuffer = LKAudioBuffer(audioBuffer: audioBuffer)
        target?.audioProcessingProcess(audioBuffer: lkAudioBuffer)

        // Convert to pcmBuffer and notify only if an audioRenderer is added.
        // The conversion copies, so the zeroing below never reaches a renderer.
        if isDelegatesNotEmpty, let pcmBuffer = lkAudioBuffer.toAVAudioPCMBuffer() {
            notify { $0.render(pcmBuffer: pcmBuffer) }
        }

        if isSilenced {
            for channel in 0 ..< lkAudioBuffer.channels {
                lkAudioBuffer.rawBuffer(forChannel: channel).update(repeating: 0, count: lkAudioBuffer.frames)
            }
        }
    }

    func audioProcessingRelease() {
        target?.audioProcessingRelease()
    }
}
