# RoboboroKit

**Native iOS / Swift** port of Mathematica’s functional monitoring tracker
([`p1-roboboro-tracker`](https://github.com/mathematica-ai/p1-roboboro-tracker) **native** adapter).

| Surface | Package |
|---------|---------|
| Web / RN / Node | `p1-roboboro-tracker` (JS) |
| **iOS / SwiftUI / UIKit** | **RoboboroKit** (this repo) |

Wire format matches `POST {apiBase}/ingest` (Sentry-shaped issues, Playwright
results, session breadcrumbs). The Next.js BFF at `/api/v1/roboboro` forwards
to sublime-go with `P1_API_KEY`.

Do **not** put `P1_API_KEY` in a browser or app binary if a BFF can attach it.

## Requirements

- iOS 15+ (also macOS 12+ for host tools/tests)
- Swift 5.9+
- Xcode 15+

## Install (Swift Package Manager)

### Xcode

**File → Add Package Dependencies…**

```
git@github.com-math:mathematica-ai/roboborokit.git
```

(or `https://github.com/mathematica-ai/roboborokit.git`)

### `Package.swift`

```swift
dependencies: [
  .package(url: "git@github.com-math:mathematica-ai/roboborokit.git", from: "0.2.0"),
],
targets: [
  .target(name: "YourApp", dependencies: ["RoboboroKit"]),
]
```

Local path (this monorepo):

```
../roboborokit
```

## Quick start

```swift
import RoboboroKit

Task {
  _ = await initRoboboroTracker(config: RoboboroConfig(
    siteId: "p1-314-ios",
    // Next BFF — no key in the binary. Or `{P1_API_URL}/api/v1/roboboro` + apiKey.
    apiBase: "https://www.principia1.com/api/v1/roboboro",
    organisationSlug: "principia-one"
  ))
}

RoboboroTracker.shared.trackScreen("Ask")
RoboboroTracker.shared.captureException(error, extra: ["phase": "load_brain"])
RoboboroTracker.shared.addBreadcrumb(category: "sync", message: "knowledge_start")

Task { await RoboboroTracker.shared.flush() }
RoboboroTracker.shared.optOut()
RoboboroTracker.shared.optIn() // clears the opt-out; call start again to resume
```

`trackScreen` sends no event of its own: it adds a `navigation` breadcrumb and
sets the `screen` carried by later events.

`apiBase` is **required**. There is no silent production default.

## Config

| Option | Default | Notes |
|--------|---------|--------|
| `siteId` | required | Project / site id |
| `apiBase` | required | Absolute. Appends `/ingest` |
| `apiKey` | `nil` | **Server / sublime-go only.** BFF hosts omit |
| `organisationSlug` | — | Tenant for `/roboboro` console |
| `environment` | — | e.g. `debug` / `production` |
| `release` | — | App version |
| `hasConsent` | grant | Return `false` to block init; `optOut()` always wins |
| `flushInterval` | 5 s | Background flush is additional |
| `captureCrashes` | `true` | Uncaught Objective-C exceptions become `fatal` events, stored at once and sent on next launch. Chains to an earlier handler |

## Delivery and retries

- Unsent events are written to storage (debounced, at most 100) and loaded on
  the next `start`. A flush removes only what the server accepted.
- 2xx: sent. **400 / 413**: the batch is dropped (the server will never take
  it). **429, 5xx, network errors**: requeued, and the next attempt waits
  5 s, 10 s, 20 s… up to 5 minutes; a success resets the wait.
- The Next BFF at `/api/v1/roboboro/ingest` returns a non-2xx status (502)
  when sublime-go rejects or fails, so those events are retried, not lost.
- Backgrounding the app starts a flush inside a background task.
- `flush()` is single-flight: concurrent callers share one send.

## Crash capture limits

Only uncaught `NSException`s are recorded. Swift runtime traps
(`fatalError`, force-unwrap of `nil`, array bounds) and signals such as
SIGSEGV are not: a signal handler may only call async-signal-safe
functions, and building an event is not one. Pair with a crash reporter if
you need those.

## Relation to p1-roboboro-tracker

| Concern | JS native | RoboboroKit |
|---------|-----------|-------------|
| Storage | AsyncStorage | UserDefaults |
| App lifecycle | AppState | `UIApplication` background |
| Ingest | `fetch` → `/ingest` | `URLSession` → `/ingest` (2xx only, backoff) |
| IDs / fingerprint | `core.ts` / `server.ts` | `Core.swift` (same `rb_` ids, SHA-256-16; exceptions keyed by domain#code, not the translated message) |
| Vitals | no-op | no-op |

## Privacy

- No IDFA. Opt-out flag lives in UserDefaults (`roboboro_optout`).
- Hosts must not attach chat text, voice audio, or pack contents in `extra`.
- Pair with the product privacy policy; contact **info@mathematica.ai**.

## Develop

```bash
cd roboborokit
swift test
```

## License

MIT — Mathematica
