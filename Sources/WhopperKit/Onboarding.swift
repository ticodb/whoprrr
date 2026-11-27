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
    public var grantedByTest: Set<Permission> = []
    public var resetAttempts: [Permission: Int] = [:]
    public var parked: [Feature: TasteFinding] = [:]
    public var findings: [Feature: TasteFinding] = [:]
    public var build: String?
    public var updateOKUntil: Date?
    public var renewal: Set<Feature> = []
    public var renewalStarted = false
    public var renewedGrants: Set<Permission> = []

    public init(step: SetupStep = .gear) { self.step = step }

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
    public func tryFeature(_ feature: Feature, grants: Set<Permission>, skipped: Set<Permission>,
                           proven: Set<Permission>, mode: TasteMode) async -> TasteFinding {
        let parked = grants.intersection(skipped)
        if !parked.isEmpty {
            return TasteFinding(.parked, grants: parked, detail: "Waiting for " + Self.names(parked) + ". Your settings are kept.")
        }
        let states = grants.map { ($0, checker.status($0)) }
        let missing = Set(states.compactMap { grant, state in state == .granted || state == .unknown ? nil : grant })
        let unverified = Set(states.compactMap { grant, state in state == .unknown && !proven.contains(grant) ? grant : nil })
        if !missing.isEmpty {
            return TasteFinding(.parked, grants: missing, detail: "Waiting for " + Self.names(missing) + ". Your settings are kept.")
        }
        if mode == .afterUpdate && !unverified.isEmpty {
            return TasteFinding(.needsCheck, grants: unverified, detail: "Run a check to confirm " + Self.names(unverified) + ".")
        }
        return await probe.tryFeature(feature, mode: mode)
    }

    public func reset(_ permission: Permission) async -> Bool { await resetter.reset(permission) }

    public static func names(_ grants: Set<Permission>) -> String {
        Permission.setupOrder.filter(grants.contains).map(\.title).joined(separator: ", ")
    }
}
