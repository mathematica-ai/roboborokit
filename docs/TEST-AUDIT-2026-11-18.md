# RoboboroKit test audit, 18 Nov 2026

*Prepared 18 Nov 2026 (WET) by Pitch for Bruno Antunes Luis. Read-only audit. This file is the only change made in the repo. It is untracked, and nothing was committed or pushed.*

## Summary of findings

- **47 XCTest cases, all passing.** RoboboroKitTests ran 34 and RoboboroXCTestTests ran 13. They only cover Mac logic, run in-process with `swift test`. The iOS-only background code is not even compiled under test.
- **The "dummy test app"** is `SampleJourneys`: four stand-in tests (`testPasses`, `testFailsOnce`, `testFails`, `testSkips`). The observer tests drive them by hand with nested `test.run()`, which makes XCTest print "still running" warnings. There is no real host app.
- **Risky flows with no real test:** crash and relaunch in a real process, iOS backgrounding with a background task, the real `URLSession` network path, and the payload format the sublime-go ingest accepts.
- **Two likely bugs, unconfirmed until a test fails:**
  - `destroy()` during an in-flight send leaves the batch the server already accepted on disk, so it is resent after the next start.
  - At the 100-event cap, new events (crashes included) are dropped silently and nothing counts them.
- **Plan:** turn the stand-ins into a scenario-driven harness: a macOS command-line host that is killed and relaunched for real, an iOS host app with UI tests, and a mock ingest that enforces the server's rules. Add contract fixtures shared with sublime-go and a CI matrix. Test cases are prioritised P0, P1 and P2 in section 5.

## Main today vs this audit

**Checked by `git fetch origin` (read-only for the working tree) on 18 Nov 2026 (WET):**
- The checked-out branch is `main`, at `5261fd2799f226a8446ffef78b041e17f540cb17`.
- `origin/main` is at the same commit, `RoboboroKit 0.3.1: the closing line counts every result sent.`, committed on 17 Nov 2026 at 11:56 (WET).
- `git log main..origin/main` and `git log origin/main..main` are both empty. Main is **not ahead** of the audited commit, and the working tree had no changes before this file.
- The only other remote branch is `claude/reliability-0.2.0` at `583d9a8`, which is already merged into main.

So the audit below is an audit of current main. Each recommendation against main:

| Recommendation | On main (5261fd2) | Status |
|---|---|---|
| Deterministic unit seams: fake transport, in-memory storage, clock | `FakeTransport`, `RecordingTransport`, `RoboboroMemoryStorage`, internal `now` | **Partial.** Clock only. There's no ID, scheduler or background-task seam, and the debounce test still sleeps. |
| Retry, backoff, drop and chunking tests | Present (section 2) | **Addressed** |
| Single-flight flush, flush result, own-tracker isolation | Present | **Addressed** |
| Opt-out and opt-in, observer settings, readable names, flaky row | Present | **Addressed** |
| Durability across a kill or relaunch (P0) | Faked with a second object over the same memory storage | **Partial** |
| Crash capture in a real child process (P0) | `handle(_:)` called by hand | **Partial** |
| `destroy()` during a send, and the queue cap with eviction counting (P0) | No tests | **Absent** |
| iOS background flush and background task (P0) | Not compiled under test | **Absent** |
| Real `URLSession` transport against a loopback mock (P0) | Redirect rule only, as a pure function | **Partial** |
| Contract fixtures shared with sublime-go, generated fingerprint vectors (P0) | One golden fingerprint vector | **Partial** |
| Observer in a real bundle, retries, parallel runs, Swift Testing (P0/P1) | Simulated by `SampleJourneys`. Real use only through iMoney CI. | **Partial** |
| Harness: scenario catalogue, macOS CLI host, iOS host app, mock ingest | None | **Absent** |
| CI workflow, Thread Sanitizer, iOS simulator, tvOS and watchOS builds (P0/P2) | No `.github/` | **Absent** |
| Timeouts and hangs, crash-capture lock timeout, `identify` privacy, privacy manifest (P1) | None | **Absent** |
| Property tests, performance baselines, version and changelog check (P2) | None | **Absent** |

---

## 0. Verdict in one paragraph

The unit tests are good for the size of the kit. They are deterministic, with a fake transport, in-memory storage and an injectable clock. They cover retry and drop rules, backoff, chunking, single-flight flush, opt-out and crash persistence. But every test runs **in-process on macOS**, so the iOS-only code is never compiled under test. That code is the background flush with `UIApplication` and the background task. The "dummy test app" is `SampleJourneys`: four stand-in tests (pass, fail once, fail, skip) that the observer tests drive by hand with `test.run()`. It is not a real host app. Nothing exercises the flows that matter in production end to end: a real process crash and relaunch, a kill during a send, going to the background, the real `URLSession` path with redirects and headers, the principal-class observer loading in a real bundle, or the wire contract against sublime-go. The fix is to turn the stand-ins into a **scenario-driven harness**: a macOS CLI and an iOS host app, driven by subprocess and XCUITest, posting to a local mock ingest that enforces the server's rules. On top of that come contract fixtures shared with sublime-go and a CI matrix. RoboboroKit has **no CI of its own** (no `.github/`). It is only exercised indirectly by iMoney's workflow.

---

## 1. What RoboboroKit is

A native Swift port (iOS 15+, macOS 12+, tvOS 15+, watchOS 8+; Swift 5.9 tools) of `p1-roboboro-tracker`'s native adapter. It does **functional monitoring**: it sends Sentry-shaped issues, messages, breadcrumbs, session starts and test results to `POST {apiBase}/ingest`. That is either the Next BFF at `/api/v1/roboboro`, which attaches `P1_API_KEY`, or sublime-go directly with a key. It ships two products:

### 1.1 `RoboboroKit` (app product)

| Area | Public API | Behaviour (from source) |
|---|---|---|
| Start | `initRoboboroTracker(config:storage:transport:)`, `RoboboroTracker.shared.start(...)`, `RoboboroTracker()` (own instance) | Trims and requires `siteId` and `apiBase`. Reads the stored opt-out. `hasConsent` can block. Loads pending events from storage. Installs crash capture (only on `shared`, only when `captureCrashes`). Sends `session_start` with a stable `rbv_` visitor id (`sendsSessionStart`). Starts the repeating timer (`flushInterval`, default 5 s) and the background observer (`observesAppLifecycle`). Idempotent when already running. |
| Capture | `captureException(_:extra:)`, `captureMessage(_:level:)`, `captureTestResult(_:)`, `captureWebVital()` (no-op) | Exceptions are fingerprinted by `domain#code`, or by Swift type plus case. Test results are fingerprinted by test name and carry `source` (`xctest` by default), `flaky` and `attempts`. |
| Context | `addBreadcrumb(category:message:data:)`, `trackScreen(_:)`, `identify(userId:traits:)` | Breadcrumbs are capped at 50, and each event carries the last 20. `trackScreen` sends no event: it adds a `navigation` crumb and sets `screen`. `identify` attaches a user (id, email, name) to later events. |
| Delivery | `flush() -> RoboboroFlushResult`, `pendingCount`, `totals` | Single-flight. Chunks of 50. A batch is written to disk before the post. 2xx acknowledges. 400 and 413 drop. 429, 5xx and network errors requeue with backoff of 5, 10, 20 s… capped at 300 s. The queue is capped at 100. |
| Consent | `optOut()`, `optIn()` | Opt-out persists (`roboboro_optout`) and clears the queue and storage. Opt-in clears the flag but needs `start` again. |
| Lifecycle | `destroy()` | Stops and drops the in-memory queue. Stored events stay for the next start. |
| Seams | `RoboboroStoring` (`RoboboroUserDefaultsStorage`, `RoboboroMemoryStorage`), `RoboboroTransporting` (`RoboboroURLSessionTransport`) | The URLSession transport is ephemeral, sends no cookies, has a 10 s timeout and only follows a redirect from https to https on the same host. |
| Helpers | `RoboboroIDs`, `RoboboroURL`, `RoboboroConsent`, `RoboboroErrorFields`, `RoboboroRetry`, `RoboboroRedirect`, `RoboboroPost`, `RoboboroDevice`, `RoboboroJSON`, `RoboboroKitModule.version` | Pure functions. |
| Crash capture | `RoboboroCrashCapture` (internal) | Turns an uncaught `NSException` into a `fatal` event, persisted synchronously, after waiting at most 0.5 s for the lock. It chains the previous handler. Swift traps and signals are out of scope by design. |
| Privacy | `PrivacyInfo.xcprivacy` resource | No IDFA. Hosts must not put chat, voice or pack content in `extra`. |

### 1.2 `RoboboroXCTest` (test-bundle product)

`RoboboroXCTestObserver` is set as `NSPrincipalClass`. It resolves `RoboboroXCTestSettings` from the environment (`ROBOBORO_*`, passed through as `TEST_RUNNER_*`) and then from Info.plist. The API key never comes from the plist. It starts its own quiet tracker: no session event, no crash capture, no lifecycle observer, and a 30 s timer. It records one outcome per test, keeping the first issue and its location. A failure followed by a pass on retry becomes one flaky `PASSED` row. It sends each class's results when the class finishes and drains at the end of the bundle, with a 30 s ceiling. It prints one closing line, e.g. `Roboboro: 8 of 8 results sent to …`.

### 1.3 Flows (the inventory every test plan must cover)

**App developer and app user flows**

- **F1 Install:** SPM on iOS, macOS, tvOS and watchOS, with the privacy manifest bundled.
- **F2 Start:** valid config, empty `siteId` or `apiBase`, consent refused, stored opt-out, start called twice, a second start after `destroy`.
- **F3 Session start:** a visitor id is created once and kept for the install.
- **F4 Capture exception:** `NSError`, Swift enum or struct errors, `extra` payloads, grouping that doesn't depend on locale.
- **F5 Capture message:** each level.
- **F6 Breadcrumbs and screens:** caps, ordering, and screen and crumbs riding on the next event.
- **F7 Identify:** user attached to later events.
- **F8 Flush:** timer, manual, concurrent callers, chunking beyond 50, result and totals accounting.
- **F9 Failure handling:** 2xx, 400 and 413 dropped, 429 and 5xx requeued with backoff, network error, bad URL, encode failure, mixed outcomes across chunks.
- **F10 Durability:** debounced persist, on disk before the post, kill mid-send, relaunch resend, no double send after an acknowledgement, 100-event cap, corrupt store, UserDefaults suite.
- **F11 Crash capture:** uncaught exception becomes a persisted fatal event, which is sent at next launch. Chaining. Lock-timeout path. Grouping with volatile numbers stripped.
- **F12 Opt-out and opt-in:** across launches.
- **F13 App lifecycle:** background, then a flush inside a background task, which ends on completion or expiry.
- **F14 Transport:** real `URLSession`: method, headers, bearer only when there is a key, body, redirect policy, timeout, non-HTTP response.
- **F15 Destroy:** stop timer and observers, keep storage.
- **F16 Isolation:** an own tracker never mixes with `shared`, and only `shared` installs crash capture.

**Test-runner flows (RoboboroXCTest)**

- **F17 Settings resolution:** environment before plist, CI and local environment, run id fallbacks, release from the bundle, no key from the plist, off when unset.
- **F18 Readable names:** sentence casing, acronyms, snake case, module-qualified names.
- **F19 Outcome capture:** pass, fail (first issue and location), skip, retry giving flaky, duration.
- **F20 Delivery:** per-class send, final drain, closing line, server failure, timeout ceiling, results kept apart from app telemetry.
- **F21 Real bundle loading:** `NSPrincipalClass` instantiation, unit and UI test bundles, parallel runners, test repetitions, Swift Testing.

**Cross-system flow**

- **F22 Wire contract:** payload accepted by sublime-go. `site_id` required, 1–50 events, `organisation_slug` required in some scopes, `data` cut to 24 flat values. Same fingerprint as Go and TS. `source` semantics.

---

## 2. The current test setup

| Target | File | Tests | What it is |
|---|---|---|---|
| `RoboboroKitTests` | `Tests/RoboboroKitTests/RoboboroKitTests.swift` (535 lines) | 25 | 0.1 and 0.2 behaviour. Includes `FakeTransport` (records calls, scripted status or error, delay, `onSend` hook, max concurrency), `SampleError` and `ChainedHandlerFlag`. |
| `RoboboroKitTests` | `Tests/RoboboroKitTests/ZeroThreeTests.swift` (145 lines) | 9 | 0.3 behaviour: flush result, chunking, test-result source, own tracker, start off the main thread, device info. |
| `RoboboroXCTestTests` | `Tests/RoboboroXCTestTests/RoboboroXCTestObserverTests.swift` (251 lines) | 13 real + 4 stand-ins | `RecordingTransport` plus the **"dummy test app"**. |

**The "dummy test app".** `SampleJourneys` is an `XCTestCase` with `testPasses`, `testFailsOnce`, `testFails` and `testSkips`. Its `defaultTestSuite` is overridden so it never runs as a suite of its own. The observer tests build `SampleJourneys(selector:)`, call the observer's callbacks by hand around `test.run()`, and inject the issue text themselves. The run log shows the cost: XCTest prints `WARNING: Starting test case -[SampleJourneys testPasses] while test case -[RoboboroXCTestObserverTests testTheClosingLineCountsEarlierSends] is still running` and `…finished which isn't running`. Nested runs are not how XCTest actually drives an observer. The callback order, threading and the `testSuiteDidFinish` hierarchy are all simulated.

**What each test asserts (short form)**

- **IDs, URLs and consent:** `testGenerateIdPrefix` checks the format. `testFingerprintMatchesJS` checks one golden vector, `"Chaos › Forecast"` gives `6d41f6dc829c1cd4`, plus whitespace and case normalisation. `testIngestUrlAppendsOnce` and `testConsentHonoursOptOut` cover their helpers.
- **Start:** `testInitRejectsEmptySiteId`, `testInitRejectsEmptyApiBase` and `testConsentCallbackCanBlockInit`. `testStartDoesNotNeedTheMainThread` checks that start finishes while the main thread is blocked, within 3 s.
- **Capture and encode:** `testCaptureExceptionSerializesAndFlushes` covers the URL, bearer, envelope fields, the session event and the exception fields. `testTrackScreenAddsBreadcrumbWithoutEvent` covers screens. `testATestResultCarriesItsSourceAndRetries` checks that `source: xctest` is present and that app telemetry has no source.
- **Grouping:** `testFingerprintIgnoresLocalizedDescription` and `testCaptureExceptionSameFingerprintAcrossLanguages`.
- **Delivery and failure:** `testHttpErrorRequeuesThenRetries` (500). `testServiceUnavailableRequeuesWithBackoff` (503: 5 s, then 10 s, capped at 300 s, reset on success). `testBadRequestDropsChunk` (400 and 413 are never resent). `testRetryClassification`. `testAFlushSaysWhatItSent`, `testAFailedSendKeepsTheEventsAndSaysWhy` and `testARefusedChunkIsDroppedAndCounted` check the flush result. `testMoreThanFiftyEventsGoInChunksTheServerAccepts` (70 events go as 50 + 20). `testConcurrentFlushSendsOnce` (10 callers, 1 send, at most 1 in flight).
- **Durability:** `testFlushKeepsTheBatchUntilThePostSucceeds` (on disk during the post). `testPushIsPersistedAfterDebounce` (real sleep of about 0.8 s, the slowest test). `testQueueSurvivesNewTrackerInstance` (a "new process" faked with a second instance and the same memory storage).
- **Crash capture:** `testCrashHandlerPersistsFatalEventAndChains` calls `handle(_:)` directly. It checks chaining, a synchronous persist, `fatal` with `crash: true`, grouping with numbers stripped, and that the "relaunch" sends it. `testCaptureCrashesFlagOff` only checks that start succeeds and the config default. It does **not** assert that the handler is absent.
- **Consent:** `testOptOutDropsQueueAndPersists` and `testOptInClearsOptOutAndNeedsStart`.
- **Session:** `testSessionStoresAVisitorId` and `testNoSessionEventWhenAsked`.
- **Isolation and device:** `testATrackerOfYourOwnNeverMixesWithShared` and `testDeviceInfoIsReadable` (non-empty only).
- **Observer:** names (`testNamesReadLikeSentences`, `testAnAcronymStaysOneWord`). Settings (`…EnvironmentThenThePlist`, `…EnvironmentWinsOverThePlist`, `testNoSiteIdOrNoBaseMeansOff`, `testTheKeyIsNeverReadFromThePlist`, `testTheTrackerIsQuietAboutItself`). Outcomes (`testEachOutcomeIsSentOnceWithItsStatusAndSource`, `testAFailureThenAPassIsOneFlakyPass`, `testOffSendsNothing`). Closing line (`testTheSummarySaysWhatHappened`, pure function; `testTheClosingLineCountsEarlierSends`). Failure (`testARefusedSendIsReported`, 502 keeps 1 pending).

**Where it runs.** Only `swift test` on a macOS host. `#if canImport(UIKit)` is false there, so `observeAppLifecycle`, `didEnterBackground` and `BackgroundTaskBox` are not even compiled under test. tvOS and watchOS are declared but never built. There is no CI workflow in this repo. iMoney's CI (`.github/workflows/ios.yml` in `imoney-ios-app`) uses the observer as the principal class of `iMoneyUITests`. Per iMoney's README, the 17 Nov run at `36d9edc` reported 9 of 9 journeys to Roboboro. That is the only real-bundle evidence, and it lives outside this repo.

---

## 3. Coverage matrix

Legend: **solid** means happy path plus the main error or edge cases are asserted. **shallow** means happy path only, a pure helper only, or simulated. **none** means no test.

| # | Flow / critical feature | Rating | Tests (file) | Notes |
|---|---|---|---|---|
| F1 | SPM install on 4 platforms, privacy manifest bundled | **none** | – | No build matrix and no resource check. |
| F2 | Start validation, consent, opt-out, idempotence | solid | `RoboboroKitTests.swift`: `testInitRejects*`, `testConsentCallbackCanBlockInit`, `testOptOutDropsQueueAndPersists` | Idempotent second start and start-after-destroy are not asserted. |
| F3 | Session start and visitor id | shallow | `testSessionStoresAVisitorId`, `ZeroThreeTests.testNoSessionEventWhenAsked` | The id being stable across launches (second start reuses it) is not asserted. |
| F4 | Capture exception and grouping | solid | `testCaptureExceptionSerializesAndFlushes`, `testFingerprintIgnoresLocalizedDescription`, `testCaptureExceptionSameFingerprintAcrossLanguages` | Struct errors (`type#code`) and the `trace` / `NSUnderlyingErrorKey` path are untested. |
| F5 | Capture message and levels | shallow | Used incidentally in most tests | Level is never asserted on the wire. |
| F6 | Breadcrumbs and screens | shallow | `testTrackScreenAddsBreadcrumbWithoutEvent` | The cap of 50, the last 20 per event, `data` payloads and calls before start are untested. |
| F7 | `identify` | **none** | – | User and email go out on every later event. This needs a privacy test. |
| F8 | Flush: single-flight, chunking, result, totals | solid | `testConcurrentFlushSendsOnce`, `ZeroThreeTests.*` | `totals` is only covered through the observer. Pushes during a flush (counted as pending) are untested. The timer-driven flush is never exercised (every test uses a 60 s interval). |
| F9 | Retry, backoff and drop | solid | `testHttpErrorRequeuesThenRetries`, `testServiceUnavailableRequeuesWithBackoff`, `testBadRequestDropsChunk`, `testRetryClassification`, `ZeroThreeTests.testARefusedChunkIsDroppedAndCounted` | 429 and network errors are only covered by classification, not end to end. Mixed chunk outcomes (chunk 1 OK, chunk 2 502), bad `apiBase` and the encode-failure branch are untested. |
| F10 | Durability and persistence | shallow | `testFlushKeepsTheBatchUntilThePostSucceeds`, `testPushIsPersistedAfterDebounce`, `testQueueSurvivesNewTrackerInstance` | The "new process" is a second object, not a new process. Kill mid-send, destroy during a send, the 100-event cap with eviction order, corrupt stored JSON and `RoboboroUserDefaultsStorage` are all untested. |
| F11 | Crash capture | shallow | `testCrashHandlerPersistsFatalEventAndChains`, `testCaptureCrashesFlagOff` | `handle(_:)` is called by hand. No real uncaught exception is raised in a child process. The lock-timeout path, "own tracker does not install", and "flag off does not install" are not asserted. |
| F12 | Opt-out and opt-in | solid | `testOptOutDropsQueueAndPersists`, `testOptInClearsOptOutAndNeedsStart` | Opt-out during an in-flight flush is untested. |
| F13 | Background flush with a UIKit background task | **none** | – | Not compiled under `swift test`. |
| F14 | Real `URLSession` transport | shallow | `testRedirectStaysOnHttpsAndTheSameHost` (pure function) | Headers, bearer omission, ephemeral cookies, the delegate actually refusing a redirect, timeout and a non-HTTP response are untested. |
| F15 | `destroy` | shallow | Used in teardown | Timer and observer removal and storage kept for the next start are not asserted. |
| F16 | Isolation between own and shared trackers | solid | `ZeroThreeTests.testATrackerOfYourOwnNeverMixesWithShared` | Crash capture staying with `shared` is not asserted. |
| F17 | Observer settings | solid | 5 settings tests in `RoboboroXCTestObserverTests.swift` | `ROBOBORO_RELEASE` and the name-prefix override are untested. |
| F18 | Readable names | solid | `testNamesReadLikeSentences`, `testAnAcronymStaysOneWord` | Example-based only, with no property test (digits, unicode, empty method). |
| F19 | Outcome capture | shallow | `testEachOutcomeIsSentOnceWithItsStatusAndSource`, `testAFailureThenAPassIsOneFlakyPass` | Simulated through nested `test.run()`, and issues are injected by hand. `XCTExpectFailure`, a failing `setUp`, a thrown error and the location trace are untested. |
| F20 | Observer delivery and closing line | shallow | `testTheClosingLineCountsEarlierSends`, `testARefusedSendIsReported`, `testTheSummarySaysWhatHappened` | The 30 s and 10 s ceilings (`waiting`) with a hanging transport are untested. The per-class flush only ran through a hand-made suite. |
| F21 | Real bundle loading and runner variants | **none** (in this repo) | – | Covered only indirectly by iMoney CI. Parallel testing, `-test-iterations`, `-retry-tests-on-failure` and Swift Testing (`@Test`, which the observer cannot see) are untested. |
| F22 | Wire contract with sublime-go | shallow | `testFingerprintMatchesJS` (1 vector), `testCaptureExceptionSerializesAndFlushes` (Swift decodes its own JSON) | No shared fixture with Go or TS. Server rules (`organisation_required`, 1–50, 24 flat `data` values) are not checked from the client side. |
| F23 | Version and changelog consistency | **none** | – | `RoboboroKitModule.version` is `"0.3.1"`, but nothing ties it to the tag. |

---

## 4. Gaps that matter

Items marked *suspected* come from reading the source. A failing test should confirm them before anyone calls them bugs.

1. **Process-level durability is never tested.** The README promises that "a kill mid-send loses nothing", that "an acknowledged batch is never sent twice", and that uncaught exceptions are sent on the next launch. The tests emulate a process with a second object sharing a `RoboboroMemoryStorage`. No test kills a process, relaunches it, or uses real `UserDefaults`.
2. ***Suspected* double send after `destroy()` during a flush.** `takeBatch` writes the in-flight batch to disk. If `destroy()` runs while the post is in flight, `acknowledge` calls `writePendingLocked`, which returns early because `destroyed && !optedOut`. So the batch the server accepted stays on disk and is sent again after the next `start`. No test covers this interleaving.
3. ***Suspected* silent loss at the cap.** `appendLocked` limits the queue to `100 − inFlight.count`. A long in-flight batch of 100 leaves no room, so new events (including a crash) are dropped without a counter. `requeueInFlight` keeps the newest 100, so old events go first. Neither is tested, and `RoboboroFlushResult` doesn't report evictions.
4. **The iOS lifecycle path has zero coverage.** The background flush, `beginBackgroundTask` and expiry are never compiled or run in tests.
5. **The real transport is untested.** Only the redirect predicate is tested, not the delegate wiring. There's nothing on the `Authorization` header being absent without a key, ephemeral cookies, the 10 s timeout, or a 3xx left unfollowed being treated as a failure (which status is retried).
6. **The wire contract isn't tied to the server.** The Go handler requires `site_id` and 1–50 events. It returns `400 organisation_required` when the scope needs a slug, and the kit then **drops** that batch permanently. It keeps at most 24 *flat* `data` values, so the kit's `.object` and `.array` `extra` values are silently discarded server-side. A single fingerprint vector is the only cross-language check. Go uses `strings.Fields` (Unicode spaces), Swift uses `\s+` after trimming, so the two should be compared on generated inputs.
7. **The observer is tested by simulation.** The nested `test.run()` triggers XCTest warnings. The real hierarchy (bundle → class suite → cases), retries, parallel runners and principal-class loading are never exercised in this repo. **Swift Testing results are invisible to an `XCTestObservation`**: if iMoney or any other host moves journeys to `@Test`, they stop being reported and nothing will notice.
8. **Timeouts and hangs.** `waiting(seconds:)` exists so a dead network never hangs a run, but no test uses a transport that never returns.
9. **Crash capture edge cases.** The lock held by another thread (the 0.5 s give-up) is untested, and so are "flag off means not installed" and "own tracker never installs". Neither is a real `NSException` raised in a child process.
10. **Privacy.** `identify` can attach an email to every event, and no test guards that. Nothing checks that the privacy manifest is in the built bundle.
11. **No CI, no sanitisers, no platform matrix.** The kit declares tvOS and watchOS, but nothing builds them. It uses locks and `@unchecked Sendable` throughout, but there is no Thread Sanitizer run.
12. **Timing-based tests.** `testPushIsPersistedAfterDebounce` sleeps on the wall clock (`persistDelay` + 0.3 s). The timer flush isn't testable because it is scheduled on the main run loop with a real `Timer`.

---

## 5. Stronger-test plan

### 5.1 Turn the dummy app into a flow harness

Replace the hand-driven `SampleJourneys` with four layers. Each one is cheap on its own, and together they cover every flow above.

**A. Seams.** These are small production changes the implementing agent makes. Today `now` is internal and the ID, timer and persist scheduling are hard-wired.
- `RoboboroEnvironment`, injected through an internal `init`, with:
  - `clock: () -> Date`
  - `ids: () -> String` (seeded in tests)
  - `scheduler` (a timer and a debounce; a manual scheduler in tests, so "advance 0.5 s" persists without sleeping)
  - `backgroundTasks` (a protocol over `UIApplication.begin/endBackgroundTask`, faked on macOS)
- This makes every tracker test deterministic and makes the lifecycle path testable on macOS.

**B. Scenario catalogue.** Add `Tests/Scenarios/Scenarios.swift`: one enum shared by every layer, each case driving the public API only.

| Id | Scenario | Flows |
|---|---|---|
| S01 | `startSendsSessionOnce` | F2, F3 |
| S02 | `exceptionThenFlush` | F4, F8 |
| S03 | `breadcrumbOverflow` (60 crumbs, then 1 event) | F6 |
| S04 | `identifyThenMessage` | F7, privacy |
| S05 | `seventyEventsTwoChunks` | F8 |
| S06 | `chunkOneOkChunkTwo502` | F9 |
| S07 | `scripted429Then202` | F9 |
| S08 | `networkDownThenUp` | F9 |
| S09 | `killMidSendThenRelaunch` | F10 |
| S10 | `destroyDuringFlight` | F10, F15 |
| S11 | `queueAtCapacity` (150 pushes, server down) | F10 |
| S12 | `corruptStore` | F10 |
| S13 | `uncaughtExceptionThenRelaunch` | F11 |
| S14 | `optOutDuringFlight` | F12 |
| S15 | `backgroundFlush` | F13 |
| S16 | `redirectOffHost` / `redirectToHttp` | F14 |
| S17 | `ownTrackerAndShared` | F16 |
| S18 | `observerRealBundle` (pass, fail, skip, retry, setUp failure, expected failure) | F19–F21 |
| S19 | `observerDeadNetwork` | F20 |

**C. Runnable hosts.** Two hosts run the catalogue:
1. **`RoboboroHarness` (macOS executable target in `Package.swift`).** It takes `--scenario S09 --suite <UserDefaults suite> --ingest http://127.0.0.1:<port>`. Tests launch it with `Process`, kill it (`SIGKILL`) at a mark printed to stdout, relaunch it and assert on what the mock ingest received. This is the only honest way to test S09 and S13.
2. **`RoboboroHarnessApp` (iOS host app via XcodeGen, under `Harness/`, plus a UI test bundle).**
   - The app reads `-scenario` from its launch arguments and shows the scenario state as accessibility labels, for example `pending=3`.
   - The UI tests drive S15 with `XCUIDevice.shared.press(.home)`, S09 with `app.terminate()` and relaunch, and S13 with a button that raises an `NSException`.
   - The UI test bundle uses `RoboboroXCTestObserver` as its principal class, with `ROBOBORO_API_BASE` pointing at the mock ingest. That makes S18 real: the harness's own results become the observer's test data.
   - A deliberately failing UI test goes behind a `ROBOBORO_HARNESS_EXPECT_FAIL` flag. The CI step asserts on the mock ingest's log, not on the exit code.

**D. Mock ingest that enforces the server's rules.** Add `Tests/Support/MockIngest` as a small Network.framework listener, or a script run in CI. It:
- rejects a missing `site_id` (400)
- rejects batches with 0 or more than 50 events (400)
- optionally requires `organisation_slug` (400 `organisation_required`)
- keeps only flat `data` and at most 24 keys, the same as `copyTrackerData`
- can be scripted per request with 202, 400, 413, 429, 502, a hang, or a 3xx to another host or to http
- writes every body as JSONL for the assertions.

### 5.2 Test cases by gap, prioritised

**P0: before RoboboroKit is relied on in the iMoney pitch or production**

| Gap | Test name | Layer |
|---|---|---|
| 1 | `testKillDuringPostResendsOnRelaunch`, `testAcknowledgedBatchIsNeverResentAfterRelaunch` | Harness CLI (subprocess plus `SIGKILL`) |
| 1, 9 | `testUncaughtNSExceptionInChildProcessIsSentOnNextLaunch` | Harness CLI |
| 2 | `testDestroyDuringFlightDoesNotResendAcknowledgedBatch` | Unit (`FakeTransport.onSend`) |
| 3 | `testQueueAtCapacityKeepsNewestAndCountsEvictions`, `testPushWhileHundredInFlightIsNotLostSilently` | Unit |
| 4 | `testBackgroundStartsAndEndsBackgroundTask`, `testBackgroundTaskEndsOnExpiry` | Unit with a fake `backgroundTasks` · iOS sim: `HarnessUITests.testBackgroundFlushDelivers` |
| 5 | `testURLSessionTransportSendsJSONAndBearerOnlyWithKey`, `testRedirectOffHostIsNotFollowedAndRetried`, `testRedirectToHttpIsRefused`, `testNoCookiesStored` | Integration against the mock ingest on loopback |
| 6 | `testGoldenBatchMatchesSharedFixture`, `testFingerprintVectorsMatchGo` (generated vectors), `testOrganisationRequiredIsSurfacedNotSilentlyDropped`, `testNestedExtraIsFlattenedOrRejected` | Contract (Swift side plus a Go test in sublime-go reading the same fixtures) |
| 7 | `testObserverInRealBundleReportsPassFailSkip`, `testRetryOnFailureIsOneFlakyRow` (`xcodebuild -retry-tests-on-failure`) | Harness UI bundle plus the mock ingest |
| 11 | CI workflow: `swift test` (macOS), `xcodebuild test` package scheme on an iOS simulator, `--sanitize=thread` | CI |

**P1**

| Gap | Test name |
|---|---|
| 8 | `testObserverDoesNotHangWhenTransportNeverReturns` (closing line says "not confirmed" within the ceiling), `testBundleStartGivesUpAfterTenSeconds` |
| 9 | `testCrashCaptureGivesUpWhenLockIsHeld`, `testCaptureCrashesOffDoesNotInstallHandler`, `testOwnTrackerNeverInstallsCrashHandler` |
| 10 | `testIdentifyEmailIsOnlySentWhenHostOptsIn` (or at least that it is asserted and documented), `testPrivacyManifestIsBundled` |
| F3 | `testVisitorIdIsStableAcrossStarts` |
| F6 | `testBreadcrumbsCapAtFiftyAndEventsCarryLastTwenty`, `testBreadcrumbBeforeStartIsIgnored` |
| F9 | `testChunkTwoFailureRequeuesOnlyUnsentChunks`, `test429RequeuesWithBackoff`, `testNetworkErrorRequeues`, `testBadApiBaseReportsFailure` |
| F10 | `testCorruptPendingStoreIsDiscardedAndOverwritten`, `testUserDefaultsSuiteRoundTrip` |
| F12 | `testOptOutDuringFlightClearsStorageAfterResponse` |
| 7 | `testSwiftTestingResultsAreReportedOrWarned`. Decide: add a Swift Testing reporter, or have the observer print a warning when the bundle contains `@Test` suites. |
| 12 | Replace the wall-clock sleep in `testPushIsPersistedAfterDebounce` with the manual scheduler. Add `testTimerFlushFiresAtInterval`. |

**P2**

- **Property-based tests.** Swift has no built-in runner, so use a seeded generator loop with no new dependency:
  - `propFingerprintIsNormalisationInvariant`
  - `propJSONRoundTrips` (`RoboboroJSON` encode/decode)
  - `propReadableNameAlwaysHasPrefixAndSuite`
  - `propDeliveryAccounting`: for random push and status scripts, sent + dropped + pending + evicted == pushed, and the queue is never above 100
- **Performance baselines.** Use `measure` for `testPerfEncodeFiftyEventBatch`, `testPerfPushThousandEvents` and `testPerfPersistHundredEvents`. Record the baselines on the CI machine. No target figures are set here.
- **Build matrix.** tvOS and watchOS build-only. Swift 6 strict-concurrency build.
- **Consistency.** `testModuleVersionMatchesChangelogHead`, and a parity test against `p1-roboboro-tracker`'s fingerprint vectors.
- **Snapshots and accessibility.** The kit has no UI, so this applies only to the harness app: accessibility identifiers on scenario controls, so the UI tests are stable. Use **golden-payload snapshots** (normalised JSON) in place of visual snapshots.

### 5.3 Example code for three P0s

**(a) Destroy during a flush must not resend.** Unit test, uses the existing `FakeTransport`.

```swift
func testDestroyDuringFlightDoesNotResendAcknowledgedBatch() async throws {
    let first = RoboboroTracker()
    _ = await first.start(config: config(), storage: storage, transport: transport)
    first.captureMessage("once")
    transport.onSend = { [first] in first.destroy() }   // destroy while the post is in flight
    await first.flush()                                  // server answers 202
    XCTAssertEqual(try transport.batches().flatMap(\.batch).filter { $0.message == "once" }.count, 1)

    // Next launch, same storage: nothing already acknowledged may go again.
    transport.onSend = nil
    let second = RoboboroTracker()
    _ = await second.start(config: config(), storage: storage, transport: transport)
    await second.flush()
    let sends = try transport.batches().flatMap(\.batch).filter { $0.message == "once" }
    XCTAssertEqual(sends.count, 1, "acknowledged batch was resent after relaunch")
    second.destroy()
}
```

**(b) Shared golden contract fixture.** Swift side. The same file is read by a Go test in sublime-go that posts it to `IngestTracker` and expects 2xx.

```swift
func testGoldenBatchMatchesSharedFixture() async throws {
    // Needs the seams: fixed clock and seeded ids.
    let tracker = RoboboroTracker(environment: .fixed(clock: Date(timeIntervalSince1970: 1_700_000_000),
                                                      ids: .sequence(prefix: "rb")))
    _ = await tracker.start(config: config(), storage: storage, transport: transport)
    tracker.addBreadcrumb(category: "sync", message: "knowledge_start")
    tracker.captureException(NSError(domain: "P1314", code: 43), extra: ["phase": "load_brain"])
    tracker.captureTestResult(.init(testName: "iOS › Home › Opens", status: .PASSED, runId: "run-1"))
    await tracker.flush()

    let body = try XCTUnwrap(transport.calls.first).body
    let fixture = try Data(contentsOf: Bundle.module.url(forResource: "ingest-batch-v1", withExtension: "json")!)
    XCTAssertEqual(try canonical(body), try canonical(fixture))        // sorted keys, same values
    // Client-side mirror of the server's rules (tracker.go):
    let batch = try JSONDecoder().decode(RoboboroBatch.self, from: body)
    XCTAssertFalse(batch.siteId.isEmpty)
    XCTAssertTrue((1...50).contains(batch.batch.count))
    XCTAssertNotNil(batch.organisationSlug)
    for event in batch.batch {
        XCTAssertLessThanOrEqual(event.data?.count ?? 0, 24)
        XCTAssertTrue(event.data?.values.allSatisfy(\.isFlat) ?? true, "server drops nested data")
    }
}
```

**(c) Real crash, real relaunch.** The harness CLI runs in a child process and posts to the loopback mock ingest.

```swift
func testUncaughtNSExceptionInChildProcessIsSentOnNextLaunch() throws {
    let ingest = try MockIngest.start()                  // records JSONL, answers 202
    let suite = "roboboro.harness.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite); ingest.stop() }

    // Launch 1: start, raise an uncaught NSException. Ingest is unreachable, so nothing is sent.
    let crash = try Harness.run(["--scenario", "S13-crash", "--suite", suite, "--ingest", "http://127.0.0.1:9"])
    XCTAssertNotEqual(crash.terminationStatus, 0)        // the process really died
    XCTAssertTrue(ingest.events.isEmpty)

    // Launch 2: plain start + flush against the mock.
    let relaunch = try Harness.run(["--scenario", "S00-flush", "--suite", suite, "--ingest", ingest.url])
    XCTAssertEqual(relaunch.terminationStatus, 0)
    let fatal = try XCTUnwrap(ingest.events.first { $0.level == .fatal })
    XCTAssertEqual(fatal.data?["crash"], .bool(true))
    XCTAssertEqual(fatal.data?["exception_name"], .string("NSInvalidArgumentException"))
    XCTAssertEqual(ingest.events.filter { $0.level == .fatal }.count, 1, "sent once, not on every launch")
}
```

### 5.4 CI matrix to add to `roboborokit`

There is no workflow today. Add `.github/workflows/ci.yml` on macOS runners, triggered on push, pull request and nightly:

| Job | Command | When |
|---|---|---|
| unit-macos | `swift test` | every push |
| unit-tsan | `swift test --sanitize=thread` | every push |
| unit-ios-sim | `xcodebuild test -scheme RoboboroKit-Package -destination 'platform=iOS Simulator,…'` | every push |
| build-tv-watch | `xcodebuild build` for tvOS and watchOS simulators | every push |
| harness-cli | Process-level scenarios (S09, S10, S13) against the mock ingest | every push |
| harness-ui | `xcodebuild test` on `Harness/` with the observer pointed at the mock ingest. Assert on the JSONL. | nightly and release tags |
| contract | Regenerate fixtures, then fail on diff. A matching Go test in sublime-go reads `Tests/Fixtures/*.json`. | every push, in both repos |
| consumer | Build iMoney against the PR's commit (local path override). Run `iMoneyUITests` with the observer pointed at the mock. | release tags |

---

## 6. What I did not do

- I did not change, commit or push anything in `roboborokit`, `imoney`, `p1-roboboro-tracker` or sublime-go. The test run used a throwaway export in `/tmp` on the Mac, and I deleted it afterwards.
- I did not run the iOS simulator, the iMoney suites or the Go tests. The iMoney CI result above is quoted from iMoney's README, not re-run.
- No secrets were read or printed. Where the site id appeared, it was redacted.
- The *suspected* items in section 4 (gaps 2 and 3) are unconfirmed until the P0 tests are written and run.
