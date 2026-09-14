import SwiftUI

struct CostMoneyHero: View {
    let amount: Double
    let symbol: String
    let wholeUnits: Bool
    let color: Color
    let glowOpacity: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(symbol).font(Typography.unit).foregroundStyle(.white.opacity(0.4))
            CountUpDollar(target: amount, wholeUnits: wholeUnits, color: color, glowOpacity: glowOpacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
