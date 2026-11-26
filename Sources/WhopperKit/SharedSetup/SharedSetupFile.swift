import Foundation

/// A shared setup as a file that can be sent from person to person: `{"fileVersion":1,"madeBy":"…","setup":{…}}`.
/// `madeBy` is opaque to this code (it will be a key fingerprint later). Opening a file always runs the checker, and nothing is
/// handed back unless it passes. The file is not registered with the system in this version.
public enum SharedSetupFile {
    public static let fileExtension = "whoprrr-setup"
    public static let fileVersion = 1
    /// The document's own limit plus room for the wrapper.
    public static let maxFileBytes = SharedSetupTable.maxBytes + 1024
    public static let madeByMax = 200

    public enum Problem: Error, Equatable, Sendable {
        /// Not a Whoprrr setup file, or damaged.
        case unreadable
        /// Written by a newer Whoprrr.
        case newerFile(Int)
        /// Bigger than a file can be.
        case tooBig
        /// The setup breaks a limit.
        case violations([SharedSetupViolation])

        /// One plain sentence for the person.
        public var message: String {
            switch self {
            case .unreadable: return "This file is not a shared setup that Whoprrr can read."
            case .newerFile: return "This file was made with a newer Whoprrr. Update Whoprrr to open it."
            case .tooBig: return "This file is too big to be a shared setup."
            case .violations(let v): return v.first?.message ?? "This setup breaks Whoprrr’s limits."
            }
        }
    }

    /// What opening a file found.
    public struct Opened: Equatable, Sendable {
        /// The setup, only when it passed every check.
        public var setup: SharedSetup?
        public var madeBy: String?
        public var report: SharedSetupReport
        public var problem: Problem?
    }

    /// The bytes of a file for this setup. Refused (with the violations) when the setup breaks a limit.
    public static func encode(_ setup: SharedSetup, madeBy: String) -> Result<Data, Problem> {
        let report = SharedSetupLimits.check(setup)
        guard report.ok else { return .failure(.violations(report.violations)) }
        guard madeBy.utf16.count <= madeByMax, !madeBy.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return .failure(.unreadable) }
        let file: JSONValue = .object(["fileVersion": .int(fileVersion), "madeBy": .string(madeBy), "setup": setup.json])
        let data = file.encoded()
        return data.count <= maxFileBytes ? .success(data) : .failure(.tooBig)
    }

    /// Reads a file. The checker always runs, on the setup as it is written in the file, so a hand-edited file is caught.
    public static func decode(_ data: Data) -> Opened {
        func fail(_ p: Problem, _ r: SharedSetupReport = SharedSetupReport()) -> Opened { Opened(setup: nil, madeBy: nil, report: r, problem: p) }
        guard data.count <= maxFileBytes else { return fail(.tooBig) }
        guard let v = JSONValue.parse(data), let o = v.object else { return fail(.unreadable) }
        if let n = o["fileVersion"]?.integer, n > fileVersion { return fail(.newerFile(n)) }
        guard o["fileVersion"]?.integer == fileVersion, Set(o.keys) == ["fileVersion", "madeBy", "setup"],
              let madeBy = o["madeBy"]?.string, madeBy.utf16.count <= madeByMax, let doc = o["setup"] else { return fail(.unreadable) }
        let report = SharedSetupLimits.check(value: doc)
        guard report.ok, let setup = SharedSetup(json: doc) else {
            return Opened(setup: nil, madeBy: madeBy, report: report, problem: report.ok ? .unreadable : .violations(report.violations))
        }
        return Opened(setup: setup, madeBy: madeBy, report: report, problem: nil)
    }
}
