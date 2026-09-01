import Foundation

/// Buffers `finderpath://` URLs that arrive before the app is ready to act on
/// them.
///
/// AppKit delivers a launch URL while `finishLaunching` is still running —
/// after `applicationWillFinishLaunching` but before
/// `applicationDidFinishLaunching` returns. FinderPath only wires up the
/// preference defaults, the status item, and `FinderPathActionRouter`'s
/// callbacks inside `applicationDidFinishLaunching`, so a URL that *launches*
/// the app arrives too early to be handled: `allowExternalLaunchURLs` would
/// still read its pre-registration value and `onOpenConnectWindow` would still
/// be nil.
///
/// So the delegate buffers early URLs here and replays them once the app is
/// fully built. Handling them in place instead would silently discard both
/// gated actions and no-op `connect`, which is exactly the bug this type
/// exists to prevent.
struct PendingURLQueue {
    /// Upper bound on URLs held while launching. A stuck or hostile caller can
    /// deliver URLs faster than the app finishes launching, and replaying an
    /// unbounded backlog would stack one modal alert per failure.
    static let capacity = 16

    private(set) var buffered: [URL] = []

    /// False until `drain()` runs, i.e. until the router and preferences exist.
    private(set) var isReady = false

    /// Records `incoming` and returns the URLs to handle right now: a bounded
    /// batch once the app is ready, nothing while it is still launching.
    mutating func accept(_ incoming: [URL]) -> [URL] {
        guard !isReady else { return Array(incoming.prefix(Self.capacity)) }
        // Keep the earliest URLs: the one that launched the app is the one the
        // user actually asked for.
        for url in incoming where buffered.count < Self.capacity {
            buffered.append(url)
        }
        return []
    }

    /// Marks the app ready and hands back everything buffered so far, in
    /// arrival order. Subsequent calls return nothing, so a replay cannot run
    /// twice.
    mutating func drain() -> [URL] {
        isReady = true
        let queued = buffered
        buffered = []
        return queued
    }
}
