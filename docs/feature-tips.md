# Feature tips

TipKit guides users through 46 additional features, with stable IDs and a
maximum of one display per tip. The existing composer tip is also connected
to the chat screen, with updated guidance for `@` mentions and `/` commands.

| Area | Guidance |
| --- | --- |
| Simple mode | Template gallery, engine, uploads, save location, template selection, plan review, live activity, clip navigation, refinement, build notes, full editor |
| Chat | Footage mentions, commands, target, threads, new conversation, pinning, engine/model, thinking level |
| Marketplace | Customer browsing, categories, previews, sign-in, buying, installing, managing downloads, adding to a film, using templates |
| Inspectors | Tabs, image/video/narration generation, video job recovery, Remotion source and rendering, sequence rendering, caption translation and style, effect order, transition duration |
| Editor | New footage, media import and storage, installed marketplace library, filtering, effects browser |

## Behavior

- The app configures TipKit once and keeps normal dismissal history in its
  application datastore. No reset runs during normal launch.
- `FilmFeatureTip` owns app tips; `FilmTemplateTip` owns tips on controls inside
  `FilmTemplateUI`. Keep the raw case names and ID prefixes stable when editing
  copy so users do not see the same guidance again.
- Tips are attached to their controls. Relevant eligibility checks hide them
  during generation, while related sheets are open, or when an action is
  unavailable. Generation buttons dismiss their tip when activated.
- Marketplace tips cover the customer catalog and item details. Authoring and
  administrative controls have no new tips.
- Purchase and installation tips are invalidated on success, so a failed
  request does not count as completing the action.
- The SDK chat composer is unchanged. App-owned inline guidance and accessory
  controls provide its tips.

## Reviewing tips

Add `-previewTips` to a **Debug** launch to use a fresh temporary TipKit
datastore. This does not reset the normal tip history. It also allows tips
when `-uiTesting` is present; ordinary UI-test launches still hide all tips.
The option is ignored by Release builds.

Review these representative interactions:

1. New Film → template gallery → engine → upload files → save location.
2. During a Simple mode build, open and close Agent Activity; after completion,
   review notes, type a refinement, and open the editor.
3. Open Agent; inspect the composer guidance, target, engine, thinking, and
   thread controls. No message needs to be sent to review these tips.
4. Browse Marketplace while signed out and confirm that customer tips appear
   without exposing authoring controls. Check purchase/install/Add to Film
   eligibility using the corresponding account and item states.
5. Select footage and timeline clips; check the inspector tabs, enabled
   generation actions, effects, captions, and render controls. Close a tip and
   revisit its control to check that the tip stays dismissed for that history.

The Debug app build was validated. Visual review remains unverified because
computer-use access to the isolated review app was not approved.
