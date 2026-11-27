import Foundation

public enum SetupStep: Int, CaseIterable, Codable, Sendable {
    case key, gear, recipe, permissions, taste, orderUp, complete

    public var title: String {
        switch self {
        case .key: "Key"
        case .gear: "Your gear"
        case .recipe: "Recipe"
        case .permissions: "Permissions"
        case .taste: "Taste test"
        case .orderUp, .complete: "Order up"
        }
    }
}

public enum TasteResult: String, Codable, Sendable {
    case works, notWorking, parked, needsCheck

    public var title: String {
        switch self {
        case .works: "Works"
        case .notWorking: "On, not working"
        case .parked: "Parked"
        case .needsCheck: "Needs a check"
        }
    }
}

public enum TasteMode: Sendable { case setup, afterUpdate }

public struct TasteFinding: Codable, Equatable, Sendable {
    public var result: TasteResult
    public var grants: Set<Permission>
    public var detail: String

    public init(_ result: TasteResult, grants: Set<Permission> = [], detail: String) {
        self.result = result
        self.grants = grants
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey { case result, grants, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        result = (try? c.decodeIfPresent(TasteResult.self, forKey: .result)) ?? .needsCheck
        grants = (try? c.decodeIfPresent(Set<Permission>.self, forKey: .grants)) ?? []
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? ""
    }
}

@MainActor
public protocol TasteProbing {
    /// Only use operations that cannot show a system prompt in afterUpdate mode.
    func tryFeature(_ feature: Feature, mode: TasteMode) async -> TasteFinding
}

public protocol PermissionResetting: Sendable {
    func reset(_ permission: Permission) async -> Bool
}

public struct SetupProgress: Codable, Sendable {
    public var step: SetupStep
    public var scan: GearScan?
    public var accepted: Set<String> = []
    public var recipeName: String?
    public var selected: Set<Feature> = []
    public var skipped: Set<Permission> = []
    /// Grants being asked again, also kept across Input Monitoring's relaunch.
    public var askingAgain: Permission?
    public var permissionFlow: PermissionFlow?
    public var grantedByTest: Set<Permission> = []
    public var resetAttempts: [Permission: Int] = [:]
    public var parked: [Feature: TasteFinding] = [:]
    public var findings: [Feature: TasteFinding] = [:]
    public var build: String?
    public var updateOKUntil: Date?
    /// The check after an update ran out of time. Features started as before.
    public var updateCheckIncomplete = false
    public var renewal: Set<Feature> = []
    public var renewalStarted = false
    public var renewedGrants: Set<Permission> = []

    public init(step: SetupStep = .gear) { self.step = step }

    private enum CodingKeys: String, CodingKey {
        case step, scan, accepted, recipeName, selected, skipped, askingAgain, grantedByTest, resetAttempts
        case permissionFlow, parked, findings, build, updateOKUntil, updateCheckIncomplete, renewal, renewalStarted, renewedGrants
    }

    /// Every field is optional on disk, so a file from an older or newer build keeps what it can read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        step = read(.step, .complete)
        scan = read(.scan, nil)
        accepted = read(.accepted, [])
        recipeName = read(.recipeName, nil)
        selected = read(.selected, [])
        skipped = read(.skipped, [])
        askingAgain = read(.askingAgain, nil)
        permissionFlow = read(.permissionFlow, nil)
        grantedByTest = read(.grantedByTest, [])
        resetAttempts = read(.resetAttempts, [:])
        parked = read(.parked, [:])
        findings = read(.findings, [:])
        build = read(.build, nil)
        updateOKUntil = read(.updateOKUntil, nil)
        updateCheckIncomplete = read(.updateCheckIncomplete, false)
        renewal = read(.renewal, [])
        renewalStarted = read(.renewalStarted, false)
        renewedGrants = read(.renewedGrants, [])
    }

    /// The state after the silent check. It only marks features for renewal: it never starts a grant, so
    /// `renewalStarted` is always false and nothing is being asked for.
    public func applyingAudit(_ audit: UpdateAudit, build: String, now: Date) -> SetupProgress {
        var next = self
        next.findings.merge(audit.findings) { _, current in current }
        next.parked.merge(audit.park) { _, current in current }
        next.build = build
        next.updateCheckIncomplete = !audit.finished
        next.updateOKUntil = audit.allWork && next.parked.isEmpty ? now.addingTimeInterval(86_400) : nil
        if !audit.park.isEmpty { next.renewal.formUnion(audit.park.keys) }
        next.renewalStarted = false
        next.askingAgain = nil
        next.skipped = []
        next.renewedGrants = []
        next.grantedByTest = []
        next.resetAttempts = [:]
        return next
    }

    /// Features that may run. Parked features keep their settings but stay off. The check after an update never holds
    /// working features back: they run while it reads, and it parks only what definitely stopped working.
    public func allowed(_ enabled: Set<Feature>) -> Set<Feature> {
        guard step == .complete || step == .orderUp else { return [] }
        return enabled.subtracting(parked.keys)
    }

    /// A grant that reads as on but whose feature failed its test, and has not been renewed in this pass.
    public func isStale(_ grant: Permission, targets: Set<Feature>) -> Bool {
        step == .complete && !renewedGrants.contains(grant)
            && targets.contains { parked[$0]?.result == .notWorking && parked[$0]?.grants.contains(grant) == true }
    }

    /// The next grant to ask for: one being asked again, else the first in order that is off (or stale) and whose
    /// features are not waiting on a skipped grant.
    public func currentGrant(order: [Permission], requirements: [Feature: Set<Permission>], targets: Set<Feature>,
                             isGranted: (Permission) -> Bool) -> Permission? {
        if let retry = askingAgain, !skipped.contains(retry) { return retry }
        return order.first { permission in
            guard !skipped.contains(permission), !isGranted(permission) || isStale(permission, targets: targets) else { return false }
            return requirements.values.contains { $0.contains(permission) && $0.isDisjoint(with: skipped) }
        }
    }

    public mutating func reserveReset(_ permission: Permission) -> Bool {
        let used = resetAttempts[permission, default: 0]
        guard permission.resetService != nil, used < 2 else { return false }
        resetAttempts[permission] = used + 1
        return true
    }
}

public struct TasteTest {
    public let checker: any PermissionChecking
    public let probe: any TasteProbing
    public let resetter: any PermissionResetting

    public init(checker: any PermissionChecking, probe: any TasteProbing, resetter: any PermissionResetting) {
        self.checker = checker
        self.probe = probe
        self.resetter = resetter
    }

    public static func requirements(for feature: Feature, audioCapture: Bool, mic: Bool, clipboardPrivacy: Bool) -> Set<Permission> {
        switch feature {
        case .audio: audioCapture ? [.systemAudio] : []
        case .microphone: mic ? [.microphone, .micDriver] : []
        case .clipboard: clipboardPrivacy ? [.paste] : []
        case .display: []  // Camera-assisted matching asks when the user starts a match.
        default: Set(feature.requires)
        }
    }

    public static func affected(by grant: Permission, in requirements: [Feature: Set<Permission>]) -> Set<Feature> {
        Set(requirements.compactMap { $0.value.contains(grant) ? $0.key : nil })
    }

    public func readGrants() -> [Permission: PermissionStatus] {
        Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, checker.status($0)) })
    }

    @MainActor
    /// One check never holds the Taste test longer than this. A check that doesn't answer is "could not check".
    public static let checkDeadline: Duration = .seconds(8)

    /// The probe, raced against a deadline. A probe that never returns is left behind, not awaited.
    @MainActor
    public func check(_ feature: Feature, mode: TasteMode, deadline: Duration = TasteTest.checkDeadline) async -> TasteFinding {
        let gate = ProbeGate()
        let probe = self.probe
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            gate.continuation = done
            gate.work = Task { @MainActor in
                let finding = await probe.tryFeature(feature, mode: mode)
                gate.finish(finding)
            }
            gate.timer = Task { @MainActor in
                try? await Task.sleep(for: deadline)
                gate.finish(nil)
            }
        }
        return gate.result ?? TasteFinding(.needsCheck, detail: "Could not check \(feature.shortTitle): it didn’t answer in time.")
    }

    public func tryFeature(_ feature: Feature, grants: Set<Permission>, skipped: Set<Permission>, mode: TasteMode) async -> TasteFinding {
        let parked = grants.intersection(skipped)
        if !parked.isEmpty {
            return TasteFinding(.parked, grants: parked, detail: "Waiting for " + Self.names(parked) + ". Your settings are kept.")
        }
        let states = grants.map { ($0, checker.status($0)) }
        if mode == .afterUpdate {
            // Park only on a definite failure. A grant macOS can't report, or one that still asks each time, is not one.
            let blocked = Set(states.compactMap { Self.definitelyBlocked($0, $1) ? $0 : nil })
            if !blocked.isEmpty {
                return TasteFinding(.notWorking, grants: blocked, detail: Self.names(blocked) + " is off for Whoprrr. Your settings are kept.")
            }
            return await check(feature, mode: mode)
        }
        let missing = Set(states.compactMap { grant, state in state == .granted || state == .unknown ? nil : grant })
        if !missing.isEmpty {
            return TasteFinding(.parked, grants: missing, detail: "Waiting for " + Self.names(missing) + ". Your settings are kept.")
        }
        return await check(feature, mode: mode)
    }

    /// True only when the grant certainly blocks the feature. Unknown never counts; "ask each time" (Paste) never counts;
    /// the Whoprrr Mic driver is a device, not a grant, so a missing device never parks after an update.
    public static func definitelyBlocked(_ grant: Permission, _ status: PermissionStatus) -> Bool {
        switch status {
        case .denied: grant != .micDriver
        case .notDetermined: grant == .accessibility || grant == .inputMonitoring
        case .granted, .unknown: false
        }
    }

    /// A finding from the after-update check parks its feature only when it names a grant and the feature failed.
    public static func parksAfterUpdate(_ finding: TasteFinding) -> Bool {
        (finding.result == .notWorking || finding.result == .parked) && !finding.grants.isEmpty
    }

    /// The silent check after an update. Reads states and runs probes that cannot prompt or post input, one feature at a
    /// time, and gives up at the deadline: features it did not reach are reported, never parked.
    @MainActor
    public func auditAfterUpdate(_ features: [Feature], needs: [Feature: Set<Permission>], deadline: Duration) async -> UpdateAudit {
        let gate = AuditGate()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            gate.continuation = done
            gate.work = Task { @MainActor in
                for feature in features {
                    let finding = await tryFeature(feature, grants: needs[feature] ?? [], skipped: [], mode: .afterUpdate)
                    guard !gate.finished else { return }
                    gate.findings[feature] = finding
                }
                gate.completed = true
                gate.finish()
            }
            gate.timer = Task { @MainActor in
                try? await Task.sleep(for: deadline)
                gate.finish()
            }
        }
        var findings = gate.findings
        for feature in features where findings[feature] == nil {
            findings[feature] = TasteFinding(.needsCheck, detail: "The check after the update could not finish. \(feature.shortTitle) started as before.")
        }
        let park = findings.filter { Self.parksAfterUpdate($0.value) }
        return UpdateAudit(findings: findings, park: park, finished: gate.completed)
    }

    public func reset(_ permission: Permission) async -> Bool { await resetter.reset(permission) }

    public static func names(_ grants: Set<Permission>) -> String {
        Permission.setupOrder.filter(grants.contains).map(\.title).joined(separator: ", ")
    }
}

public struct UpdateAudit: Equatable, Sendable {
    public var findings: [Feature: TasteFinding]
    public var park: [Feature: TasteFinding]
    public var finished: Bool

    public var allWork: Bool { finished && findings.values.allSatisfy { $0.result == .works } }
}

@MainActor
private final class AuditGate {
    var continuation: CheckedContinuation<Void, Never>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?
    var findings: [Feature: TasteFinding] = [:]
    var completed = false
    var finished = false

    func finish() {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        work?.cancel()
        continuation?.resume()
        continuation = nil
    }
}

/// Renew after an update starts System Settings, the guide card and any macOS prompt, so it must be a deliberate press:
/// in Whoprrr's own focused window, after the window has been on screen long enough to read.
public enum RenewalStart {
    public static let settle: TimeInterval = 1.0

    public static func allowed(shownAt: Date?, now: Date, windowIsKey: Bool) -> Bool {
        guard windowIsKey else { return false }
        guard let shownAt else { return true }
        return now.timeIntervalSince(shownAt) >= settle
    }
}

@MainActor
private final class ProbeGate {
    var continuation: CheckedContinuation<Void, Never>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?
    var result: TasteFinding?
    private var finished = false

    func finish(_ finding: TasteFinding?) {
        guard !finished else { return }
        finished = true
        result = finding
        timer?.cancel()
        if finding == nil { work?.cancel() }
        continuation?.resume()
        continuation = nil
    }
}
