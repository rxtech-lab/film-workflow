# RxPet

A standalone SwiftUI camera companion with image-generated sprite animations and a nonactivating macOS overlay.

```swift
import RxPet
PetView(character: .cameraBuddy)
    .mood(.focused)
    .status(.replaying)
    .motion(.automatic)
    .message("Recording Safari — Checkout")
    .size(72)
```

Pass a `PetState` to drive the view from observable state. `PetCharacter` accepts a custom atlas, grid and frame rate. The built-in camera has six frames for each of eight motions: idle, working, waiting, resting, waving, walking, celebration and failure. Reduce Motion displays a still frame; hidden views stop scheduling frames.

For desktop overlays, call `PetOverlayPresenter.prepare`, register its `windowID` in your capture exclusions, then `reveal`. The package does not own permissions, recording, documents, or agent state. Bounds use AppKit screen coordinates.

Artwork was generated with the built-in image-generation tool from an original camera-mascot brief: a periwinkle and cream compact camera, orange shutter, expressive cyan lens eye, little arms and feet, crisp pixel outlines and transparent background.

## SwiftUI previews

Open `PetPreviews.swift` in Xcode’s canvas. It includes interactive pose/mood/status
controls, every animated movement, all six moods, all recording states, a grid
of all 48 still frames, and Reduce Motion with short and long messages.

Use `PetPreviewGallery()` inside another app’s preview, or select a specific pose:

```swift
#Preview("Walking, frame three") {
    PetView().mood(.curious).motion(.walking).animationFrame(2).size(96)
}
```

`animationFrame(nil)` resumes animation. Explicit frames and Reduce Motion stop
the animation timer. Sprite frames and face anchors are described in the bundled
`camera-animation.json`; expression artwork is separate from body animation.

Animation uses the manifest's per-frame timing: movement loops take roughly
2–3 seconds, and idle blinks include a longer rest. Use `.animationSpeed(0.5)`
for half speed; the interactive gallery includes a speed slider. Animated QA
previews use the same timing as the SwiftUI view.
