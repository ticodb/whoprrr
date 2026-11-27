import Foundation

/// "Did it work?" after a take: the same models-and-results report the gear scan offers, in the same shape
/// (`FitReport.payload`), so the same server endpoint and the same checks keep it to models and results.
/// It is built here so tests can hold it to that. Nothing leaves the Mac until the person presses a button.
public enum TakeReport {
    public enum Outcome: Equatable, Sendable {
        /// "It works": every line that was on is reported as working.
        case works
        /// "Something is off": the lines are reported with the label the person saw. Which one is off is not known, so none is blamed.
        case somethingOff
    }

    public static func payload(app: String, scan: GearScan, plan: FitPlan, switchedOn: Set<String>, outcome: Outcome) -> [String: Any] {
        let gear: [[String: String]] = plan.matches.compactMap { m in
            guard let r = m.receiver else { return nil }
            return ["name": KnownGear.publicName(r.model), "detail": ShelfRanking.normalizedRole(m.author.role),
                    "fit": (KnownGear.isTested(r.model) ? Fit.tested : Fit.untested).rawValue]
        }
        let lines: [[String: Any]] = plan.lines.map { l in
            let on = switchedOn.contains(l.id) && !l.state.isOff
            let fit = outcome == .works && on ? "works" : TakeFit.fit(of: l, in: plan).rawValue
            return ["id": FitReport.publicID(l.id), "fit": fit, "on": on]
        }
        return [
            "kind": "mac", "app": app,
            "mac": ["model": scan.mac.model, "chip": scan.mac.appleSilicon ? "arm64" : "x86_64", "os": scan.mac.os],
            "gear": gear, "lines": lines,
            "off": plan.off.map { ["feature": $0.part] },
        ]
    }

    public static func json(app: String, scan: GearScan, plan: FitPlan, switchedOn: Set<String>, outcome: Outcome) -> Data {
        (try? JSONSerialization.data(withJSONObject: payload(app: app, scan: scan, plan: plan, switchedOn: switchedOn, outcome: outcome), options: [.sortedKeys])) ?? Data()
    }

    /// The same content as readable text, shown before anything is sent.
    public static func text(app: String, scan: GearScan, plan: FitPlan, switchedOn: Set<String>, outcome: Outcome) -> String {
        let p = payload(app: app, scan: scan, plan: plan, switchedOn: switchedOn, outcome: outcome)
        var out = ["Whoprrr \(app) · \(scan.mac.model) · \(scan.mac.appleSilicon ? "Apple Silicon" : "Intel") · macOS \(scan.mac.os)"]
        for g in (p["gear"] as? [[String: String]]) ?? [] { out.append("\(g["name"] ?? ""): \(g["detail"] ?? "") (\(g["fit"] ?? ""))") }
        for l in (p["lines"] as? [[String: Any]]) ?? [] { out.append("\(l["id"] ?? ""): \((l["on"] as? Bool) == true ? "on" : "off") (\(l["fit"] ?? ""))") }
        for o in (p["off"] as? [[String: String]]) ?? [] { out.append("\(o["feature"] ?? ""): not on this setup") }
        return out.joined(separator: "\n")
    }
}

/// Applying is nearly instant, so it is a deliberate pause: each part gets its own beat, about a second in all. The same
/// "Cookin'" label as the save bar.
public enum CookinBeats {
    public static let total: TimeInterval = 1.0

    /// One beat per part, sharing the total (never shorter than a tenth of a second each).
    public static func beats(parts: Int) -> [TimeInterval] {
        guard parts > 0 else { return [] }
        return Array(repeating: max(0.1, total / Double(parts)), count: parts)
    }
}
