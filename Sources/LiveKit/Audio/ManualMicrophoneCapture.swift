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

/// The disposition of one caller-provided manual microphone buffer.
public enum ManualMicrophoneCaptureResult: Int, Sendable {
    /// The buffer was accepted without crossing the queue target.
    case accepted

    /// The buffer was accepted, but the producer should slow down until the queue returns to its target.
    case acceptedWithBackpressure

    /// The manual microphone graph is not connected and running.
    case notReady

    /// Accepting the buffer would exceed the hard queue ceiling, so the buffer was dropped.
    case droppedQueueFull

    /// The buffer has an empty or unsupported PCM format.
    case rejectedFormat
}

/// A snapshot of the bounded manual microphone queue.
public struct ManualMicrophoneCaptureMetrics: Sendable, Equatable {
    /// The queue target, in seconds.
    public let targetQueueDuration: TimeInterval

    /// The hard queue ceiling, in seconds.
    public let maximumQueueDuration: TimeInterval

    /// The number of output-format frames currently queued.
    public let queuedFrames: Int

    /// The current queued duration, in seconds.
    public let queuedDuration: TimeInterval

    /// The highest number of output-format frames queued since the graph last started.
    public let highWaterMarkFrames: Int

    /// The highest queued duration since the graph last started, in seconds.
    public let highWaterMarkDuration: TimeInterval

    /// The number of buffers accepted since the graph last started.
    public let acceptedBufferCount: UInt64

    /// The number of accepted buffers that also signaled backpressure.
    public let backpressuredBufferCount: UInt64

    /// The number of buffers dropped at the queue ceiling since the graph last started.
    public let droppedBufferCount: UInt64

    /// The number of output-format frames dropped at the queue ceiling since the graph last started.
    public let droppedFrames: UInt64

    /// The number of calls rejected because the graph was not ready since it last started.
    public let notReadyBufferCount: UInt64

    /// The number of buffers rejected for their format since the graph last started.
    public let rejectedFormatBufferCount: UInt64
}

extension MixerEngineObserver {
    struct ManualMicrophoneQueueState {
        static let targetDuration: TimeInterval = 0.05
        static let maximumDuration: TimeInterval = 0.1

        var generation: UInt64 = 0
        var nextBufferID: UInt64 = 0
        var sampleRate: Double = 0
        var queuedBuffers: [UInt64: AVAudioFrameCount] = [:]
        var queuedFrames: AVAudioFrameCount = 0
        var highWaterMarkFrames: AVAudioFrameCount = 0
        var acceptedBufferCount: UInt64 = 0
        var backpressuredBufferCount: UInt64 = 0
        var droppedBufferCount: UInt64 = 0
        var droppedFrames: UInt64 = 0
        var notReadyBufferCount: UInt64 = 0
        var rejectedFormatBufferCount: UInt64 = 0

        var targetFrames: AVAudioFrameCount {
            AVAudioFrameCount(sampleRate * Self.targetDuration)
        }

        var maximumFrames: AVAudioFrameCount {
            AVAudioFrameCount(sampleRate * Self.maximumDuration)
        }

        var metrics: ManualMicrophoneCaptureMetrics {
            ManualMicrophoneCaptureMetrics(
                targetQueueDuration: Self.targetDuration,
                maximumQueueDuration: Self.maximumDuration,
                queuedFrames: Int(queuedFrames),
                queuedDuration: duration(for: queuedFrames),
                highWaterMarkFrames: Int(highWaterMarkFrames),
                highWaterMarkDuration: duration(for: highWaterMarkFrames),
                acceptedBufferCount: acceptedBufferCount,
                backpressuredBufferCount: backpressuredBufferCount,
                droppedBufferCount: droppedBufferCount,
                droppedFrames: droppedFrames,
                notReadyBufferCount: notReadyBufferCount,
                rejectedFormatBufferCount: rejectedFormatBufferCount,
            )
        }

        mutating func reset(sampleRate: Double = 0) {
            generation &+= 1
            nextBufferID = 0
            self.sampleRate = sampleRate
            queuedBuffers.removeAll(keepingCapacity: true)
            queuedFrames = 0
            highWaterMarkFrames = 0
            acceptedBufferCount = 0
            backpressuredBufferCount = 0
            droppedBufferCount = 0
            droppedFrames = 0
            notReadyBufferCount = 0
            rejectedFormatBufferCount = 0
        }

        mutating func reserve(frameCount: AVAudioFrameCount) -> (ManualMicrophoneCaptureResult, UInt64?) {
            guard frameCount <= maximumFrames, queuedFrames <= maximumFrames - frameCount else {
                droppedBufferCount &+= 1
                droppedFrames &+= UInt64(frameCount)
                return (.droppedQueueFull, nil)
            }

            nextBufferID &+= 1
            let bufferID = nextBufferID
            queuedBuffers[bufferID] = frameCount
            queuedFrames += frameCount
            highWaterMarkFrames = max(highWaterMarkFrames, queuedFrames)
            acceptedBufferCount &+= 1

            if queuedFrames > targetFrames {
                backpressuredBufferCount &+= 1
                return (.acceptedWithBackpressure, bufferID)
            }
            return (.accepted, bufferID)
        }

        mutating func consume(bufferID: UInt64, generation: UInt64) {
            guard generation == self.generation,
                  let frameCount = queuedBuffers.removeValue(forKey: bufferID)
            else { return }

            queuedFrames -= frameCount
        }

        private func duration(for frames: AVAudioFrameCount) -> TimeInterval {
            guard sampleRate > 0 else { return 0 }
            return TimeInterval(frames) / sampleRate
        }
    }

    /// Captures caller-provided microphone PCM through the bounded manual microphone lane.
    ///
    /// Input is converted synchronously to the audio engine format before it is queued. The
    /// queue targets 50 ms and has a hard 100 ms ceiling. A result of
    /// ``ManualMicrophoneCaptureResult/acceptedWithBackpressure`` means the buffer was accepted,
    /// but the caller should slow down until ``manualMicrophoneCaptureMetrics`` returns to target.
    /// ``ManualMicrophoneCaptureResult/droppedQueueFull`` means the buffer was not accepted.
    ///
    /// The graph must be running in manual rendering mode before this method can accept data.
    /// This method never opens or selects a physical audio device and does not apply ``appVolume``.
    ///
    /// - Parameter inputBuffer: A nonempty PCM buffer to use as microphone input.
    /// - Returns: The disposition of this buffer.
    @discardableResult
    public func capture(microphoneAudio inputBuffer: AVAudioPCMBuffer) -> ManualMicrophoneCaptureResult {
        _state.mutate { state in
            let micNode = state.micNode
            guard state.isInputConnected,
                  let playerNodeFormat = state.playerNodeFormat,
                  let engine = micNode.engine,
                  engine.isInManualRenderingMode,
                  engine.isRunning
            else {
                state.manualMicrophoneQueue.notReadyBufferCount &+= 1
                return .notReady
            }

            let conversion = state.convertMicrophoneBuffer(inputBuffer, to: playerNodeFormat)
            guard let convertedBuffer = conversion.buffer else {
                return conversion.failure
            }
            return scheduleMicrophoneBuffer(convertedBuffer, on: micNode, state: &state)
        }
    }

    private func scheduleMicrophoneBuffer(
        _ buffer: AVAudioPCMBuffer,
        on micNode: AVAudioPlayerNode,
        state: inout State,
    ) -> ManualMicrophoneCaptureResult {
        let (result, bufferID) = state.manualMicrophoneQueue.reserve(frameCount: buffer.frameLength)
        guard let bufferID else { return result }
        let generation = state.manualMicrophoneQueue.generation

        micNode.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            self?._state.mutate {
                $0.manualMicrophoneQueue.consume(bufferID: bufferID, generation: generation)
            }
        }

        if !micNode.isPlaying, let engine = micNode.engine, engine.isRunning {
            micNode.play()
        }
        return result
    }
}

private extension MixerEngineObserver.State {
    mutating func convertMicrophoneBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat,
    ) -> (buffer: AVAudioPCMBuffer?, failure: ManualMicrophoneCaptureResult) {
        guard inputBuffer.frameLength > 0,
              inputBuffer.format.sampleRate > 0,
              inputBuffer.format.channelCount > 0
        else {
            manualMicrophoneQueue.rejectedFormatBufferCount &+= 1
            return (nil, .rejectedFormat)
        }

        let frameCapacity = AudioConverter.frameCapacity(
            from: inputBuffer.format,
            to: outputFormat,
            inputFrameCount: inputBuffer.frameLength,
        )
        guard frameCapacity > 0, frameCapacity <= manualMicrophoneQueue.maximumFrames else {
            manualMicrophoneQueue.droppedBufferCount &+= 1
            manualMicrophoneQueue.droppedFrames &+= UInt64(frameCapacity)
            return (nil, .droppedQueueFull)
        }

        let converter: AudioConverter
        if let existingConverter = microphoneAudioConverters[inputBuffer.format] {
            converter = existingConverter
        } else {
            guard let newConverter = AudioConverter(
                from: inputBuffer.format,
                to: outputFormat,
                outputBufferCapacity: manualMicrophoneQueue.maximumFrames,
            ) else {
                manualMicrophoneQueue.rejectedFormatBufferCount &+= 1
                return (nil, .rejectedFormat)
            }
            microphoneAudioConverters[inputBuffer.format] = newConverter
            converter = newConverter
        }

        let outputBuffer = converter.convert(from: inputBuffer)
        guard outputBuffer.frameLength > 0 else {
            manualMicrophoneQueue.rejectedFormatBufferCount &+= 1
            return (nil, .rejectedFormat)
        }
        return (outputBuffer, .accepted)
    }
}
