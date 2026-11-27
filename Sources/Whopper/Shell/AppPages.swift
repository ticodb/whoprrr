import SwiftUI
import WhopperKit

/// The pages of the main window.
enum AppPage: Hashable {
    case feature(Feature), features, permissions, recipes, about, welcome, picklsss, extras

    init?(name: String) {
        switch name {
        case "features": self = .features
        case "permissions": self = .permissions
        case "recipes": self = .recipes
        case "about": self = .about
        case "welcome": self = .welcome
        case "picklsss": self = .picklsss
        case "extras": self = .extras
        default:
            guard let f = Feature(rawValue: name) else { return nil }
            self = .feature(f)
        }
    }
}

extension AppPage {
    /// The page where a recipe part is changed ("audio" → Audio), so a window opened to a reminder lands on it. Falls back to
    /// Recipes when that feature is switched off.
    @MainActor
    static func page(forRecipePart key: String, features: FeatureStore) -> AppPage {
        let page: AppPage
        switch key {
        case "audio": page = .feature(.audio)
        case "windows": page = .feature(.windows)
        case "clipboard": page = .feature(.clipboard)
        case "input": page = .feature(.remap)
        case "display": page = .feature(.display)
        case "features": return .features
        default: return .recipes
        }
        if case .feature(let f) = page, !features.isEnabled(f) { return .recipes }
        return page
    }
}

/// Which page the main window shows. Shared so the menu-bar panel can open the window on a given page.
@MainActor
final class WindowNav: ObservableObject {
    /// Set by the menu-bar panel to open the window straight into the new-recipe sheet.
    @Published var newRecipeRequested = false
    /// True while the main window is on screen. Questions and reminders that belong to it wait until it is.
    @Published var windowOpen = false {
        didSet { if !windowOpen { onClose?() } }
    }
    @Published var page: AppPage = AppPage(name: ProcessInfo.processInfo.environment["WHOPPER_PAGE"] ?? "") ?? .feature(.display) {
        didSet { if windowOpen && oldValue != page { onPageChange?() } }
    }
    var onPageChange: (() -> Void)?
    var onClose: (() -> Void)?
}

/// The content of one page. Each feature supplies its own panel.
struct PageContent: View {
    var page: AppPage
    var body: some View {
        switch page {
        case .feature(.display): DisplayPanel()
        case .feature(.audio): AudioPanel()
        case .feature(.windows): WindowPanel()
        case .feature(.clipboard): ClipboardPanel()
        case .feature(.remap): InputPanel()
        case .feature(.microphone): MicPanel()
        case .feature(let f): Text("\(f.title) is not built yet.").foregroundStyle(.secondary)
        case .features: FeaturesHubView()
        case .permissions: PermissionsView()
        case .recipes: RecipesView()
        case .about: AboutView()
        case .welcome: WelcomeView()
        case .picklsss: PicklsssView()
        case .extras: ExtrasView()
        }
    }
}
