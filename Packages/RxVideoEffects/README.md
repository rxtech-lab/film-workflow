# RxVideoEffects

A macOS effects catalog with no dependency on application models or
`VideoEditorCore`. The editor depends on this package.

| Product | Responsibility |
| --- | --- |
| `VideoEffectsCore` | Definition protocols, parameter descriptors, instances, Core Image rendering, bundled preview samples |
| `VideoEffectsUI` | Searchable browser, animated thumbnails, drag payloads, parameter controls |

`EffectProtocol` and `TransitionProtocol` pair stable identifiers, names,
descriptions and parameter descriptors with Core Image rendering. Register new
definitions in `ModifierCatalog.standard`; the browser and inspector resolve
their controls from the same descriptors. `TransitionProtocol.renderEdge` has
a default transparent-input implementation; Fade through Color overrides it.
Transition inputs must share an extent and use premultiplied alpha.

`EffectInstance` stores an independent ID, definition ID, parameters and enabled
state. `ModifierCatalog.apply` evaluates enabled effects in array order. Unknown
definitions pass through during preview, and their persisted values remain
intact. The host must validate unavailable definitions before export.

The bundled landscape samples are original procedural artwork. Thumbnail
previews use the actual catalog renderers. Hover animates a transition or blends
between the original sample and the applied effect. Rendering samples is cached
at the source-image level; previews use a shared Core Image context.

The UI drag payload uses `com.rxlab.video-modifier`. The host supplies timeline
drop targets and owns transition attachments, duration limits, selection,
undo and persistence. Sliders commit on release, text fields commit on submit
or focus loss, and menus commit once per selection.

Run `swift test --package-path Packages/RxVideoEffects --no-parallel` from the
repository root. The suite covers alpha, transition endpoints, midpoint color,
wipe direction, effect ordering/bypass, bundled samples and unknown instances.
