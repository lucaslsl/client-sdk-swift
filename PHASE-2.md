# Phase 2 — Bounded manual microphone capture evidence

Date: 2026-08-24  
Branch: `2.15.3-owned-audio`  
Starting revision: `6fd771b96d497dabaab389ee29fae1a891c5e289`  
Implementation commit: `89e5d2ac` (`Add bounded manual microphone buffer capture`)

## Behavior delivered

`MixerEngineObserver.capture(microphoneAudio:)` is a manual-mode-only Swift API
separate from `capture(appAudio:)`. It synchronously converts supported nonempty
PCM on the caller's thread, schedules accepted buffers on the microphone node,
and returns one of:

- `accepted`: accepted at or below the 50 ms target
- `acceptedWithBackpressure`: accepted above 50 ms and at or below 100 ms
- `notReady`: the manual input graph is not connected and running
- `droppedQueueFull`: accepting the buffer would exceed 100 ms
- `rejectedFormat`: the PCM is empty or cannot be converted

`manualMicrophoneCaptureMetrics` reports current frames/duration, 50 ms target,
100 ms ceiling, high-water frames/duration, and cumulative accepted,
backpressured, dropped, dropped-frame, not-ready, and rejected-format counts for
the current graph generation. Graph connect, start, stop, and release reset the
queue and metrics. Completion callbacks carry a generation so an old graph
cannot consume accounting from a restarted graph.

The implementation uses the SDK's existing `StateSync` serialization and a
separate converter cache for microphone buffers. Conversion, allocation, and
scheduling occur at the synchronous caller entry point, not in an audio render
callback. The unchanged app/screen-share node retains `capture(appAudio:)` and
`appVolume`; remote tests observed microphone PCM while `appVolume` was zero.

The API is intentionally Swift-only because `MixerEngineObserver` and the
existing manual-rendering surface are Swift-only. Its result and metrics are
public `Sendable` value types.

## Focused verification

The focused/sequential SDK policy was followed. No full SDK suite ran.

Passed individually after the final production-source split and before the
manual-mode-only readiness guard, then passed again after that guard:

```text
swift test --filter ManualMicrophoneCaptureTests/aDisconnectedGraphRejectsMicrophoneFrames
swift test --filter ManualMicrophoneCaptureTests/aFastProducerIsBoundedAtOneHundredMilliseconds
swift test --filter ManualMicrophoneCaptureTests/consumedFramesAndGraphStopResetQueueMetrics
swift test --filter ManualMicrophoneCaptureTests/supportedFormatChangesAreConvertedAndEmptyPCMIsRejected
swift test --filter ManualMicrophoneCaptureTests/restartRejectsStoppedFramesAndStartsWithFreshMetrics
```

The published Phase 1 e2e passed twice against local LiveKit Server 1.13.4 after
migration to `capture(microphoneAudio:)`, including 16 kHz mono and 48 kHz
stereo conversion, remote microphone PCM, no physical SDK I/O, mute/unmute on
the same publication/source, and microphone signal while `appVolume` was zero:

```text
swift test --filter ManualPCMContractTests/manualMicrophonePublishesAndResumesOnTheSameSource
```

One initial e2e attempt failed because `ws://localhost:7880` refused the
connection before the required local server was started. Two later attempts
failed only experimental remote-amplitude ordering assertions because Opus
tails and callback boundaries are not deterministic signal-frame boundaries;
that flaky observation was replaced by a deterministic queue-reservation order
test. The coordinator then ran that replacement individually on 2026-08-24; it
passed 1 test in 1 suite with 0 failures:

```text
swift test --filter ManualMicrophoneCaptureTests/framesBelowCapacityReserveInSubmissionOrder
```

Directly affected existing regressions passed individually:

```text
swift test --filter ManualPCMContractTests/manualModeConnectsNoPhysicalInputOrOutputNodes
swift test --filter ManualPCMContractTests/aFastProducerCanQueueMoreThanOneSecondOfManualAudio
```

Static/build checks:

```text
swiftlint lint --strict
xcodebuild build -scheme LiveKit -destination 'platform=macOS'
```

Strict lint passed all 381 Swift files with zero violations. The macOS SDK build
passed with only existing E2EE deprecation warnings.

`swift package generate-documentation --target LiveKit` built the LiveKit
target, then failed in `swift-symbolgraph-extract` because it could not load the
existing binary module `RustLiveKitUniFFI`. This is a DocC harness/module-search
failure; it did not identify a malformed new symbol link.

## Deferred verification and risks

No hardware, acoustic, two-person, two-machine, or perceptual checks ran. Those
remain user-owned under the authoritative plan. The player-node completion
callback uses `StateSync` for queue accounting, matching the SDK's synchronized
state convention; Phase 8 should measure queue behavior under the application's
processing-worker cadence. Phase 3 should begin with the standalone WebRTC APM
feasibility gate without adding Blixel route or UID concepts to the SDK.
