# Changelog

## Unreleased

- A batch is written to the pending buffer before the post, so a kill mid-flight retries next launch.
- Opt-out drops a batch already taken off the queue and stops the flush timer.
- The default session is ephemeral, sends no cookies, and refuses a redirect onto another host or onto http.
- Session start stores a stable `visitor_id` (`rbv_…`) for this install. It is not an account or an email.
- Backgrounding asks for a few seconds to finish the flush.

## 0.1.0

- Native iOS / Swift port of `p1-roboboro-tracker/native`: exceptions, messages,
  breadcrumbs, screen events, and session start.
- Same-origin-or-BFF ingest: `POST {apiBase}/ingest` with optional
  `Authorization: Bearer` (`P1_API_KEY`).
- Durable pending buffer (UserDefaults), single-flight flush, HTTP status
  treated as failure (non-2xx requeues).
- Opt-out persists across launches. No default `apiBase` — the host must set it.
