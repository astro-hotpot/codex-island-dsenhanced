import Foundation

@MainActor
final class HideIconsStore: ObservableObject {
    static let shared = HideIconsStore()
    private static let key = "MacIsland.hideIcons"

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.key) }
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.key)
    }
}
