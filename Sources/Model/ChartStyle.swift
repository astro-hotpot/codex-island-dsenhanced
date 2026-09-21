import SwiftUI

enum ChartStyle: String, CaseIterable {
    case ring, bar, stepped, numeric, spark, balance

    var label: String {
        switch self {
        case .ring: return L10n.tr("Ring")
        case .bar: return L10n.tr("Bar")
        case .stepped: return L10n.tr("Stepped")
        case .numeric: return L10n.tr("Numeric")
        case .spark: return L10n.tr("Sparkline")
        case .balance: return L10n.tr("Balance")
        }
    }
}

@MainActor
final class StylePref: StylePreferenceStore<ChartStyle> {
    static let shared = StylePref()

    private init() {
        super.init(
            styleKey: "MacIsland.chartStyle",
            cycledKey: "MacIsland.hasCycledStyle",
            defaultStyle: .ring
        )
    }
}
