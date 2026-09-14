import Foundation

enum IslandProvider: String, CaseIterable, Identifiable, Codable {
    case claude, codex, grok, antigravity, deepseek

    var id: String { rawValue }
    var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .antigravity: return "Antigravity"
        case .deepseek: return "DeepSeek"
        }
    }
    var usesLegacyUsage: Bool { self == .claude || self == .codex }
}
