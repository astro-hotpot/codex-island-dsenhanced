import SwiftUI

enum ChartStyle: String, CaseIterable {
    case ring, bar, stepped, numeric, spark, balance

    var label: String {
        switch self {
        case .ring: L10n.tr("Ring")
        case .bar: L10n.tr("Bar")
        case .stepped: L10n.tr("Stepped")
        case .numeric: L10n.tr("Numeric")
        case .spark: L10n.tr("Sparkline")
        case .balance: L10n.tr("Balance")
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
