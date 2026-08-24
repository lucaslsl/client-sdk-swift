# Phase 1 — Manual PCM contract evidence

Date: 2026-08-24  
Branch: `2.15.3-owned-audio`  
Starting revision: `1ed0c7ce6a7f44ec7fe808a6425cf771abb2d286`

## Automated gate

Passed. At the pinned baseline, manual rendering opens neither a physical input
nor a physical output, caller-fed PCM reaches a remote microphone publication,
and combined remote PCM remains available without SDK playout. No production
SDK API changed in this phase.

`ManualPCMContractTests` establishes these observable behaviors:

- Starting recording and playout leaves the engine in manual rendering mode.
  The input connection has no physical source, and no output connection or
  physical destination is created.
- Non-interleaved Float32 input is accepted as 10 ms, 16 kHz mono buffers and
  as the common 10 ms, 48 kHz stereo hardware form.
- Both the subscribed-track renderer and `add(remoteAudioRenderer:)` receive
  10 ms, 48 kHz, mono Int16 PCM. Their callbacks execute off the main thread.
- A subscriber with no local microphone receives both per-track and combined
  remote PCM while the SDK has no output graph.
- Muting retains the publication SID and the running manual source graph. The
  remote track reports muted and receives silence; unmuting the same
  publication resumes the signal.
- Removing the combined renderer stops its callbacks, and unpublishing removes
  the publication.

The callback adapters dispatch serially on SDK-owned multicast queues. Source
inspection identifies `LiveKitSDK.Multicast.AudioRendererAdapter` for a track
renderer and `LiveKitSDK.Multicast.AudioCustomProcessingDelegateAdapter.renderPre`
for the combined remote renderer. The tests deliberately contract only the
off-main behavior, not those private queue labels or callback timing jitter.

## Scheduling characterization

`capture(appAudio:)` converts caller buffers to the manual engine format and
schedules them directly on an `AVAudioPlayerNode`. It returns `Void` and has no
completion, queue bound, or backpressure signal. A producer that submitted 120
10 ms buffers immediately still had more than one second queued after 100 ms.
The existing API can therefore accumulate unbounded playout latency when its
producer gets ahead.

## Gaps for Phase 2

- The entry point is semantically app/screen-share audio rather than a
  microphone-specific lane, and app-volume policy applies to it.
- Calls do not report accepted, not-ready, dropped, backpressured, or rejected.
- Queue duration, high-water, and cumulative drop metrics do not exist.
- Calls made before the graph is connected and running are logged and dropped.
- Conversion failure is logged and dropped rather than returned as a precise
  format error.
- The caller cannot deterministically reset or own the source queue across a
  graph stop/restart.
- There is no queue ceiling; the current player-node scheduling path permits
  latency to grow with producer lead.

These are contract gaps, not architecture blockers. Phase 2 should begin by
replacing the semantic use of `capture(appAudio:)` with the planned bounded,
microphone-specific caller-fed PCM lane. No Phase 2 design or implementation is
included here.

## Verification

- `swift test --filter ManualPCMContractTests`: passed 3 tests in 1 suite.
- `xcodebuild build -scheme LiveKit -destination 'platform=macOS'`: passed.
- `xcodebuild test -scheme LiveKit -only-testing LiveKitCoreTests -destination 'platform=macOS'`:
  interrupted after 259 seconds when Xcode's test runner stopped making
  progress while waiting for a crashed test operation to restart. Before the
  stall, the runner emitted server ping/pong timeouts. This is an Xcode test
  harness/regression-run gap, not a failure of the focused PCM contract.
- `swiftlint lint --strict Tests/LiveKitAudioTests/ManualPCMContractTests.swift`:
  passed with no violations.

The automated server test used two in-process participants against local
LiveKit Server 1.13.4. It is not a two-person, two-machine, hardware, acoustic,
or perceptual qualification. Those user-owned checks remain deferred to the
later gates in the authoritative plan.
