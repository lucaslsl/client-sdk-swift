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
@testable import LiveKit
import Testing

func makeManualMicrophoneConstantBuffer(
    sampleRate: Double,
    channels: AVAudioChannelCount,
    value: Float,
) throws -> AVAudioPCMBuffer {
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

final class PCMObservationRenderer: AudioRenderer, @unchecked Sendable {
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
        var maximumMagnitude: Float = 0
        if let channels = pcmBuffer.floatChannelData {
            for channel in 0 ..< Int(pcmBuffer.format.channelCount) {
                for frame in 0 ..< Int(pcmBuffer.frameLength) {
                    let magnitude = abs(channels[channel][frame])
                    maximumMagnitude = max(maximumMagnitude, magnitude)
                }
            }
        } else if let channels = pcmBuffer.int16ChannelData {
            for channel in 0 ..< Int(pcmBuffer.format.channelCount) {
                for frame in 0 ..< Int(pcmBuffer.frameLength) {
                    let magnitude = abs(Float(channels[channel][frame])) / Float(Int16.max)
                    maximumMagnitude = max(maximumMagnitude, magnitude)
                }
            }
        }
        state.mutate {
            $0.count += 1
            $0.sampleRates.append(pcmBuffer.format.sampleRate)
            $0.channelCounts.append(pcmBuffer.format.channelCount)
            $0.commonFormats.append(pcmBuffer.format.commonFormat)
            $0.frameDurations.append(Double(pcmBuffer.frameLength) / pcmBuffer.format.sampleRate)
            $0.maximumMagnitude = max($0.maximumMagnitude, maximumMagnitude)
            $0.callbackRanOnMainThread = $0.callbackRanOnMainThread || Thread.isMainThread
        }
    }
}
