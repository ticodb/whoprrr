import SwiftUI
import WhopperKit

/// The pages of the main window.
enum AppPage: Hashable {
    case feature(Feature), features, permissions, recipes, about, welcome

    init?(name: String) {
        switch name {
        case "features": self = .features
        case "permissions": self = .permissions
        case "recipes": self = .recipes
        case "about": self = .about
        case "welcome": self = .welcome
        default:
            guard let f = Feature(rawValue: name) else { return nil }
            self = .feature(f)
        }
    }
}

/// Which page the main window shows. Shared so the menu-bar panel can open the window on a given page.
@MainActor
final class WindowNav: ObservableObject {
    /// Set by the menu-bar panel to open the window straight into the new-recipe sheet.
    @Published var newRecipeRequested = false
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
        }
    }
}
