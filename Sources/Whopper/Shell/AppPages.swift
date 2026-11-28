import SwiftUI
import WhopperKit

/// The pages of the main window.
enum AppPage: Hashable {
    case feature(Feature), features, permissions, recipes, about, welcome, picklsss, extras

    var storageName: String {
        switch self {
        case .feature(let feature): return feature.rawValue
        case .features: return "features"
        case .permissions: return "permissions"
        case .recipes: return "recipes"
        case .about: return "about"
        case .welcome: return "welcome"
        case .picklsss: return "picklsss"
        case .extras: return "extras"
        }
    }

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
    /// The page for an unsaved section. Recipes is the fallback when its feature is switched off.
    @MainActor
    static func page(forRecipePart key: String, features: FeatureStore) -> AppPage {
        let page: AppPage
        switch key {
        case "audio", "audio.eq", "audio.mix", "audio.outputfx", "audio.routing": page = .feature(.audio)
        case "audio.mic": page = .feature(.microphone)
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
    /// Questions that belong to the main window wait until it is on screen.
    @Published var windowOpen = false
    @Published var drawerOpen = false
    @Published var drawerPage: AppPage?

    func openDrawerSection(_ section: AppPage) {
        page = section
        drawerPage = section
    }

    func returnToOverview() { drawerPage = nil }
    @Published var page: AppPage = AppPage(name: ProcessInfo.processInfo.environment["WHOPPER_PAGE"] ?? "") ?? .feature(.display)
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
