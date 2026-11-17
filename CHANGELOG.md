# Changelog

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
