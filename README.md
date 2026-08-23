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
  .package(url: "git@github.com-math:mathematica-ai/roboborokit.git", from: "0.1.0"),
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
```

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

## Relation to p1-roboboro-tracker

| Concern | JS native | RoboboroKit |
|---------|-----------|-------------|
| Storage | AsyncStorage | UserDefaults |
| App lifecycle | AppState | `UIApplication` background |
| Ingest | `fetch` → `/ingest` | `URLSession` → `/ingest` (2xx only) |
| IDs / fingerprint | `core.ts` / `server.ts` | `Core.swift` (same `rb_` ids, SHA-256-16) |
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
