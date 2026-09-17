import Foundation

@MainActor
final class GlowEnabledStore: ObservableObject {
    static let shared = GlowEnabledStore()
    private static let key = "MacIsland.glowEnabled"

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.key) }
    }

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
    }
}
