import Foundation

/// The sentences of the save bar, the reminder and the recipe menu, built here so they can be tested and so the wording
/// of the approved prototype lives in one place.
public enum RecipeWording {
    /// "Audio", "Audio and Windows", "Audio, Windows and Clipboard".
    public static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    /// "just now", "today at 18:42", "yesterday at 18:42", "on Tuesday at 18:42", "on 12 Nov at 18:42".
    public static func whenPhrase(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if now.timeIntervalSince(date) >= 0, now.timeIntervalSince(date) < 60 { return "just now" }
        let time = formatted(date, calendar, locale) { $0.timeStyle = .short; $0.dateStyle = .none }
        switch dayName(date, now: now, calendar: calendar, locale: locale) {
        case .today: return "today at \(time)"
        case .yesterday: return "yesterday at \(time)"
        case .weekday(let w): return "on \(w) at \(time)"
        case .date(let d): return "on \(d) at \(time)"
        }
    }

    /// The recipe menu item that swaps the current and the previous version.
    public static func goBackTitle(_ previous: RecipeVersion, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if previous.isNewer {
            switch dayName(previous.savedAt, now: now, calendar: calendar, locale: locale) {
            case .today: return "Go forward to the version you saved today"
            case .yesterday: return "Go forward to the version you saved yesterday"
            case .weekday(let w): return "Go forward to the version you saved on \(w)"
            case .date(let d): return "Go forward to the version you saved on \(d)"
            }
        }
        switch dayName(previous.replacedAt, now: now, calendar: calendar, locale: locale) {
        case .today: return "Go back to the version before today’s save"
        case .yesterday: return "Go back to the version before yesterday’s save"
        case .weekday(let w): return "Go back to the version before \(w)’s save"
        case .date(let d): return "Go back to the version before the save on \(d)"
        }
    }

    /// "You left something on the stove."
    public static let stoveTitle = "You left something on the stove."

    /// "You changed Audio yesterday at 18:42 and did not save it to Desk."
    public static func stoveDetail(parts: [String], recipe: String, changedAt: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        "You changed \(list(parts)) \(whenPhrase(changedAt, now: now, calendar: calendar, locale: locale)) and did not save it to \(recipe)."
    }

    /// "Desk has changes you have not saved: Audio"
    public static func unsavedSummary(recipe: String, parts: [String]) -> String {
        "\(recipe) has changes you have not saved: \(parts.joined(separator: ", "))"
    }

    /// The small label while a deliberate wait runs.
    public static func changingLabel(recipe: String) -> String { "\(recipe) is changing" }
    public static func savingLabel(recipe: String) -> String { "Saving \(recipe)" }

    // MARK: Auto-switch

    public static func switchQuestionTitle(current: String) -> String { "\(current) has changes you have not saved" }
    public static func switchQuestionDetail(candidate: String, current: String, parts: [String]) -> String {
        "\(candidate) fits what is connected now. \(current) has unsaved changes to \(list(parts))."
    }
    public static func saveThenSwitch(current: String) -> String { "Save to \(current), then switch" }
    public static let switchWithoutSaving = "Switch without saving"
    public static func stay(current: String) -> String { "Stay on \(current)" }

    // MARK: Days

    enum Day { case today, yesterday, weekday(String), date(String) }

    static func dayName(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> Day {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return .yesterday }
        let start = calendar.startOfDay(for: now)
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: start).day, days > 0, days < 7 {
            return .weekday(formatted(date, calendar, locale) { $0.setLocalizedDateFormatFromTemplate("EEEE") })
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return .date(formatted(date, calendar, locale) { $0.setLocalizedDateFormatFromTemplate(sameYear ? "d MMM" : "d MMM y") })
    }

    private static func formatted(_ date: Date, _ calendar: Calendar, _ locale: Locale, _ configure: (DateFormatter) -> Void) -> String {
        let f = DateFormatter()
        f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
        configure(f)
        return f.string(from: date)
    }
}
