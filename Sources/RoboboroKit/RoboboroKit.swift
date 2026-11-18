/// RoboboroKit — native iOS / Swift port of Mathematica **p1-roboboro-tracker**
/// (`native` adapter).
///
/// Functional monitoring: exceptions, messages, breadcrumbs, and screen
/// events. Wire protocol is `POST {apiBase}/ingest` — the same payload the
/// JS web / RN / Playwright trackers send.
///
/// Related JS package: `p1-roboboro-tracker`.
///
/// ```swift
/// import RoboboroKit
///
/// Task {
///   _ = await initRoboboroTracker(config: RoboboroConfig(
///     siteId: "p1-314-ios",
///     apiBase: "https://www.principia1.com/api/v1/roboboro",
///     organisationSlug: "principia-one"
///   ))
///   RoboboroTracker.shared.trackScreen("Ask")
/// }
/// ```
///
/// Do **not** put `P1_API_KEY` in the app binary unless you are talking
/// straight to sublime-go. Prefer a Next.js BFF that attaches the key.
public enum RoboboroKitModule {
    public static let version = "0.3.2"
}
