# Compatibility

RxRemotion is a browser-compatible Remotion host, not a Swift implementation of arbitrary JavaScript frameworks. It uses the pinned upstream Remotion timing, sequences, springs, interpolation, registration and Player. The engine accepts browser code; it cannot execute server-side frameworks or install arbitrary packages.

| Surface | Behavior |
|---|---|
| React / ReactDOM | 19.2.0, one shared module instance |
| Remotion / Player | 4.0.459; entrypoint calls registerRoot; multiple compositions, input props and calculateMetadata |
| Three.js / React Three Fiber / Drei | 0.185.0 / 9.7.0 / 10.7.8; shared Three.js and Fiber modules, WebGL rendering and transparent capture |
| @remotion/three | 4.0.459; ThreeCanvas with explicit width/height, frame-driven transforms and Remotion context inside the scene |
| Mapbox / react-map-gl | 3.23.1 / 8.1.1; WebGL readback adapter, valid provider token required |
| tsParticles | engine/slim 3.9.1, React 3.0.0; seeded random and frame-driven animation callbacks |
| Maps | Native MKMapSnapshotter; Leaflet 1.9.4 with configured export-permitted OSM tiles |
| Modules | Relative project-local browser modules and bundled catalog; unknown imports report source locations |
| Assets | CSS, JSON, image/font imports, staticFile assets and native media byte ranges |
| Video | Remotion Video/Html5Video use the native OffthreadVideo adapter during export; AVFoundation codecs only |
| Audio | Native mix of collected Remotion asset timing, sequence offsets, trims, loops, positive speed, mute, gain envelopes and video audio |
| Still / movie | PNG; H.264 + AAC MP4; ProRes 4444 + PCM MOV with transparency |
| Frame capture | DOM/SVG snapshots; canvas/WebGL converted into layout-preserving PNGs; native video decoded into images |

The 3D catalog exposes `three`, `@react-three/fiber`, `@react-three/drei`, and `@remotion/three` directly. Additional subpaths such as `three/addons/*` and `three/examples/jsm/*` are not exposed. Use `ThreeCanvas`, animate from `useCurrentFrame()`, and give nested sequences `layout="none"`. Independently animated Drei helpers require frame-driven configuration; custom model and texture loaders must hold `delayRender` while loading. See the [authoring example](README.md#threejs).

Capture is deliberately narrower than an interactive browser. WebKit has [documented snapshot limitations](https://bugs.webkit.org/show_bug.cgi?id=221662). Backdrop filters, 3D DOM transforms/perspective, and blend modes across transparent surfaces produce explicit errors. Leaflet's tile blending is allowed only inside its isolated opaque map surface. Cross-origin canvas textures require CORS. WebGPU, remote iframe content, arbitrary worker-driven canvas animation, and independently animated media outside Remotion's frame model are not supported. Keep animations driven by `useCurrentFrame`; Date/performance and requestAnimationFrame are virtualized only in the export page. CSS animations are paused and positioned at the requested frame. Arbitrary setInterval/setTimeout-driven application animation is not deterministic and must be rewritten to use frame state.

`Audio` pitch shifting through `toneFrequency` is rejected. The exported mix uses frame-sampled volume ramps; audio controlled entirely by Web Audio/third-party JS is outside this release. HTML video sources require seekable AVFoundation-readable media. DRM, unavailable codecs, cross-origin image/canvas failures, and resource timeouts report errors. Ordinary CSS background images are awaited; custom resource loaders should hold `delayRender` until ready. Runtime-specific webpack/remotion.config hooks and process environment variables are not evaluated.

Transparent live layers use macOS WebKit’s background-drawing KVC flag, matching the existing Film Workflow preview; export alpha is reconstructed through public snapshots. Recheck this flag when updating the supported macOS versions.

The native preview bridge supports positive playback rates up to 10 and volume 0...1. Film Workflow retains its existing native rendered-preview path for clip speeds, gains or media that the live Player cannot play. Those temporary alpha sources are also rendered through RxRemotion; there is no legacy-process or screen-recording fallback.

Fonts and browser rendering can vary across OS/browser versions. Use bundled fonts and compare representative frames for a project before relying on pixel identity. Map exports also depend on provider availability and licensing. Unsupported effects must be handled explicitly; a successful simple fixture does not establish compatibility with every Mapbox style, WebGL extension, or arbitrary npm library.
