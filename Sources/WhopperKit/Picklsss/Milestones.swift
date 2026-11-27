import Foundation

public enum CookRank: Int, CaseIterable, Codable, Comparable, Sendable {
    case dishwasher = 1, prepCook, lineCook, sousChef, headChef

    public var name: String {
        switch self {
        case .dishwasher: "dishwasher"
        case .prepCook: "prep cook"
        case .lineCook: "line cook"
        case .sousChef: "sous chef"
        case .headChef: "head chef"
        }
    }

    public init?(shelfName: String?) {
        guard let shelfName, let value = Self.allCases.first(where: { $0.name == shelfName.lowercased() }) else { return nil }
        self = value
    }

    public static func < (lhs: CookRank, rhs: CookRank) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PicklsssMilestone: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case rank(CookRank)
        case firstKeep
        case firstTake(title: String, inRecipes: Bool)
        case tenTakes, twentyFiveTakes, fiftyTakes
        case pickle
    }

    public let kind: Kind
    public let rank: CookRank?
    public let pickles: Int

    public init(kind: Kind, rank: CookRank?, pickles: Int) {
        self.kind = kind
        self.rank = rank
        self.pickles = max(0, pickles)
    }

    public var id: String {
        switch kind {
        case .rank(let rank): "rank-\(rank.rawValue)"
        case .firstKeep: "first-keep"
        case .firstTake: "first-take"
        case .tenTakes: "ten-takes"
        case .twentyFiveTakes: "twenty-five-takes"
        case .fiftyTakes: "fifty-takes"
        case .pickle: "pickle-\(pickles)"
        }
    }

    public var title: String {
        switch kind {
        case .rank(.dishwasher): "Your first picklsss is on the shelf"
        case .rank(.headChef): "Head chef"
        case .rank(let rank): "You are a \(rank.name)"
        case .firstKeep: "Someone kept your setup"
        case .firstTake: "Your first take"
        case .tenTakes: "Ten setups taken"
        case .twentyFiveTakes: "Twenty-five setups taken"
        case .fiftyTakes: "Fifty setups taken"
        case .pickle: "One more picklsss"
        }
    }

    public var detail: String {
        switch kind {
        case .rank(.dishwasher): "You are a dishwasher now. Everyone starts here. Picklsss is yours at no cost."
        case .rank(.prepCook): "People are keeping what you share. There’s a patty on your burger now."
        case .rank(.lineCook): "20 keeps. People stay with what you share."
        case .rank(.sousChef): "People have made your setups part of their day."
        case .rank(.headChef): "200 keeps across three setups. The burger is complete."
        case .firstKeep: "A week later it is still in their recipes. That is what ranks are made of."
        case .firstTake(let title, true): "“\(title)” is in your recipes. One button puts everything back."
        case .firstTake(let title, false): "“\(title)” is in your presets."
        case .tenTakes: "You know what a good one feels like. Got one of your own worth sharing?"
        case .twentyFiveTakes: "You’ve tried a lot of ways to set up a Mac. Got a setup you come back to?"
        case .fiftyTakes: "Fifty setups, fifty ways to make a Mac feel like yours. There’s room on the shelf for yours too."
        case .pickle: "A pickle lands on your burger each time you take a setup or share one."
        }
    }

    public var introducedLayer: CookRank? {
        if case .rank(let layer) = kind { return layer }
        return nil
    }

    public var dropsPickle: Bool {
        switch kind {
        case .firstTake, .tenTakes, .twentyFiveTakes, .fiftyTakes, .pickle: true
        default: false
        }
    }

    public var duration: TimeInterval { kind == .pickle ? 0.85 : 2.1 }
}

/// Monotonic counters and a persistent FIFO. The previous app stored local takes and shares but did not store cook rank.
public struct MilestoneProgress: Codable, Equatable, Sendable {
    public private(set) var takes: Int
    public private(set) var shares: Int
    public private(set) var highestRank: CookRank?
    public private(set) var keeps: Int = 0
    public private(set) var queued: [PicklsssMilestone] = []
    private var hasCookBaseline = false

    public init(previousTakes: Int, previousShares: Int) {
        takes = max(0, previousTakes)
        shares = max(0, previousShares)
    }

    public var pickles: Int { takes + shares }

    public mutating func observeCook(_ cook: ShelfCook?, sharedCount: Int) {
        let rank = CookRank(shelfName: cook?.rank)
        let newKeeps = max(0, cook?.keeps ?? 0)
        guard hasCookBaseline else {
            hasCookBaseline = true
            highestRank = rank
            keeps = newKeeps
            shares = max(shares, sharedCount)
            return
        }

        let oldLevel = highestRank?.rawValue ?? 0
        let newLevel = rank?.rawValue ?? 0
        if oldLevel == 0 && newLevel >= 1 { enqueue(.rank(.dishwasher), rank: .dishwasher) }
        if keeps == 0 && newKeeps > 0 { enqueue(.firstKeep, rank: highestRank ?? (rank == nil ? nil : .dishwasher)) }
        for gained in CookRank.allCases where gained != .dishwasher && gained.rawValue > oldLevel && gained.rawValue <= newLevel {
            enqueue(.rank(gained), rank: gained)
        }
        if newLevel > oldLevel { highestRank = rank }
        keeps = max(keeps, newKeeps)
    }

    public mutating func recordTake(title: String, inRecipes: Bool) {
        takes += 1
        let kind: PicklsssMilestone.Kind = switch takes {
        case 1: .firstTake(title: title, inRecipes: inRecipes)
        case 10: .tenTakes
        case 25: .twentyFiveTakes
        case 50: .fiftyTakes
        default: .pickle
        }
        enqueue(kind, rank: highestRank)
    }

    public mutating func recordShare() {
        shares += 1
        enqueue(.pickle, rank: highestRank)
    }

    public mutating func next(windowOpen: Bool) -> PicklsssMilestone? {
        guard windowOpen, !queued.isEmpty else { return nil }
        return queued.removeFirst()
    }

    private mutating func enqueue(_ kind: PicklsssMilestone.Kind, rank: CookRank?) {
        queued.append(PicklsssMilestone(kind: kind, rank: rank, pickles: pickles))
    }
}
