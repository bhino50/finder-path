import Foundation

/// Stable, total ordering for duplicate FinderPath processes.
///
/// An already-running instance outranks a newer launch, then release identity
/// and PID break an exact launch-time tie. Age must come first: a running
/// development build cannot rerun election merely because a release build
/// appears later, so allowing the newcomer to win would leave both active.
/// Treating missing launch metadata as oldest is the conservative single-
/// instance choice and keeps the ordering total and transitive.
struct FinderPathInstanceIdentity: Equatable {
    static let releaseBundleIdentifier = "io.github.bhino50.FinderPath"
    static let developmentBundleIdentifier = "io.github.bhino50.FinderPathDev"
    static let knownBundleIdentifiers: Set<String> = [
        releaseBundleIdentifier,
        developmentBundleIdentifier,
    ]

    let bundleIdentifier: String?
    let launchDate: Date?
    let processIdentifier: Int32

    /// Process Manager occasionally omits launchDate. That ambiguity has
    /// opposite safe meanings by role: an existing contender is conservatively
    /// old, but this process is definitely the newcomer. Normalize the current
    /// process at construction so a missing value can never make it displace an
    /// established instance.
    static func current(
        bundleIdentifier: String?,
        observedLaunchDate: Date?,
        processIdentifier: Int32,
        fallbackLaunchDate: Date = Date()
    ) -> Self {
        Self(
            bundleIdentifier: bundleIdentifier,
            launchDate: observedLaunchDate ?? fallbackLaunchDate,
            processIdentifier: processIdentifier
        )
    }

    static func isPreferred(_ lhs: Self, over rhs: Self) -> Bool {
        let lhsLaunchDate = lhs.launchDate ?? .distantPast
        let rhsLaunchDate = rhs.launchDate ?? .distantPast
        if lhsLaunchDate != rhsLaunchDate { return lhsLaunchDate < rhsLaunchDate }

        let lhsPriority = priority(of: lhs.bundleIdentifier)
        let rhsPriority = priority(of: rhs.bundleIdentifier)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        return lhs.processIdentifier < rhs.processIdentifier
    }

    private static func priority(of bundleIdentifier: String?) -> Int {
        switch bundleIdentifier {
        case releaseBundleIdentifier: 0
        case developmentBundleIdentifier: 1
        default: 2
        }
    }
}

/// Pure refresh bookkeeping for the Finder path model.
///
/// Beginning a refresh deliberately clears the previously actionable result.
/// That prevents menu actions from operating on a folder that Finder stopped
/// showing while the next Apple Event is still in flight. A monotonically
/// increasing generation also keeps slower, older queries from winning races.
struct FinderPathRefreshState: Equatable {
    private(set) var generation = 0
    private(set) var result: FinderPathQueryResult?
    private(set) var isRefreshing = false

    var currentPath: String { result?.path ?? "" }

    @discardableResult
    mutating func begin() -> Int {
        generation += 1
        result = nil
        isRefreshing = true
        return generation
    }

    @discardableResult
    mutating func complete(_ result: FinderPathQueryResult, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        self.result = result
        isRefreshing = false
        return true
    }
}
