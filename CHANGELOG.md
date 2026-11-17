# Changelog

## 0.3.1

- The XCTest observer's closing line counts every result sent during the run.
  It counted only the final send, so classes that went out earlier on the
  timer were missing (`6 of 8` when all 8 had arrived).
- The observer starts a send as soon as each test class finishes, rather than
  waiting for the 30-second timer.
- `RoboboroTracker.totals`: events sent and refused since `start`, by every
  flush, what is still pending, and the latest failure.

## 0.3.0

Test results:

- `RoboboroXCTest`, a new product for test bundles. `RoboboroXCTestObserver`,
  set as the principal class, sends every XCTest outcome as a `test_result`
  with a readable name, status, duration, first failure, and where it failed.
  It is configured from the runner's environment and the bundle's Info.plist,
  never reads an API key from a plist, and prints one line saying what was sent.
- A retried test is one row: the last attempt's status, with `flaky` and
  `attempts`.
- Test results carry `source` (`xctest` by default). The server only keeps
  failures from app telemetry, so 0.2.0's test results lost every pass.
- `RoboboroTestResultInput` takes `source`, `flaky`, `attempts`, and `data`.

Delivery:

- `flush()` returns what it did: sent, dropped, still pending, and the last
  failure. Existing callers can ignore it.
- `pendingCount` says how many events are not yet accepted.
- `start` no longer waits for the main thread, so a caller that blocks the
  main thread (an XCTest observer) can start a tracker. `RoboboroDevice` reads
  the system version and model without UIKit.
- `RoboboroTracker()` is public: a tracker of your own, apart from `shared`.
  Only `shared` installs crash capture.
- `sendsSessionStart` and `observesAppLifecycle` can be turned off.

From main, merged with 0.2.0:

- A batch is written to storage before its post, so a kill mid-flight sends it
  next launch, and an acknowledged batch is never sent twice. (On main, a
  session event could be sent twice in one batch.)
- The default session is ephemeral, sends no cookies, and refuses a redirect
  onto another host or onto http.
- Session start stores a stable `visitor_id` (`rbv_…`) for this install. It is
  not an account or an email.

## 0.2.0

- Crash capture, on by default (`captureCrashes`): an uncaught Objective-C
  exception is stored as a `fatal` exception event with its call stack and
  sent on the next launch. Any handler installed earlier still runs. Swift
  traps and signals are not captured.
- Unsent events are written to storage within half a second of each event, so
  killing the app no longer loses the queue. Only events the server accepted
  are removed.
- Exceptions now group by error domain and code (or Swift type and case)
  instead of the translated message, so the same error groups together in
  every device language. Existing issues from 0.1.0 will start a new group.
- `trackScreen` no longer sends an event per screen. It records a navigation
  breadcrumb and sets the screen shown on later events.
- `optIn()` clears a stored opt-out; call `start` again to resume tracking.
  `optOut()` now also stops tracking until then.
- A 400 or 413 response drops that batch instead of retrying it forever.
  429, 5xx (including the BFF's 502 when sublime-go fails), and network
  errors retry with a growing wait, up to five minutes.
- Going to the background asks iOS for time to finish sending.
- Calling `flush()` from several places at once sends once.

## 0.1.0

- Native iOS / Swift port of `p1-roboboro-tracker/native`: exceptions, messages,
  breadcrumbs, screen events, and session start.
- Same-origin-or-BFF ingest: `POST {apiBase}/ingest` with optional
  `Authorization: Bearer` (`P1_API_KEY`).
- Durable pending buffer (UserDefaults), single-flight flush, HTTP status
  treated as failure (non-2xx requeues).
- Opt-out persists across launches. No default `apiBase` — the host must set it.
