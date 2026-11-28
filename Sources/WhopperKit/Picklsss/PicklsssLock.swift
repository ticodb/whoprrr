import Foundation

/// Where the extra is asked for. Browsing, opening, matching gear and reviewing are free for everyone; the lock appears at the
/// first action that changes this Mac, which is taking. The pass says whether the buyer has the extra (`pick`).
public enum PicklsssLock {
    public enum Action: Equatable, Sendable {
        case browse, open, matchGear, review
        /// Applying a shared setup (or an update to one) to this Mac.
        case take
        /// Taking one part on its own into the presets.
        case takePart
        /// Opening a file and looking at how it fits is free; `madeBy` is who made it (a key id), as the file says.
        case openFile
        /// Taking from a file. Always free for a file made under the person's own key.
        case takeFromFile(madeBy: String?)
        case makeFile, share, update, takedown, putBack
    }

    public enum Decision: Equatable, Sendable { case free, locked }

    /// What the lock card says, and the words around it. Plain, because errors and key screens use plain words only.
    public static let price = "$4, paid once"
    public static let freeIfAccepted = "free if a picklsss you share is accepted"

    public static func decision(_ action: Action, pass: LicensePass?) -> Decision {
        switch action {
        case .browse, .open, .matchGear, .review, .openFile, .makeFile, .share, .update, .takedown, .putBack: return .free
        case .take, .takePart: return hasExtra(pass) ? .free : .locked
        case .takeFromFile(let madeBy): return isOwnFile(madeBy: madeBy, pass: pass) || hasExtra(pass) ? .free : .locked
        }
    }

    public static func hasExtra(_ pass: LicensePass?) -> Bool { pass?.pick == true }

    /// A file made under the person's own key always opens free. Without a pass nothing can be called "own".
    public static func isOwnFile(madeBy: String?, pass: LicensePass?) -> Bool {
        guard let madeBy, !madeBy.isEmpty, let kid = pass?.kid, !kid.isEmpty else { return false }
        return madeBy == kid
    }
}

/// The server can say yes to a take that the pass does not know about yet (the extra switches on for a cook the first time one of
/// their setups goes public, and the pass only learns at its next renewal). So `needs_extra` from the server, not the pass, is what
/// finally decides; the pass only decides when to show the card before asking.
public enum PicklsssWords {
    /// "Audio", "External displays"… the part names as the app's pages call them.
    public static func partTitle(_ key: String) -> String {
        switch key {
        case "audio": "Audio"
        case "microphone": "Microphone"
        case "windows": "Windows"
        case "keys": "Keys and mouse"
        case "typingLanguage": "Typing language"
        case "clipboard": "Clipboard"
        case "display": "External displays"
        default: key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    public static func partList(_ keys: [String]) -> String { keys.map(partTitle).joined(separator: ", ") }

    /// "212 people kept it", "1 person kept it", "Nobody has kept it yet".
    public static func keeps(_ n: Int) -> String {
        switch n { case 0: return "Nobody has kept it yet"; case 1: return "1 person kept it"; default: return "\(n) people kept it" }
    }

    /// "sous chef · 41 kitchen days" for a card's byline; the rank is whatever the server said.
    public static func cookLine(_ c: ShelfCook) -> String {
        var s = "by \(c.handle)"
        if let r = c.rank { s += ", \(r)" }
        return s
    }

    /// A cook's own total: "No keeps yet", "1 keep", "23 keeps".
    public static func cookKeeps(_ n: Int) -> String { n == 0 ? "No keeps yet" : n == 1 ? "1 keep" : "\(n) keeps" }

    public static func kitchenDays(_ n: Int) -> String { n == 1 ? "1 kitchen day" : "\(n) kitchen days" }

    /// The five states in plain words, for a cook's own list.
    public static func state(_ s: ShelfState) -> String {
        switch s {
        case .checking: "Being checked"
        case .public: "Public"
        case .held: "Being checked"
        case .refused: "Not accepted"
        case .removed: "Taken down"
        }
    }

    /// What a cook sees under a state, when the server gave no reason of its own.
    public static func stateDetail(_ s: ShelfState) -> String {
        switch s {
        case .checking: "A moment, while the shelf decides."
        case .public: "On the shelf, and anyone can take it."
        case .held: "We’ll look at it soon. Only you can see it until then."
        case .refused: "It was not accepted."
        case .removed: "It is off the shelf. Copies people took are theirs."
        }
    }

    public static let countQuestionTitle = "Count what you keep?"
    public static let countQuestionBody = "Cooks earn their rank from people who keep their picklsss. If you say yes, Whoprrr tells the shelf one thing for each picklsss you take: 7 days later, kept or not. Never your settings, your gear or anything else."
    public static let countQuestionNote = "You can change this any time on the Extras page."

    public static func takedownTitle(_ title: String) -> String { "Take “\(title)” down?" }
    /// The prototype said "The page and the link stop working"; this build has no public page, so the sentence says what is true.
    public static func takedownBody(keeps: Int) -> String {
        let who = keeps == 0 ? "Nobody has kept it yet. " : keeps == 1 ? "1 person kept it; their copy stays as it is. " : "\(keeps) people kept it; their copies stay as they are. "
        return "It leaves the shelf and nobody new can take it. \(who)Your own recipe is not touched."
    }

    /// The refusal screen for a file someone edited by hand.
    public static let tamperedTitle = "This file was not opened"
    public static let tamperedWhy = "It asks for things a setup cannot do. Whoprrr never writes values like these, so the file was changed by hand."
    public static let tamperedNothing = "Nothing. No setting on this Mac was changed."
}
