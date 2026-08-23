# Changelog

## 0.1.0

- Native iOS / Swift port of `p1-roboboro-tracker/native`: exceptions, messages,
  breadcrumbs, screen events, and session start.
- Same-origin-or-BFF ingest: `POST {apiBase}/ingest` with optional
  `Authorization: Bearer` (`P1_API_KEY`).
- Durable pending buffer (UserDefaults), single-flight flush, HTTP status
  treated as failure (non-2xx requeues).
- Opt-out persists across launches. No default `apiBase` — the host must set it.
