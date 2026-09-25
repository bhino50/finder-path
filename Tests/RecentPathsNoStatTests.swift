import Darwin
import Foundation

/// Recent Paths and the compact path header run on the main actor while the
/// menu is built. A saved folder can sit on a network volume that no longer
/// answers, so this code must treat paths as strings and never ask the
/// filesystem about them. Tests/Support/MetadataProbeCounter.c counts every
/// metadata call on a marker path; script/test_logic.sh injects it.
@main
struct RecentPathsNoStatTests {
    private typealias ProbeCounter = @convention(c) () -> Int

    static func main() {
        var failures = 0
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            if !condition() {
                failures += 1
                print("FAIL: \(message)")
            }
        }

        // RTLD_DEFAULT is a C macro Swift cannot import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fp_metadata_probe_count") else {
            print("FAIL: metadata probe counter is not loaded; run with DYLD_INSERT_LIBRARIES")
            exit(1)
        }
        let probeCount = unsafeBitCast(symbol, to: ProbeCounter.self)
        func probes(_ body: () -> Void) -> Int {
            let before = probeCount()
            body()
            return probeCount() - before
        }

        let marker = "/Volumes/FinderPathNoStatProbe"

        // Positive controls: without them every zero below could pass because
        // the interposer silently failed to load or stopped seeing Foundation.
        expect(
            probes { var info = stat(); _ = lstat(marker + "/direct", &info) } == 1,
            "the interposer counts a direct lstat of a marker path"
        )
        expect(
            probes { _ = URL(fileURLWithPath: marker + "/control") } > 0,
            "the interposer sees the lstat Foundation performs for an unhinted file URL"
        )

        let visitDate = Date(timeIntervalSinceReferenceDate: 0)
        // Alternating parents force the menu's shared-leaf disambiguation branch.
        let saved = (0..<RecentPathsLogic.limit).map { index in
            RecentPath(path: "\(marker)/\(index % 2 == 0 ? "api" : "web")\(index / 2)/src", lastVisited: visitDate)
        }
        let data = RecentPathsLogic.encode(saved)
        var decoded: [RecentPath] = []
        expect(probes { decoded = RecentPathsLogic.decode(data) } == 0, "loading history never probes saved paths")
        expect(decoded == saved, "loading history keeps every saved entry unchanged")

        var titles: [String] = []
        expect(probes { titles = RecentPathsLogic.menuTitles(for: decoded) } == 0, "building menu titles never probes saved paths")
        expect(titles.first == "api0/src", "clashing leaves still gain their parent folder")

        var recorded: [RecentPath] = []
        expect(
            probes { recorded = RecentPathsLogic.recording(marker + "/new/", into: decoded, at: visitDate) } == 0,
            "recording a folder never probes the new or saved paths"
        )
        expect(recorded.first?.path == marker + "/new", "recording still strips the Finder trailing slash")

        // Registration-domain defaults stay in memory, so nothing is written
        // to any preferences file.
        UserDefaults.standard.register(defaults: [FinderPathPreferences.pathDisplayStyleKey: "compact"])
        for folder in [marker + "/team/project", marker + "/team/project/"] {
            var header = ""
            expect(
                probes { header = FinderPathPreferences.displayPath(for: folder) } == 0,
                "the compact path header never probes \(folder)"
            )
            expect(header == ".../team/project", "the compact path header keeps its last two components")
        }

        if failures > 0 {
            print("\(failures) of \(assertions) RecentPaths no-stat assertions failed")
            exit(1)
        }
        print("\(assertions) RecentPaths no-stat assertions passed")
    }
}
