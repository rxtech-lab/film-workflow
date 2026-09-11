# Validation and release status

Implementation and automated integration are present in this working tree. This is **not yet a completed release sign-off**: live authenticated Mapbox capture and manual visible preview/timeline interaction checks remain open. Do not distribute the renderer cutover until those gates are completed. No release, commit, or installation over the user's existing app was performed.

## Verified locally

Environment: arm64 macOS 26.5.1 (25F80), Swift 6.3.2, package declared with Swift tools 6.2 / macOS 26. The package targets have no third-party Swift dependencies.

- A fresh copy containing only `Package.swift`, `Sources`, and `Tests` built in `/tmp/rxremotion-swift-only-consumer`. There was no Browser directory, npm project, or node_modules. With PATH restricted to system directories, `swift run -c release RxRemotionExample --check` completed compilation, preview creation/seek, PNG and movie export.
- Package integration tests exercise composition discovery, editable multi-file TSX, source reload, CSS and local assets, bundled Leaflet CSS, simultaneous project preparation, distinct preview positions, delayed resources, WebGL and SVG capture, particle geometry, MapKit snapshots/projections, fixture-backed OSM tiles, explicit unsupported-effect/Mapbox-token errors, and 4K half-transparent PNG output.
- Three.js integration imports all four bundled 3D packages, verifies shared mesh identity and Remotion context, checks PNG placement/transparency at frames 0 and 15, and decodes all 30 ProRes frames to verify animation and alpha. App-hosted tests verify visible ThreeCanvas preview pixels while seeking 0 → 15 → 0 and confirm the supported-package instructions reach in-app and MCP agents under both write policies. Visible preview testing runs inside the app's window lifecycle; a command-line Swift test host does not provide the normal AppKit event loop.
- Decoded media checks cover dimensions, duration and exact frame count, ProRes alpha, embedded video frames, audio sequence offsets, trims, positive speed, volume envelopes, native audio loops, and gain above unity. A 0.5→2.0 gain change produced the expected 16× PCM energy ratio. Cancellation before rendering and after capture started preserved destinations and removed incomplete work.
- Film Workflow builds. Focused app tests pass for MCP `create_project` returning `preview`, shared leases, screenshots, alpha render versions/cache reuse, source preservation, closing/reopening documents, and source hashing. Existing document persistence tests also pass.
- The built app contains the RxRemotion resource bundle and no RemotionRuntime resource folder. Legacy installer/startup/signing build phases and host JIT exceptions have been removed. Shared subprocess/environment helpers remain for unrelated agent/caption features.

## Reproduce

```sh
cd Packages/RxRemotion
swift build
swift run RxRemotionExample --check
RX_REMOTION_INTEGRATION=1 RX_REMOTION_MAPKIT=1 swift test -c release
RX_REMOTION_BENCHMARK=1 swift test -c release --filter BenchmarkTests
# Repeat with RX_REMOTION_BENCHMARK_FRAMES=120 for the longer memory check.
```

`RX_REMOTION_MAPKIT=1` uses Apple's network-backed snapshot service. OSM tests use a deterministic local transport fixture, not a real/public tile service. The live Mapbox test is enabled only when `RX_REMOTION_MAPBOX_TOKEN` is supplied in the test environment; do not commit credentials. The missing-token regression always runs with integration tests and requires an explicit error.

From the repository root:

```sh
xcodebuild -project film-workflow.xcodeproj -scheme film-workflow \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:film-workflowTests/RemotionNativeWorkflowTests \
  -only-testing:film-workflowTests/RemotionSourceHasherTests \
  -only-testing:film-workflowTests/ProjectDocumentTests test
```

## Measurements

The table below records the baseline before Three.js was added. With `three`, `@react-three/fiber`, `@react-three/drei`, and `@remotion/three` bundled, the browser resources total 17,988,642 logical bytes (17.16 MiB). The timing samples below have not been remeasured for 3D scenes.

These are local samples, not universal performance claims. The benchmark is a simple 1920×1080, 30 fps composition with Arial typography, a spring transform, an interpolated bar and SVG. Preview/capture measurements run after the reported compilation unless stated otherwise. No control was imposed on unrelated system activity.

| Measurement | Result |
|---|---:|
| Shipped browser resources, logical bytes | 15,130,441 bytes (14.43 MiB) |
| Old Bun + installed JS dependencies, logical bytes, excluding Chromium | 341,106,663 bytes (325.30 MiB) |
| Resource size reduction on that basis | 95.6% |
| Cold compilation | 0.364 s |
| Warm prepare in the same engine | 0.00074 s |
| Preview creation after compilation | 0.108 s |
| Seek command round trip (not display latency) | 0.00040 s |
| 1080p PNG capture, advancing through frame 15 | 0.309 s |
| 30-frame H.264 export | 0.966 s, 31.1 output frames/s |
| Longer 120-frame H.264 sample | 2.464 s, 48.7 output frames/s |
| Host peak RSS, 30 / 120 frames, excluding WebKit services | 843.7 / 843.7 MB |

The native encoder's pixel pool is limited to three buffers. Audio timing/envelope metadata grows with composition duration; decoded picture frames are not accumulated. The RSS measurements do not include the separate WebKit GPU/content/network services and therefore are not a total-process-tree memory comparison. Four-K PNG capture passed; four-K movie throughput has not been benchmarked.

A development-only Chromium still of the same frame completed in 1.74 seconds including its CLI/bundling startup. Against that PNG, the corrected native frame had mean absolute RGB error 0.2475 / 255 and 99.619% of pixels within 10 levels per channel. This verifies the representative typography/spring/SVG layout, not pixel identity for every project. Reference files and local benchmark reports were written under `/tmp/rxremotion-benchmark-*`; BenchmarkTests retains reproducible native fixtures there.

The legacy movie baseline did not complete: its default eight-page run reported closed browser sessions, and the single-page retry stalled at frame zero. Those test processes were stopped. There is consequently no reliable old/new movie throughput ratio, legacy seek-latency comparison, or aggregate memory comparison to report. No runtime fallback was added.

## Parallel rendering and freeze regression (2026-09-11)

A Debug 1080p transparent 12-frame fixture reproduced the freeze: 22.415 s export time and a maximum 1.822 s main-actor heartbeat gap. Full-frame alpha reconstruction was running a Swift pixel loop on MainActor. After moving image processing, encoding/mixing, project copying/hashing and cache I/O off MainActor and adding bounded workers, the same Debug fixture took 0.987 s with a maximum 0.038 s heartbeat gap. These figures include the alpha-loop fix and parallelism together; they are not a claim that parallelism alone gives a 23× speedup.

Sequential Release measurements of the same 1080p typography/spring/SVG fixture, extended to 120 frames and encoded as ProRes 4444:

| WebView workers | Export time | Output frames/s | Host peak RSS, excluding WebKit services | Maximum main-actor gap |
|---:|---:|---:|---:|---:|
| 1 | 5.107 s | 23.5 | 1,004 MB | 45 ms |
| 2 | 3.053 s | 39.3 | 1,098 MB | 40 ms |
| 4 | 2.224 s | 54.0 | 1,327 MB | 39 ms |

Two workers are the automatic default; four are available explicitly. The two-worker sample was 1.67× faster than serial; four were 2.30× faster. Native source-video PNGs share a bounded 32 MiB cache, and requests for each AVFoundation decoder are serialized. Frame buffers and the encoder pool are bounded. Nonoverlapping audio runs reuse native mixer tracks, avoiding a new track for every loop iteration.

`ParallelRenderingTests` compares every decoded ProRes frame across one, two and four workers, including stateful canvas history, transparency and nondivisible frame counts. Normal-speed trimmed/looped audio and volume envelopes are compared numerically, allowing PCM quantization noise and implicit trailing silence. Exact PCM identity is not asserted for system pitch-preserving speed conversion; existing speed-change, trim, loop and audio-onset tests remain required. A 1080p alpha export also runs a 10 ms main-actor heartbeat and rejects stalls above 500 ms. The full package suite and focused Film Workflow document/rendering tests passed after these changes. A fresh Swift-only consumer at `/tmp/rxremotion-parallel-swift-only-consumer` also built the internal C target and passed the standalone compile/preview/PNG/movie check with PATH restricted to system tools. These are automated responsiveness checks, not a manual test of the user's app window.

Reproduce a worker measurement with `RX_REMOTION_BENCHMARK=1 RX_REMOTION_BENCHMARK_ALPHA=1 RX_REMOTION_BENCHMARK_FRAMES=120 RX_REMOTION_BENCHMARK_CONCURRENCY=2 swift test -c release --filter BenchmarkTests`. Run workers 1, 2 and 4 sequentially. The initial Debug before/after measurements are in `/tmp/rxremotion-parallel-before-debug.log` and `/tmp/rxremotion-parallel-after-debug.log`; Release measurements are in `/tmp/rxremotion-parallel-release-{1,2,4}.log`.

## Preview capture resolution (2026-09-11)

The bundled 1920×1080 typography/SVG benchmark, 150 frames, ProRes 4444 alpha,
Debug build and automatic two workers took 5.356 s at full capture resolution and
1.897 s at `captureScale: 0.5` (960×540): 2.82× render throughput. Cold compilation
was 0.358 s and 0.354 s respectively. These are local fixture measurements, not a
guarantee for every composition or total viewer preparation time.

Reproduce from the package directory with `RX_REMOTION_BENCHMARK=1
RX_REMOTION_BENCHMARK_ALPHA=1 RX_REMOTION_BENCHMARK_FRAMES=150 swift test
--no-parallel --filter BenchmarkTests`, then repeat with
`RX_REMOTION_BENCHMARK_CAPTURE_SCALE=0.5`. Run the measurements sequentially.
The native integration suite verifies scaled still/movie layout, alpha, all frame
timestamps and audio presence, alongside the existing full-resolution export,
stateful canvas and audio comparisons.

## Open release gates

1. Supply an existing local Mapbox project with an authorized token and compare real map frames (including required styles/tiles) against development references. Only the missing-token error path has been verified locally so far.
2. Unlock the Mac for manual visual checks of the standalone example, transparent layered timeline preview, play/pause/scrub synchronization, source reload, multiple visible clip instances, and settings changes. The computer-use tool reported a locked Mac; automated hidden-window tests and app workflow tests continued successfully.
3. Expand reference comparisons to production media, maps and particle projects, including background-window and 4K movie cases. Confirm provider attribution and real-provider OSM export permissions/configuration.
4. Complete the remaining performance comparisons before making claims about overall preview latency, memory or export speed. The packaged runtime is substantially smaller; that alone does not establish a universal rendering-speed improvement.
5. Reconcile the app's dependency lockfile before committing. During final verification, concurrent workspace activity repeatedly removed `film-workflow.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` immediately after restoration. Dependency resolution succeeded with the original eight remote version pins; their unchanged file is also preserved at `/tmp/rxremotion-original-Package.resolved`. No user Xcode process was stopped to force a restoration.

Known capture/codec/framework boundaries are in [Compatibility.md](Compatibility.md). Unsupported accelerated effects should remain explicit errors rather than incomplete successful exports.
