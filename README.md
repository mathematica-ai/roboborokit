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
  .package(url: "git@github.com-math:mathematica-ai/roboborokit.git", from: "0.3.0"),
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
| `captureCrashes` | `true` | Uncaught Objective-C exceptions become `fatal` events, stored at once and sent on next launch. Chains to an earlier handler. Only `shared` installs it |
| `sendsSessionStart` | `true` | A `session_start` event with a stable `visitor_id` (`rbv_…`) for the install. Not an account or an email |
| `observesAppLifecycle` | `true` | Flush in a background task when the app goes to the background |

## Delivery and retries

- Unsent events are written to storage (debounced, at most 100) and loaded on
  the next `start`. A flush removes only what the server accepted.
- 2xx: sent. **400 / 413**: the batch is dropped (the server will never take
  it). **429, 5xx, network errors**: requeued, and the next attempt waits
  5 s, 10 s, 20 s… up to 5 minutes; a success resets the wait.
- The Next BFF at `/api/v1/roboboro/ingest` returns a non-2xx status (502)
  when sublime-go rejects or fails, so those events are retried, not lost.
- Backgrounding the app starts a flush inside a background task.
- `flush()` is single-flight: concurrent callers share one send. It returns a
  `RoboboroFlushResult`: how many events were `sent`, `dropped` (400 / 413),
  and still `pending`, and the last `failure` (`http 502`, or the network
  error). A batch is on disk before its post, so a kill mid-send loses nothing.
- Batches are at most 50 events, the server's limit.
- The default session is ephemeral: no cookies, no cache, and a redirect is
  followed only on https to the same host.

## Test results (XCTest)

Link the `RoboboroXCTest` product from a test bundle (never from the app) and
make its observer the bundle's principal class. Every test's outcome goes to
Roboboro as a `test_result`, the way p1-website's Playwright reporter does:

```yaml
# XcodeGen
AppUITests:
  dependencies:
    - package: RoboboroKit
      product: RoboboroXCTest
  info:
    properties:
      NSPrincipalClass: RoboboroXCTest.RoboboroXCTestObserver
      RoboboroAPIBase: https://www.principia1.com/api/v1/roboboro
      RoboboroOrganisationSlug: principia-one
```

It stays off until the runner has a site id. xcodebuild hands the runner every
variable prefixed `TEST_RUNNER_`, without the prefix:

```bash
TEST_RUNNER_ROBOBORO_SITE_ID=site_… TEST_RUNNER_ROBOBORO_RUN_ID=$GITHUB_RUN_ID \
  xcodebuild test -scheme AppUITests -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max'
```

| Setting | Environment | Info.plist |
|---|---|---|
| site id | `ROBOBORO_SITE_ID` | `RoboboroSiteID` |
| API base | `ROBOBORO_API_BASE` | `RoboboroAPIBase` |
| API key | `ROBOBORO_API_KEY` | never |
| organisation | `ROBOBORO_ORGANISATION_SLUG` | `RoboboroOrganisationSlug` |
| environment | `ROBOBORO_ENVIRONMENT`, else `ci` when `CI` is set, else `local` | |
| run id | `ROBOBORO_RUN_ID`, else `GITHUB_RUN_ID`, else a new UUID | |
| release | `ROBOBORO_RELEASE`, else the bundle's version and build | |
| name prefix | `ROBOBORO_NAME_PREFIX` | `RoboboroNamePrefix`, else `iOS` |

What it sends:

- One row per test. `-[HomeJourneyTests testScrubbingShowsThatDay]` reads as
  `iOS › HomeJourneyTests › Scrubbing shows that day`, and that name is the
  fingerprint, so a test keeps one row across runs.
- `PASSED`, `FAILED`, or `SKIPPED`, the duration, and for a failure the first
  issue and where it happened.
- A test that failed and then passed on a retry is one `PASSED` row with
  `flaky: true` and `attempts`.
- `suite`, `device` (the simulated model on a simulator), and `os_version` in
  `data`.
- `source: "xctest"`. Roboboro keeps every result from a test source and shows
  the latest status per test. App telemetry (no source, `roboboro` on the
  server) only turns failures into issues, so passes sent that way vanish.
- No `session_start`. The observer uses a tracker of its own, so a hosted unit
  test never mixes with the app's events.

Each class's results are sent when the class finishes, so a runner that dies
later has still reported what finished. The run ends with one line in the
log, for example `Roboboro: 8 of 8 results sent to www.principia1.com, run
1234, ci.`

`RoboboroTracker()` makes a tracker of your own for anything else that must
stay apart from `shared`.

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

`RoboboroXCTestTests` runs sample tests under the observer, including ones
that fail on purpose. Their failures print in the log but are not the suite's.

## License

MIT — Mathematica
