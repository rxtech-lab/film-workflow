# RxRemotion

A macOS 26+, Swift 6.2 package for editable Remotion React/TypeScript compositions. It compiles browser code with bundled esbuild-wasm in a Web Worker, displays it in system WebKit, and captures/encodes through Swift and AVFoundation. Consumers build with Swift alone. No Node, Bun, Chromium, Studio, npm installation, or renderer subprocess is used by the package.

## Use from Swift

Add `.package(path: "Packages/RxRemotion")` and the `RxRemotion` / `RxRemotionUI` products to your package or Xcode project.

```swift
import RxRemotion
import RxRemotionUI

// These operations run on the main actor because they own WebKit views.
let engine = RemotionEngine()
try RemotionEngine.scaffold(at: projectURL) // Only copies missing files.
let project = try await engine.prepare(projectURL: projectURL)
let compositions = try await engine.compositions(in: project)
let session = try await engine.makePreviewSession(project: project, compositionID: "Main")
// In a SwiftUI view: RemotionPreview(session: session)
try await session.seek(to: 30)
try await session.play()
try await engine.renderStill(project: project, frame: 30, to: pngURL)
try await engine.renderMovie(project: project, to: movieURL,
    settings: .init(codec: .h264)) { progress in
    print(progress.stage, progress.fraction ?? 0)
}
// For transparent timeline sources, use .proRes4444 and a .mov destination.
session.dispose()
engine.closeAll()
```

Pass composition IDs, JSON `inputProps`, and optional width/height/fps overrides to the operations. Preview sessions share a prepared project's compiled resources while owning their WebView and transport state. Sessions expose frame, playing state, buffering, errors, seek, play/pause, rate, volume, mute, events, and explicit disposal. Keep the engine and sessions alive for their intended lifetime; dispose views and close projects when a document closes. A scoped `previewURL()` is also available for a native host with its own playback bridge.

Cancel the enclosing Swift task to stop capture/export. Movies and stills write only completed output; incomplete work is removed, and an existing destination is preserved on failure. Source/assets are copied into an immutable export snapshot. An edit during snapshot creation causes an explicit retry error. Existing project files are never overwritten by scaffolding.

## Parallel export and responsiveness

Movie exports use two WebView workers automatically on Macs with at least four logical processors and 8 GiB of memory, up to 4K; smaller devices, larger frames, and single-frame movies use one. Choose `RemotionRenderSettings(concurrency: 1)` for serial rendering or `concurrency: 2...4` explicitly. Film Workflow exposes this under **Settings → Remotion → Frames at a time**. Settings affect the next movie or temporary preview render.

Each worker advances its own composition through intervening frames, preserving frame-driven state. Only assigned frames are captured. A bounded queue delivers frames in order to one encoder; there is at most one pending frame per worker plus three encoder pixel buffers. More workers increase WebKit memory and repeat some animation work, so they do not guarantee a speedup for every project.

Snapshot acquisition stays on the main actor as WebKit requires. Pixel scaling, alpha reconstruction, PNG encoding, native movie encoding, audio mixing, project copying, hashing and compilation-cache I/O run off the UI thread. A small internal C target accelerates the alpha operation in Debug as well as Release; it builds automatically with the Swift package and introduces no external runtime. The native engine version is part of cache fingerprints.

For disposable preview media, pass `RemotionRenderSettings(codec: .proRes4444, captureScale: 0.5)` to capture half the width and height. The logical WebView viewport, `useVideoConfig()`, frame count, timing and audio stay unchanged; only the captured and encoded pixels shrink. The scale must be greater than zero and at most one. Nil preserves full-resolution export. Film Workflow caps cached transition/effect previews at 960 pixels on their longest edge.

See [Validation.md](Validation.md) for measured worker throughput and UI-thread responsiveness.

## Standalone example

```sh
cd Packages/RxRemotion
swift run RxRemotionExample
# Or: swift run RxRemotionExample /absolute/path/to/project
swift run RxRemotionExample --check  # Automated compile, preview, PNG and movie smoke check
```

The example creates a temporary sample if no folder is supplied. It does not import Film Workflow, SwiftData, or RxVideoEditor. Its two library targets have no external Swift package dependencies.

## Authoring

Projects retain `src/index.ts`, `registerRoot`, and the `Main` convention. TS, TSX, JS, JSX, MJS, CSS, JSON, local asset imports and relative browser modules are supported. TypeScript is transformed, not type-checked. Other frameworks must supply browser-ready JavaScript/custom elements that can be mounted by a React component; framework compilers, SSR, Node APIs, dynamic npm installation, and Node-based Remotion config hooks are unavailable.

### Three.js

`three`, `@react-three/fiber`, `@react-three/drei`, and `@remotion/three` are bundled and can be imported directly without installing packages. Use [ThreeCanvas](https://www.remotion.dev/docs/three-canvas) to connect the 3D scene to Remotion's frame state:

```tsx
import {ThreeCanvas} from '@remotion/three';
import {Box} from '@react-three/drei';
import {useCurrentFrame, useVideoConfig} from 'remotion';

export function MyComposition() {
  const frame = useCurrentFrame();
  const {width, height, fps} = useVideoConfig();
  return <ThreeCanvas width={width} height={height} camera={{position: [0, 0, 5]}}>
    <ambientLight intensity={0.8}/>
    <directionalLight position={[3, 4, 5]} intensity={2}/>
    <Box rotation={[0.3, frame / fps, 0]}>
      <meshStandardMaterial color="#2676e8"/>
    </Box>
  </ThreeCanvas>;
}
```

Use `useCurrentFrame()` for animation and `layout="none"` for sequences inside the canvas. Custom model/texture loading must hold `delayRender` until ready; prefer local `staticFile()` assets and CORS-enabled remote textures. WebGL canvas capture preserves transparency. WebGPU, worker-owned canvases and CSS perspective effects are outside the export contract. Drei helpers that animate independently must be driven by frame state. Only the four package entrypoints above are exposed: `three/addons/*`, `three/examples/jsm/*`, and other unlisted subpaths are not bundled.

### Maps

```tsx
import {MapKitMap, OpenStreetMap} from '@rxlab/remotion-maps';

<MapKitMap center={{latitude: 22.28, longitude: 114.16}}
  zoom={12} width={1280} height={720} mapStyle="standard"
  markers={[{coordinate: {latitude: 22.28, longitude: 114.16}, label: 'Hong Kong'}]}
  routes={[{coordinates: [{latitude: 22.28, longitude: 114.16},
                         {latitude: 22.30, longitude: 114.18}], color: '#2676e8', width: 4}]}/>
```

Both components accept center, zoom, width, height, markers, routes, CSS `style` and `className`. MapKit also accepts standard/muted/satellite/hybrid map styles and an `onSnapshot` callback with marker/route pixel projections. Swift callers can use `engine.snapshotMapKit(RemotionMapRequest(...))` to obtain PNG data and projected points. Do not crop or cover the map's attribution. The overlay renderer preserves the original attribution strip.

OpenStreetMap uses bundled Leaflet 1.9.4. Configure an HTTPS `{z}/{x}/{y}` provider, attribution, zoom bounds and native-only request headers:

```swift
let engine = RemotionEngine(configuration: .init(openStreetMap: .init(
    tileURL: "https://your-provider.example/{z}/{x}/{y}.png",
    attribution: "Your provider · © OpenStreetMap contributors",
    allowsExport: true,
    headers: ["Authorization": "Bearer your-provider-token"]
)))
```

`allowsExport` represents your provider agreement, not a permission granted by this package. There is no default tile provider. Public `tile.openstreetmap.org` is rejected for automated rendering, as required by the [OSM tile policy](https://operations.osmfoundation.org/policies/tiles/). Film Workflow stores this configuration in Keychain under **Settings → Remotion**. Mapbox retains its own access-token requirements.

## Runtime and compatibility

Read [Compatibility.md](Compatibility.md) and [Validation.md](Validation.md) before adopting the renderer. Prebuilt browser dependencies are pinned in `Browser/package-lock.json`; optional library chunks load only when imported. The host and projects share one React/Remotion instance. The [esbuild browser API](https://esbuild.github.io/api/#browser) handles compilation without a Node runtime. A package-owned loopback server scopes projects with random URLs, rejects root escapes, and streams media byte ranges.

Compilation is cached by source/assets fingerprint and runtime manifest, with a bounded relocatable disk cache. Source text is content-hashed; large binary assets use path/size/modification time. Native polling watches both source and asset changes, including modules outside `src/`. Each export explicitly advances frames and awaits React updates, delayRender, fonts, images, media and maps. It never advances frames according to elapsed export time.

## Maintainers

Only rebuilding the checked-in browser resources requires npm:

```sh
cd Browser
npm ci --ignore-scripts
npm run build
```

Commit the generated `Sources/RxRemotion/Resources/Web` files along with changes to the browser sources and lockfile. Consumers and CI package builds use those resources directly. Remotion internals are isolated in `Browser/host.tsx` and the vendor adapter in `Browser/build.mjs`; revisit these adapters when changing the pinned version.

Third-party licenses, including Remotion and Mapbox's license terms, are bundled in `Resources/Web/THIRD-PARTY-NOTICES.txt`. Bundling dependencies does not change their licensing requirements.
