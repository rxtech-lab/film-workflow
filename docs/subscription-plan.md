# Accounts + Credits Subscription — Design Plan

## Context

RxFilm Studio is BYOK today: `film-workflow/config/AppConfig.swift` holds 12 fields (Google AI key, Azure Speech key/endpoint, OpenAI-compatible endpoint/key, plus model ids) in the macOS/iOS Keychain under service `com.rxlab.film-workflow`, and every AI client takes `apiKey:`/`endpoint:` as a parameter. That blocks anyone who doesn't already have provider accounts, and it means we capture no revenue.

We want a second credential mode: the user signs in to an RxLab account, tops up credits, and all AI work runs on our provider keys, metered and billed. BYOK stays as a first-class option — the choice lives in Settings.

`website/` (Next.js 16 App Router, Tailwind 4, bun) is currently a static marketing page. It becomes the account backend: auth, Turso DB, Stripe, the metered AI API, and the dashboard.

`RxAuthSwift` + `RxAuthSwiftUI` are **already linked** into `film-workflow.xcodeproj` (branch `main`, rev `af111a0`) but nothing imports them yet — the dependency step is done.

### Decisions already locked in

1. **Proxy everything through the backend.** Desktop sends a Bearer access token to `website/` API routes; the backend calls AI Gateway / Google / Azure, measures real cost, deducts credits. Provider keys never leave the server — the only way billing can be accurate or enforceable.
2. **Extend the existing `website/` app** rather than standing up a second Next.js project. One Vercel deploy, one domain; the marketing page at `app/page.tsx` is untouched.
3. **Desktop sign-in uses `RxAuthSwift`'s `OAuthManager.authenticate()`** (authorization code + PKCE against `auth.rxlab.app`; on macOS the package opens an in-app `WKWebView`, on iOS `ASWebAuthenticationSession`). Payment/top-up opens the *real system browser* to the website.
4. **Backend holds our own Google AI + Azure Speech keys** so Lyria music and Azure TTS work under subscription, priced from a hand-maintained per-unit table (neither is on AI Gateway).

### Architecture

```
┌──────────────────────┐        Bearer access token        ┌───────────────────────────┐
│ RxFilm Studio (macOS)│ ────────────────────────────────► │ website/ (Next.js, Vercel)│
│  BYOK  ──────────────┼──► providers directly             │  NextAuth cookie + Bearer │
│  Subscription ───────┼──► /api/v1/ai/*                   │  Turso + Drizzle          │
└──────────────────────┘                                   │  billing (points ledger)  │
        │ system browser for top-up                        │  AI Gateway/Google/Azure  │
        └─────────────────────────────────────────────────►│  Stripe                   │
                                                           └───────────────────────────┘
```

**The load-bearing idea:** *provider* and *credential mode* are orthogonal axes.
- **Provider** — the existing `ImageProvider`, `NarrativeProvider`, `CaptionProvider`, `AgentBackend` enums. Unchanged, still user-visible pickers.
- **Credential mode** — new `byok | subscription`. Decides *transport*, not *provider*.

Because of that, the seam lands inside the six `@MainActor enum` service façades in `film-workflow/clients/services/` plus `CaptionTranscriberFactory` — so ~15 of the ~20 existing `AppConfig.loadFromKeychain()` call sites need **zero edits**.

---

# Part 1 — Backend (`website/`)

## 1.1 Dependencies

Copy versions from `/Users/qiweili/Desktop/yc-acceptance-web/package.json` (proven together with Next 16 / React 19):

```jsonc
"dependencies": {
  "@ai-sdk/gateway": "3.0.153", "ai": "6.0.230",
  "@libsql/client": "0.17.4", "drizzle-orm": "0.45.2",
  "@rxtech-lab/authjs-rxlab": "1.6.0", "next-auth": "5.0.0-beta.31",
  "stripe": "^22.3.2", "zod": "4.4.3", "server-only": "^0.0.1",
  "lucide-react": "0.468.0", "@aws-sdk/client-s3": "^3", "@aws-sdk/s3-request-presigner": "^3"
},
"devDependencies": { "drizzle-kit": "0.31.10", "vitest": "4.1.10" },
"scripts": { "typecheck": "tsc --noEmit", "test": "vitest run",
             "db:generate": "drizzle-kit generate", "db:migrate": "drizzle-kit migrate" }
```

`website/tsconfig.json` already maps `@/*` → `./*`, so `@/lib/...` imports copied from yc-acceptance-web resolve unchanged.

## 1.2 Layout

```
website/
  drizzle.config.ts                # copy of yc's verbatim (dialect: "turso")
  drizzle/                         # generated migrations
  lib/
    db/{index,schema}.ts
    auth.ts                        # createRxLabAuth + getCurrentUser + requirePageUser
    auth/bearer.ts                 # NEW — desktop Bearer verification
    billing/{config,errors,repository,pricing,usage,stripe,history}.ts
    billing/unit-pricing.ts        # NEW — hand-maintained non-gateway price table
    ai/{gateway,catalog,image,speech,music,transcribe,meter}.ts
  app/
    api/auth/[...nextauth]/route.ts
    api/billing/{route.ts,checkout/route.ts,usage/route.ts}
    api/webhooks/stripe/route.ts
    api/v1/{me,models,uploads}/route.ts
    api/v1/ai/{chat,images,speech,voices,music,transcriptions}/route.ts
    api/v1/jobs/[jobId]/route.ts
    api/cron/{reconcile-usage,reap-reservations}/route.ts
    login/page.tsx
    (account)/{layout,dashboard,credits,usage,invoices,models}/page.tsx
  components/{credit-packs,billing-pagination,account-shell,usage-table,model-catalog-table}.tsx
  tests/{billing,billing-pricing,unit-pricing}.test.ts
```

`app/page.tsx`, `app/hero-video.tsx`, `app/reel-stage.tsx`, `app/lib/{site,release}.ts` stay exactly as they are; `app/layout.tsx` gains a "Sign in" link.

## 1.3 Database (Turso + Drizzle)

**Copy verbatim** from `/Users/qiweili/Desktop/yc-acceptance-web/lib/db/schema.ts` lines 187–300: `AiUsageSnapshot`, `billingAccounts`, `creditReservations`, `pointsLedger`, `usageEvents`, `billingTopups`, `stripeWebhookEvents`. Then:

**`usageEvents` — three added columns** so non-gateway units are auditable and refundable:
```ts
capability: text("capability", { enum: ["chat","image","speech","music","transcription","translation"] }).notNull(),
unitKind:   text("unit_kind", { enum: ["tokens","images","characters","audio_seconds","audio_minutes"] }),
unitCount:  integer("unit_count"),
```
`feature` stays the human label ("Narrative — Azure TTS"); `capability` is the machine axis the dashboard groups by.

**`billingAccounts.costRemainderNanoUsd`** — keep the column so the copied repository code compiles, but it is always `0` under the ceil policy (§1.5).

**New tables:**
- `deviceSessions` — `id, userId, platform("macos"|"ios"), appVersion, deviceName, lastSeenAt, createdAt`. Lets a user see/revoke desktop installs and gives us a per-device rate-limit key.
- `aiJobs` — `id, userId, reservationId, capability, status("queued"|"running"|"succeeded"|"failed"|"cancelled"), requestJson, resultObjectKey, resultMeta, errorCode, errorMessage, progressPercent, createdAt, updatedAt`. For music and long transcriptions that outlive a Vercel function.

## 1.4 Auth

**`lib/auth.ts`** — copy verbatim from `/Users/qiweili/Desktop/yc-acceptance-web/lib/auth.ts`: the `rxLabConfigured` guard, `createRxLabAuth({ issuer, clientId, clientSecret, signInPage: "/login", trustHost: true })`, `AppUser {id,name,email,roles}`, `getCurrentUser()`, `requirePageUser()`, the `DEV_BYPASS_AUTH` non-production bypass.

**`lib/auth/bearer.ts`** — new; this is the piece yc-acceptance-web does not have (it is cookie-only):
```ts
export class UnauthorizedError extends Error {}
export async function verifyBearerToken(token: string): Promise<AppUser | null>;
export async function getRequestUser(request: Request): Promise<AppUser | null>;  // Bearer first, cookie second
export async function requireApiUser(request: Request): Promise<AppUser>;
export function unauthorizedResponse(): Response;
```
Verification hits `${AUTH_ISSUER}/api/oauth/userinfo` — the default `userInfoPath` in `RxAuthSwift/Sources/RxAuthSwift/RxAuthConfiguration.swift`, so the desktop token verifies with one upstream call. Cache verified identities in a module-level `Map` keyed by `sha256(token)` with a 60 s TTL (Fluid keeps the instance warm, collapsing the round-trip for the burst of calls one generation makes). Returns `401 { code: "unauthorized" }` + `WWW-Authenticate: Bearer`. Later hardening: local JWKS verification against `${AUTH_ISSUER}/.well-known/jwks.json`.

Register a **public client** `filmstudio-macos` in the rxlab-auth dashboard with redirect `filmstudio://callback` (no secret — PKCE), separate from the website's confidential client.

## 1.5 Billing

Copy `lib/billing/{config,repository,errors,pricing,usage,stripe,history}.ts` from yc-acceptance-web wholesale. Three deliberate changes:

### (a) Packs at 1.3×
1 point ≡ **$0.001 of provider cost** (unchanged from yc). The margin lives in the pack price only:
```ts
export const CREDIT_PACKS = [
  { id: "points_1000",  points:  1_000, amountCents:   130 },   // 1.30x
  { id: "points_5000",  points:  5_000, amountCents:   650 },
  { id: "points_15000", points: 15_000, amountCents: 1_950 },
  { id: "points_50000", points: 50_000, amountCents: 6_500 },
] as const;
```
This is exactly what yc does at 1.29× (`lib/billing/config.ts:20`). **Do not** multiply at settle time: the reservation-capacity check (`repository.ts:291`) and every displayed number would then mean "marked-up points", and a future margin change would silently reprice open reservations. Keeping the ledger a faithful record of provider cost is what makes refunds, disputes, and "why did this cost 43 credits" answerable.

### (b) Round up, not down
yc floors with a persistent per-account carry. The user wants ceil:
```ts
/** Ceil, never floor: sub-point provider cost is real cost, and a run of 100
 *  one-character TTS calls must not be free. remainderNanoUsd stays in the
 *  signature (always 0) so copied callers in settleProviderUsage() need no edits. */
export function pointsFromCost(costNanoUsd: number, _remainder = 0) {
  if (costNanoUsd <= 0) return { points: 0, remainderNanoUsd: 0 };
  return { points: Math.max(Math.ceil(costNanoUsd / NANO_USD_PER_POINT),
                            billingConfig.minChargePoints), remainderNanoUsd: 0 };
}
```
Consequences: (1) ceil makes `BILLING_RESERVATION_EXCEEDED` (`repository.ts:292`) marginally likelier, so `BILLING_RESERVATION_MARGIN_BPS` default rises 12_500 → 15_000; (2) a multi-step agent turn pays a 1-point minimum *per step*, which is intentional — document it on `/models`; (3) `proportionalPointReversal` (refunds) keeps `Math.floor` — charge up, refund down, conservative on both sides.

### (c) `lib/billing/unit-pricing.ts` — the non-gateway table
Gateway-priced calls (chat, narrative text, caption AI) keep using yc's `estimatedCostNanoUsd` / `gateway.getGenerationInfo` — authoritative and self-updating. Everything else needs a hand table:
```ts
export type UnitKind = "images" | "characters" | "audio_seconds" | "audio_minutes";
export type UnitPrice = {
  provider: "google" | "azure" | "openai";
  model: string;              // exact id, "foo-*" glob, or "*"
  unit: UnitKind;
  nanoUsdPerUnit: number;     // provider cost per single unit
  minimumUnits?: number;
  source: string;             // provenance, so the table is auditable
  reviewedAt: `${number}-${number}-${number}`;
};
export function unitPrice(provider, model, unit): UnitPrice | null;   // longest-glob match
export function unitCostNanoUsd({provider, model, unit, units}): number;
export function estimateReservationPoints({provider, model, unit, units, floorPoints}): number;
```
Seed rows (verify each against live provider pricing before shipping — these are starting estimates, not quotes): Azure Neural TTS per-1M-characters and a higher HD-voice row; Azure Fast Transcription per audio minute; Lyria `lyria-3-pro-preview` per audio second with a minimum; Gemini TTS approximated from audio-output tokens at ~4 chars/token; Imagen and `gpt-image-*` per image; `whisper-1` per audio minute.

**Fail closed:** a model absent from both the gateway catalog *and* `UNIT_PRICES` must return HTTP 400 `PRICE_NOT_FOUND`, never settle at `costNanoUsd: 0`. `tests/unit-pricing.test.ts` asserts every model in `lib/ai/catalog.ts` has a price and that no `reviewedAt` is older than 180 days.

### (d) `lib/billing/usage.ts` additions
Copy yc's gateway path (`gatewayProviderOptions`, `normalizeLanguageUsage`, `recordAiUsage` with `getGenerationInfo` → `estimatedCostNanoUsd` fallback). **Drop** the `workflow`/`usageReconciliationWorkflow` branch (`usage.ts:125-152`) to avoid the extra dependency — use `createPendingUsage` + `markUsageNeedsReview` and drain from `/api/cron/reconcile-usage`. Add:
```ts
export async function recordUnitUsage(input: {
  context: MeteringContext; provider; model; capability;
  unit: UnitKind; units: number; externalId?: string | null; eventId?: string;
}): Promise<typeof usageEvents.$inferSelect | null>;
```
It computes `unitCostNanoUsd(...)` and calls the **same** `settleProviderUsage` the gateway path uses, with `idempotencyKey = \`unit:${operationId}:${eventId ?? capability}\``.

### (e) `lib/ai/meter.ts` — the wrapper every AI route uses
```ts
export async function withMeteredOperation<T>(input: {
  user: AppUser; feature: string; capability: Capability;
  operationKey: string; reservePoints: number; scopeId?: string | null;
  run: (ctx: MeteringContext) => Promise<T>;
}): Promise<{ value: T; reservationId: string | null }>;
```
Body is the shape of `yc/app/api/chat/route.ts:29-46` + `:150`: `reserveCredits` → run → `closeReservation({success:true})`, or `{success:false}` + rethrow on error. Routes catch `InsufficientCreditsError` → `insufficientCreditsResponse(cause)` (402).

Also add `topUpReservation(reservationId, extraPoints)` — grows an open reservation mid-run rather than throwing `BILLING_RESERVATION_EXCEEDED` halfway through a long agent turn.

## 1.6 API surface

All under `/api/v1/`, `Cache-Control: private, no-store`, authenticated via `requireApiUser(request)`.

| Route | Notes |
|---|---|
| `GET /api/v1/me` | `{user, billing:{enabled,balancePoints,reservedPoints,availablePoints,pointsPerUsd}, urls:{credits,usage}}`. `X-Client-Platform`/`X-Client-Version` headers upsert a `deviceSessions` row. Desktop polls on launch, after any 402, and on return from the browser. |
| `GET /api/v1/models?capability=` | Served from `lib/ai/catalog.ts` — the **live gateway model list** (`lib/ai/gateway-models.ts` reads the gateway's OpenAI-compatible `/v1/models`, 15-min cache, stale-on-error) classified by the same `type`/`tags` rules the desktop's `OpenAIModelsClient` uses, **plus** the direct-provider models (Imagen, Azure/Gemini TTS, Lyria, Whisper, Azure fast transcription) that are not gateway-routed. Fails closed: a model the gateway does not price per image, or whose kind no route can execute (speech/transcription/video/embedding), is not offered and is rejected by `requireCatalogModel`. Each entry carries `id, provider, displayName, capability, estimate{unit, pointsPerUnit}` where `pointsPerUnit = ceil(nanoUsdPerUnit / NANO_USD_PER_POINT)` — the desktop renders "≈ 52 credits/image" without knowing anything about pricing; chat carries no estimate because it settles from reported tokens. `s-maxage=900`. |
| `POST /api/v1/ai/chat` | Deliberately **OpenAI-chat-shaped** so `OpenAIClient.chat`/`chatWithTools` need only an endpoint+auth swap. Meters via `recordAiUsage` in `onStepFinish`. Emits a final `{"type":"rxlab.usage","chargedPoints","availablePoints"}` frame when streaming. `maxDuration = 300`. |
| `POST /api/v1/ai/images` | `{model, prompt, n, aspect_ratio, resolution, size, quality, format, …}` → `{images:[{b64_json, mime_type}], usage}`. Settle on **images actually returned**, so a partial failure charges for what was produced. |
| `POST /api/v1/ai/speech` | `{provider:"azure"|"gemini", ssml|transcript, speakers, format}` → `{audio_base64, mime_type, characters, usage}`. Billable characters computed **server-side** (SSML stripped of tags), never trusted from the client. |
| `GET /api/v1/ai/voices?provider=` | Proxies Azure `/cognitiveservices/voices/list` with the server key, returning the same JSON `AzureVoiceStore` already decodes. **Not billed.** `s-maxage=86400`. |
| `POST /api/v1/ai/music` | → **202** `{job_id, status, poll_url}`. Async by default — Lyria routinely exceeds 300 s. Billed on `audio_seconds` **measured from returned audio**. |
| `POST /api/v1/ai/transcriptions` | Two shapes: multipart (< 4 MB) or JSON `{object_key}` from `/api/v1/uploads`. The server verifies the user-scoped key and reads it through the S3 client. Returns the exact JSON the existing decoders consume. Billed `ceil(durationMs/60000)` measured server-side. |
| `POST /api/v1/uploads` | Authenticated presigned S3 PUT flow so large audio never passes through a function body. Keys are scoped under `transcriptions/{userId}/` with a 300 MB cap. |
| `GET /api/v1/jobs/[jobId]` | `{id, status, progress_percent, result_url, error, usage}`. `result_url` uses `S3_PUBLIC_URL` when configured, otherwise a short-lived S3 URL. |
| `GET /api/billing`, `POST /api/billing/checkout`, `POST /api/webhooks/stripe` | Copy yc's routes verbatim; swap `getCurrentUser` → `getRequestUser` so desktop can call them too. |
| `GET /api/billing/usage?page=` | Wraps `getPointHistory`, adds `capability` grouping. |

**Important: the desktop keeps its own batching.** `AzureTTSClient.generate` already splits into ≤10-minute SSML batches and stitches with `AzureAudioStitcher`. In subscription mode each *batch* is one `/api/v1/ai/speech` call — no single request approaches the duration limit, and `NarrativeGenerationProgress.synthesizing(completed:total:inFlight:)` keeps working unchanged.

## 1.7 Stripe

Copy `/Users/qiweili/Desktop/yc-acceptance-web/lib/billing/stripe.ts` verbatim — `customerForUser`, `createTopupCheckout` (inline `price_data`, no pre-created Products), `processStripeWebhook` with the full event switch (`checkout.session.completed`, `.async_payment_succeeded`, `.async_payment_failed`, `invoice.paid`, `charge.refunded`, `charge.dispute.created`, `charge.dispute.closed`) wrapped in the `beginStripeEvent`/`finishStripeEvent` idempotency envelope. Two edits:
1. `appInfo: { name: "RxFilm Studio" }`.
2. `createTopupCheckout` takes `origin?: "web" | "desktop"`; when desktop, `success_url` gains `&app=1` and `/credits` renders a **"Return to RxFilm Studio"** `<a href="filmstudio://credits/refresh">`.

**Prepaid packs only in v1** (`mode: "payment"`). A recurring plan is a later `stripe.subscriptions` + `invoice.paid` → `fulfillTopup` grant — the ledger already models it as a `top_up` kind, so no schema change.

## 1.8 Dashboard

| Route | Contents |
|---|---|
| `app/login/page.tsx` | Copy yc's — server action `signIn("rxlab", { redirectTo: "/dashboard" })`. |
| `app/(account)/layout.tsx` | Sidebar with live balance, modelled on `yc/app/(workspace)/layout.tsx`. |
| `.../dashboard` | Balance card, recent ledger, "Download the app", signed-in devices. |
| `.../credits` | Near-verbatim copy of `yc/app/(workspace)/credits/page.tsx` — balance card, `checkout=success|cancelled` banners, `<CreditPacks>`, ledger, top-ups with Stripe invoice/PDF links. Plus the `?app=1` deep-link back button. |
| `.../usage` | `getPointHistory` + `<BillingPagination>`, with a grouped-by-`capability` summary strip. |
| `.../invoices` | Copy of yc's over `getInvoiceHistory`. |
| `.../models` | Public price list rendered from `lib/ai/catalog.ts` — the same source the desktop picker reads. |

`components/credit-packs.tsx` and `components/billing-pagination.tsx` copy verbatim (the former is already framework-agnostic: POST `/api/billing/checkout` → `window.location.assign(url)`).

## 1.9 Environment

```
TURSO_DATABASE_URL=  TURSO_AUTH_TOKEN=
AUTH_ISSUER=https://auth.rxlab.app   AUTH_CLIENT_ID=  AUTH_CLIENT_SECRET=  AUTH_SECRET=
DESKTOP_AUTH_CLIENT_ID=filmstudio-macos
BILLING_ENABLED=true  POINTS_PER_PROVIDER_USD=1000  INITIAL_PROMOTIONAL_POINTS=300
BILLING_RESERVATION_MARGIN_BPS=15000  BILLING_MIN_CHARGE_POINTS=1
AI_CHAT_RESERVATION_POINTS=40  AI_IMAGE_RESERVATION_POINTS=60  AI_SPEECH_RESERVATION_POINTS=30
AI_MUSIC_RESERVATION_POINTS=200  AI_TRANSCRIPTION_RESERVATION_POINTS=30
STRIPE_SECRET_KEY=  STRIPE_WEBHOOK_SECRET=  STRIPE_AUTOMATIC_TAX=false
AI_GATEWAY_API_KEY=  GOOGLE_GENERATIVE_AI_API_KEY=  AZURE_SPEECH_KEY=  AZURE_SPEECH_REGION=  OPENAI_API_KEY=
S3_ENDPOINT=  S3_REGION=auto  S3_BUCKET=  S3_ACCESS_KEY_ID=  S3_SECRET_ACCESS_KEY=  S3_PUBLIC_URL=  NEXT_PUBLIC_SITE_URL=  CRON_SECRET=  DEV_BYPASS_AUTH=false
```

---

# Part 2 — Desktop (`film-workflow/`)

## 2.1 `AppConfig` gains a mode

`film-workflow/config/AppConfig.swift`:
```swift
enum CredentialMode: String, Codable, CaseIterable, Sendable { case byok, subscription }

struct AppConfig: Codable {
    // …existing 12 fields, unchanged…
    /// Declared last with a default so the memberwise init used by
    /// AIProviderSettingsView.currentConfig() keeps compiling.
    var credentialMode: CredentialMode = .byok
    var subscriptionChatModel = ""
    var subscriptionImageModel = ""
    var subscriptionTranscriptionModel = ""
}
extension AppConfig { var usesSubscription: Bool { credentialMode == .subscription } }
```
Four more Keychain accounts wired into `loadFromKeychain()` / `saveToKeychain()` / `deleteFromKeychain()`, following the existing `loadString`/`saveString` helpers. Parallel subscription model fields (rather than reusing the BYOK ones) mean toggling modes never destroys the user's other configuration.

`ImageGenProject` (SwiftData) gains `subscriptionModel: String = ""` — lightweight migration, falls back to `AppConfig.subscriptionImageModel` when blank.

## 2.2 The ~20 `loadFromKeychain()` call sites

All keep calling `loadFromKeychain()`. Only groups B–D need edits:

- **A — façade-covered, ZERO edits.** `MusicTabView:353`, `NarrativeTabView:351`, `GeneratedNarrativeListView:185`, `ImageGenTabView:285`, `CaptionTabView:466`, `MCPGenerateHandlers:58`, `MCPCaptionHandlers:314`, `AgentSettingsView:17`.
- **B — model pickers** (ask the backend catalog when `usesSubscription`; one-line swap): `AIProviderSettingsView:312`, `CaptionSettingsView:614,627`, `ImageGenProjectParametersView:277,300`, `CaptionProjectParametersView:467`, `RemotionTools:161`.
- **C — voice list/preview**: `AzureVoiceStore:62`, `AzureVoicePreviewer:54`, `GeminiVoicePreviewer:45`.
- **D — LLM/agent**: `AgentController:182`, `CaptionSegmentListView:675,798`, `CaptionTranslateSheet:196`, `MCPCaptionHandlers:444`.

## 2.3 New Swift files

### Auth & config
| File | Type |
|---|---|
| `config/BackendConfig.swift` | `enum BackendConfig` — Info.plist-backed `apiBaseURL, webBaseURL, oidcIssuer, clientID, redirectURI, scopes, hasOAuthConfiguration, diagnostics`. Direct port of `linda-assistant/.../AssistantCore/Config/AppConfig.swift`, including the bundle walk that rejects unexpanded `$(...)` values. |
| `auth/AuthManager.swift` | `@Observable @MainActor final class AuthManager`, `static let shared`. Ports `linda-assistant/.../AssistantCore/Auth/AuthManager.swift`: wraps `OAuthManager(configuration:tokenStorage:)` + `KeychainTokenStorage(serviceName: "com.rxlab.film-workflow.auth")`. Exposes `authState, isAuthenticated, isLoading, error, accessToken, currentUser, checkExistingAuth(), signIn(), refreshAccessToken(), signOut()`. |
| `auth/AuthSessionBridge.swift` | `.onOpenURL` handler for `filmstudio://credits/refresh` → `CreditBalanceStore.shared.refresh()`. |

`RxAuthConfiguration` uses the package defaults (`/api/oauth/authorize`, `/api/oauth/token`, `/api/oauth/userinfo`), which lines up with the backend's userinfo verification automatically.

### Transport
| File | Type |
|---|---|
| `clients/backend/BackendError.swift` | `enum BackendError: LocalizedError { notSignedIn, insufficientCredits(available:required:creditsURL:), unauthorized, badRequest(String), server(Int,String?), priceUnavailable(String), jobFailed(String), decoding(Error) }` |
| `clients/backend/BackendClient.swift` | `actor BackendClient { static let shared }` with `get<T>`, `post<B,T>(idempotencyKey:)`, `upload<T>(fileURL:fields:)` (streams via `URLSession.upload(for:fromFile:)`, reusing `CaptionHTTP.writeMultipartBody`), `stream(_:body:) -> AsyncThrowingStream<BackendSSEEvent, Error>`, `awaitJob(_:onProgress:)`. **401** → `AuthManager.refreshAccessToken()` + retry once (the pattern at `linda-assistant/.../APIClient.swift:55-62`). **402** → decode and throw `.insufficientCredits`. Every response updates `CreditBalanceStore`. |
| `clients/backend/CreditBalanceStore.swift` | `@Observable @MainActor final class` — `availablePoints, reservedPoints, isSignedIn, refresh(), apply(available:), openTopUp()`. `openTopUp()` uses `NSWorkspace.shared.open` on macOS / `UIApplication.shared.open` on iOS to `webBaseURL/credits?app=1`. |
| `clients/backend/BackendModelCatalog.swift` | `actor` with the same 24 h UserDefaults cache shape as the existing `OpenAIModelsClient`/`GoogleModelsClient`. |
| `clients/backend/UsageHistoryStore.swift` | `@Observable @MainActor final class` — paginated `GET /api/billing/usage`, grouped by `capability`, for the account sheet. |

### Account UI (see §2.7)
| File | Type |
|---|---|
| `views/account/AccountControl.swift` | The shared signed-out-button / signed-in-menu control, parameterised by `Placement`. |
| `views/account/AccountSidebarFooter.swift` | `View.accountSidebarFooter()` — `.safeAreaInset(edge: .bottom)`, applied one line per tab view. |
| `views/account/AccountSheet.swift` | Balance, grouped usage, Add Credits, Sign Out. |

### Capability clients — mirrors of the BYOK clients, **same return types**
`BackendImageClient` → `ImageGenResult` · `BackendTTSClient` → `AzureTTSResponse` / `GeminiTTSResponse` (reusing `AzureSSMLBuilder.buildBatches` + `AzureAudioStitcher` locally; only the `synthesize(ssml:…)` call is replaced) · `BackendMusicClient` → `LyriaResponse` (async job + poll) · `BackendTranscriptionClient` conforming to the **existing** `CaptionTranscriberClient` protocol · `BackendChatClient` mirroring `OpenAIClient.chat`/`.chatWithTools` → `OpenAIAssistantResponse` · `BackendVoiceClient` → `[AzureVoice]`.

Returning the existing types is what keeps everything downstream of the call site (`FileStorage.saveImage`, decoders, SwiftData inserts) untouched.

### The routing abstraction — `clients/AIBackend.swift`
```swift
nonisolated enum AICapability: String, Sendable, CaseIterable { case chat, image, voice, caption, music }

@MainActor enum AIRoute: Sendable {
    case byok, subscription
    static func resolve(_ config: AppConfig, for capability: AICapability) throws -> AIRoute
}
enum AIRouteError: LocalizedError { case notSignedIn, missingBYOKConfig(AICapability) }
```
`resolve` returns `.subscription` when `config.usesSubscription && AuthManager.shared.isAuthenticated`; throws `.notSignedIn` when the mode says subscription but there's no session; throws `.missingBYOKConfig` when BYOK is selected but the relevant keys are blank — centralizing the six scattered copies of `guard !config.googleAIKey.isEmpty`.

Deliberately an enum + factory, not a protocol with two conformances: that matches the repo's house style (`CaptionTranscriberFactory.client(for:)`).

## 2.4 Wrapping the six façades — no call-site churn

Each façade keeps `static func generate(project:context:config: AppConfig)` exactly as today; the only change is a branch at the top of the existing provider `switch`:

```swift
// clients/services/ImageGenerationService.swift
let result: ImageGenResult
switch try AIRoute.resolve(config, for: .image) {
case .subscription:
    result = try await BackendImageClient.generate(
        prompt: project.prompt, model: project.subscriptionModel,
        options: BackendImageOptions(project: project))
case .byok:
    // …existing body verbatim…
}
// FileStorage.saveImage + context.insert below — untouched
```

- **`MusicGenerationService`** — same two-line switch around the single `LyriaClient.generate` call.
- **`NarrativeGenerationService`** — its two `case`s (`.gemini`/`.azure`) each get the switch. `generateCaptionsIfEnabled` passes `config` down, so captions inherit the mode free.
- **`CaptionTranscriptionService`** — **no edit at all.** Change one line in the factory:
  ```swift
  static func client(for provider: CaptionProvider, config: AppConfig) -> any CaptionTranscriberClient.Type {
      if config.usesSubscription, provider.requiresNetwork { return BackendTranscriptionClient.forProvider(provider) }
      switch provider { case .azure: … }   // unchanged
  }
  ```
  `provider.requiresNetwork` (`CaptionEnums.swift:42`) is already `false` for `.whisperLocal`, so **on-device Whisper stays free** in subscription mode — that falls out of the existing enum.
- **`CaptionTranslationService`** — add `BackendCaptionTranslationRunner` alongside `AICaptionTranslationRunner`/`AppleTranslationRunner`; the two construction sites pick it when `usesSubscription`. Apple on-device translation stays free.
- **`RemotionProjectService`** — routes through `ImageGenerationService`, inherits the change.
- **`AgentRuntime`** — `AgentRuntime.swift:102-105` currently throws `.missingLLMConfig` unless endpoint+key+model are set; becomes a route switch, and the `OpenAIClient.chatWithTools(endpoint:apiKey:model:…)` call at `:141-143` gets one too. `AgentBackend.claudeCode`/`.codex`/`.appleIntelligence` are **unaffected** — those authenticate themselves and cost no credits, so they stay available in subscription mode.

## 2.5 Model & voice sources

```swift
// clients/backend/AIModelPickerSource.swift
@MainActor enum AIModelPickerSource {
    static func models(capability: AICapability, config: AppConfig, forceRefresh: Bool)
        async throws -> [PickableModel]   // { id, displayName, pointsPerUnit? }
}
```
Calls `BackendModelCatalog` in subscription mode, `OpenAIModelsClient`/`GoogleModelsClient` in BYOK mode. `AIProviderSettingsView.loadChatModels/loadImageModels` (`:358,376`) become one-line calls; the `canFetchChatModels` guard (`:293`) becomes `config.usesSubscription || (endpoint && key non-empty)`.

`AzureVoiceStore:62`, `AzureVoicePreviewer:54`, `GeminiVoicePreviewer:45` each get the same one-line branch (`BackendVoiceClient.fetchAzureVoices()` vs `AzureTTSClient.fetchVoices(apiKey:endpoint:)`). Voice *listing* is free; voice *previews* go through `/api/v1/ai/speech` and do cost ~1 credit.

## 2.6 Settings UI

**New Account tab.** `AppNavigation.SettingsSection` gains `case account` (first, so it's the default landing tab) plus `showAccountSettings()`. `SettingsView.swift` adds the `AccountSettingsView().tabItem { Label("Account", systemImage: "person.crop.circle") }`.

**`views/settings/AccountSettingsView.swift`** (new) — signed out: `RxSignInView` from `RxAuthSwiftUI`, or a plain "Sign in with RxLab" button calling `AuthManager.shared.signIn()`. Signed in: it **embeds the same `AccountSheet` body** (extracted as `AccountDetailContent`) so balance/usage/top-up are written once and appear identically in Settings and in the sheet — the Settings tab is then just a third entry point next to the menu bar and sidebar footer (§2.7).

**`views/settings/AIProviderSettingsView.swift`** (414 lines today) — restructure, don't rewrite:
1. New first section: `Picker("AI credentials", selection: $credentialMode)`, `.segmented`.
2. Wrap the Google / Azure / OpenAI-compatible **key** sections in `if credentialMode == .byok`. The **provider and model pickers stay outside** — switching modes only hides key entry.
3. In subscription mode each section's footer reads "Provided by your RxFilm Studio subscription", and model pickers show the estimated cost (`"GPT Image 1 · ≈42 credits/images"`) from `pointsPerUnit`. The catalog uses the Vercel AI Gateway model id `openai/gpt-image-1`, matching the main app's provider-qualified image model.
4. The macOS "Command-line agents" section (`:193-255`) stays visible in **both** modes.
5. `currentConfig()` (`:329`) gains `credentialMode:` — one line; every save path already funnels through it.

## 2.7 Account entry points — menu bar, sidebar, account sheet

Three surfaces, **one state machine**, so the signed-out/signed-in split is written once.

### The shared control — `views/account/AccountControl.swift`

```swift
/// Signed out → a plain button. Signed in → a menu.
/// Both variants read AuthManager.shared + CreditBalanceStore.shared, so
/// every placement stays in sync with no plumbing.
@MainActor struct AccountControl: View {
    enum Placement { case sidebarFooter, menuBarCommands }
    let placement: Placement
}
```
Actions, identical in every placement:

| Action | Behaviour |
|---|---|
| **Sign In** | `await AuthManager.shared.signIn()` — RxAuthSwift PKCE flow (in-app `WKWebView` on macOS). |
| **Account…** | Presents `AccountSheet` (below). |
| **Manage Subscription…** | `CreditBalanceStore.shared.openTopUp()` → system browser at `webBaseURL/credits?app=1`. |
| **Sign Out** | `await AuthManager.shared.signOut()`; clears `CreditBalanceStore`. Confirmation alert first. |

Because sign-out is destructive-ish and sign-in opens a window, both go through `AuthManager`, never through view-local state.

### (a) macOS menu bar — `CommandMenu("Account")`

In `film_workflowApp.swift`'s existing `#if os(macOS) .commands { … }` block, alongside the current `CommandGroup(after: .appInfo)` (Check for Updates) and `CommandGroup(after: .toolbar)` (Agent). A **top-level `CommandMenu`**, not a `CommandGroup`, so it gets its own title next to View/Window:

```
  Account
  ────────────────────────────
  qiwei@rxlab.app
  4,580 credits
  ────────────────────────────
  Account…                    ⌘⇧A
  Manage Subscription…
  ────────────────────────────
  Sign Out
```
Signed out, the menu collapses to a single **Sign In…** item. The email/balance rows are `Text` (disabled), not buttons.

Two constraints this placement imposes:
- `.commands` is a `Scene` builder outside any view hierarchy, so it cannot use `@Environment`. `AccountControl` reads `AuthManager.shared` / `CreditBalanceStore.shared` singletons directly — which is why they are singletons.
- Presenting the sheet from a menu command needs a scene-level trigger, since `.commands` can't present. Add `@Observable AppNavigation.shared.showAccountSheet: Bool` (mirroring the existing `settingsSection` / `pendingSettingsFocus` pattern in `config/AppNavigation.swift`) and bind `.sheet(isPresented:)` in `ContentView`.

### (b) Sidebar footer

All five tab views (`MusicTabView`, `NarrativeTabView`, `CaptionTabView`, `ImageGenTabView`, `RemotionTabView`) build their own `private var sidebar: some View` as a `List(selection:)` + `GroupedProjectSections`. Rather than editing five list bodies, add a `View` extension and apply it as **one line per file** on the `sidebar` property:

```swift
// views/account/AccountSidebarFooter.swift
extension View {
    /// Pins the account control to the bottom of a NavigationSplitView sidebar.
    func accountSidebarFooter() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            AccountControl(placement: .sidebarFooter)
        }
    }
}
```
`.safeAreaInset` rather than putting a `Section` at the end of the `List`: the footer must stay pinned while the project list scrolls, and it must not be selectable as a list row.

Signed out it renders a full-width **"Sign in"** button; signed in, a row with avatar/initial, email, and `4,580 credits` in `.caption .secondary`, wrapped in a `Menu` so the whole row is the trigger. Separated from the list by a `Divider()` and `.background(.bar)`.

Applied at `MusicTabView.swift:56`-ish, and the matching spot in the other four — each right next to the existing `.navigationSplitViewColumnWidth(min: 200, ideal: 240)`.

### (c) `views/account/AccountSheet.swift`

A SwiftUI sheet — deliberately **not** a browser hand-off, so the common "how many credits do I have left" check never leaves the app:

- **Balance header** — available points large, `reserved` as a secondary line when non-zero, "Last updated 2m ago" + refresh button.
- **Add Credits** — prominent button → `openTopUp()` (browser). This is the only thing that must leave the app, because Stripe checkout does.
- **Usage** — the last ~20 entries from `GET /api/billing/usage`, grouped by `capability` (chat / image / speech / music / transcription) with a per-group point subtotal, then a dated list. Backed by a new `clients/backend/UsageHistoryStore.swift` (`@Observable @MainActor`, paginated, same 402/401 handling as `BackendClient`).
- **Footer** — "View full history in browser" link, and the signed-in email with **Sign Out**.
- Presented via `.sheet(isPresented: $navigation.showAccountSheet)` in `ContentView`, so both the menu command and the sidebar footer open the same instance. `.frame(minWidth: 480, minHeight: 560)` on macOS; a `NavigationStack` sheet on iOS.

### Balance freshness

`CreditBalanceStore.refresh()` fires on: app launch, `scenePhase → .active` (returning from the Stripe browser tab), the `filmstudio://credits/refresh` deep link, after any completed generation (the `usage` block in each AI response already carries `availablePoints`), and manual refresh. No polling timer.

### iOS

No menu bar and no persistent sidebar. `AccountControl` renders in the Settings tab header, and `AccountSheet` is pushed onto the existing `NavigationStack` in `ContentView`'s Settings tab rather than presented as a sheet. **Add Credits is hidden on iOS** — see the App Store IAP risk in Part 4.

## 2.8 Error handling

`views/components/InsufficientCreditsAlert.swift` — a `ViewModifier` rendering "You need 240 credits; 12 available" with **Top up** (opens the browser, refreshes on `.onOpenURL` / `scenePhase == .active`) and **Cancel**. Applied at the six generation entry points that already show error alerts.

MCP handlers return the 402 as an MCP tool error whose text includes the credits URL, so the agent explains it in prose. `AIRouteError.notSignedIn` surfaces as an alert with "Sign in" that opens Settings › Account via `AppNavigation.shared.showAccountSettings()` + `openSettings()` — the same dance as `showCaptionSettings`.

**Never auto-fall-back to BYOK.** Silently spending the user's own OpenAI key when they expected subscription billing is worse than an error.

## 2.9 URL scheme & build config

New `film-workflow/Config/{Base,Debug,Release}.xcconfig` mirroring `linda-assistant/ios/Config/Debug.xcconfig` (including its `$()` trick so xcconfig doesn't treat `//` as a comment):
```
APP_AUTH_ISSUER       = https:/$()/auth.rxlab.app
APP_AUTH_URL_SCHEME   = filmstudio
APP_AUTH_REDIRECT_URI = $(APP_AUTH_URL_SCHEME):/$()/callback
APP_AUTH_SCOPES       = openid email profile offline_access
APP_AUTH_CLIENT_ID    = filmstudio-macos
APP_API_BASE_URL / APP_WEB_BASE_URL   # localhost:3000 in Debug, filmstudio.rxlab.app in Release
```
Set `baseConfigurationReference` on the Debug/Release configs of the `film-workflow` target in `project.pbxproj`.

The repo-root `Info.plist` (which already exists purely for Sparkle's `SUFeedURL`/`SUPublicEDKey`) gains `AppAPIBaseURL`, `AppWebBaseURL`, `AppAuthIssuer`, `AppAuthClientID`, `AppAuthRedirectURI`, `AppAuthScopes`, and a `CFBundleURLTypes` entry for `$(APP_AUTH_URL_SCHEME)`.

*Accuracy note:* on macOS, sign-in itself does **not** require the scheme to be registered — `RxAuthSwift/Sources/RxAuthSwift/Platform/MacOSWebAuthSession.swift` runs an in-app `WKWebView` and intercepts the callback in its navigation delegate. The registration is needed for the **return-from-Stripe deep link** (`filmstudio://credits/refresh`).

`film-workflow.entitlements` already has `network.client` and app-sandbox off — **no entitlement change needed.**

`film_workflowApp.swift` gains `await AuthManager.shared.checkExistingAuth()` + `await CreditBalanceStore.shared.refresh()` in the `WindowGroup`'s `.task`, plus `.onOpenURL { AuthSessionBridge.handle($0) }`.

---

# Part 3 — Phased rollout

Each phase builds, ships, and is verifiable on its own.

| Phase | Scope | Verification |
|---|---|---|
| **0 — Backend skeleton** | deps, `lib/db/*`, `drizzle.config.ts`, `lib/auth.ts`, NextAuth route, `/login`, `/dashboard` | Sign in on the website, see a dashboard. Marketing page untouched. |
| **1 — Billing core, no AI** | copy `lib/billing/*` + ceil change, `/api/billing`, `/checkout`, `/webhooks/stripe`, `/credits`, `/usage`, `/invoices` | Port yc's `billing.test.ts`, `billing-pricing.test.ts`, `billing-history.test.ts`, `billing-checkout-route.test.ts`, plus ceil tests (`pointsFromCost(1) === 1`, `pointsFromCost(1_000_001) === 2`). Stripe test-mode purchase credits the ledger; a refund reverses it. |
| **2 — Desktop auth only** | `BackendConfig`, `AuthManager`, `CreditBalanceStore`, `UsageHistoryStore`; the three account surfaces from §2.7 — `CommandMenu("Account")`, `.accountSidebarFooter()` on all five tab views, `AccountSheet` — plus `AccountSettingsView`, xcconfig/Info.plist/URL scheme, `GET /api/v1/me`, `GET /api/billing/usage`, `lib/auth/bearer.ts`. `credentialMode` exists but the picker is behind a debug flag. | Sign in from the Account menu **and** from the sidebar footer; both open the same sheet. See a real balance and usage list, Add Credits → browser → buy → return → balance updates. Sign out empties all three surfaces. All AI still BYOK. |
| **3 — Images (first metered capability)** | `unit-pricing.ts`, `lib/ai/{catalog,image,meter}.ts`, `/api/v1/ai/images`, `/api/v1/models`; desktop `AIBackend`, `BackendClient`, `BackendImageClient`, `BackendModelCatalog`, `ImageGenerationService` switch, `AIModelPickerSource`, 402 alert, and the visible mode picker (other sections show "Coming soon" in subscription mode). | Images are the right first pick: one request, one unit, bounded duration, no streaming, tiny value type. |
| **4 — Chat / narrative text / caption AI** | `/api/v1/ai/chat`, `BackendChatClient`, `AgentRuntime` switch, `BackendCaptionTranslationRunner` | An agent turn with tool calls charges per step and the balance chip ticks down. |
| **5 — Speech + voices** | `/api/v1/ai/speech`, `/api/v1/ai/voices`, `BackendTTSClient` reusing the existing batcher/stitcher, voice-store branches, `NarrativeGenerationService` switch | Highest-risk phase for duration/body limits. |
| **6 — Transcription** | `/api/v1/uploads` (presigned S3 upload), `/api/v1/ai/transcriptions`, `BackendTranscriptionClient`, the one-line factory change | Whisper-local stays free. |
| **7 — Music (async jobs)** | `aiJobs` table, `/api/v1/ai/music` → 202, `/api/v1/jobs/[jobId]`, `BackendMusicClient.awaitJob`, `MusicGenerationService` switch | |
| **8 — Polish** | public `/models` price page, usage grouped by capability, device management, reconciliation + reservation-reaper crons, iOS UI, App Store prep | |

---

# Part 4 — Risks and open issues

- **Vercel 4.5 MB body limit vs. audio.** `CaptionTranscriber.swift:84-86` itself notes files run to hundreds of MB. Mitigation: `/api/v1/uploads` issues a user-scoped presigned S3 PUT, then the function receives only an `object_key`. R2 is accessed through the standard S3 client and `S3_PUBLIC_URL` supplies the custom asset domain. Fallback: the existing `CaptionAudioChunker`, whose offset re-stitching the desktop already does for BYOK.
- **Function duration.** Fluid caps at 300 s (Pro). Azure TTS is already split into batches by `AzureTTSClient.swift:70-72` with `maxConcurrent = 2`, so it fits; Lyria and long transcriptions do not → the `aiJobs` async pattern. *Open:* Vercel Workflow (as yc uses for `workflows/usage-reconciliation.ts`) vs. a plain cron-drained queue — the latter avoids a dependency but has worse latency.
- **Streaming chat.** `OpenAIClient.chat`/`chatWithTools` are non-streaming today, so v1 dodges this. When streaming lands: token usage arrives only in the final chunk, so metering must attach to the server-side `onFinish` (as `yc/app/api/chat/route.ts:150` does inside `createUIMessageStream`) — a client disconnect must still settle. A mid-stream 402 is impossible, so the reservation must be sized up front.
- **Reservation sizing under ceil.** Ceil + multi-step agent turns makes `BILLING_RESERVATION_EXCEEDED` likelier than in yc. Mitigations: `reservationMarginBps` 15_000, and `topUpReservation()` to grow an open reservation mid-run.
- **Token expiry mid-run.** A multi-batch TTS run holds one reservation across several requests; a refresh failure leaves it open. The backend needs a **reservation reaper cron** releasing any `open` reservation older than 30 minutes.
- **Price drift.** `UNIT_PRICES` will go stale. Mitigations: `reviewedAt` + a test that fails past 180 days + a monthly reminder. Long term, route images through AI Gateway so `estimatedCostNanoUsd` handles them and the table shrinks to Azure TTS + Lyria.
- **Charging for failed generations.** Azure can return 200 with partial audio; `LyriaClient.extractFinishFailure` already catches Lyria finish failures. Settle strictly on *measured output* — characters synthesized, images returned, seconds produced — never on the request.
- **App Store IAP.** Guideline 3.1.1 requires IAP for consumable credits used in-app, and 3.1.3(b) only lets an iOS app *use* credits bought elsewhere — it may not link out to buy them. The Mac app is direct-distribution (it already ships a Sparkle appcast at `update.filmstudio.rxlab.app`), so Stripe links are fine there. For iOS, pick one: omit from the App Store initially, ship BYOK-only, or add StoreKit 2 consumables granting points through a `fulfillTopup`-equivalent driven by App Store Server Notifications V2 — the ledger already models that as another `top_up` kind, so it's an adapter, not a redesign.
- **Provider key blast radius.** All keys now sit in one Vercel project. Rate-limit per user/device, cap per-request sizes (max chars per TTS call, max images, max audio minutes), and set a hard daily point ceiling per account so a leaked token can't burn a balance in minutes.
- **MCP server exposure.** `clients/mcp/` runs a local HTTP server whose handlers call the same services. In subscription mode anything reaching that port can spend the signed-in user's credits — the local bearer token should be enforced before Phase 3 ships.

---
