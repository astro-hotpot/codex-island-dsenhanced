import SwiftUI

struct DeepSeekMetricTile: View {
    let label: String
    let value: String
    var unit: String = ""
    var caption: String = ""

    @ObservedObject private var currency = CurrencyStore.shared

    private var money: (Double, String, Bool)? {
        let symbols = ["¥": "CNY", "$": "USD", "€": "EUR"]
        let prefix = String(value.prefix(1))
        let source = symbols[prefix] ?? (["CNY", "USD", "EUR"].contains(unit) ? unit : "")
        guard !source.isEmpty,
              let amount = Double((symbols[prefix] == nil ? value : String(value.dropFirst()))
                .replacingOccurrences(of: ",", with: "")) else { return nil }
        if let converted = currency.converted(amount: amount, from: source) {
            return (converted, currency.displaySymbol, currency.displayUsesWholeUnits)
        }
        return (amount, source == "CNY" ? "¥" : source == "USD" ? "$" : "€", false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.tr(label)).font(Typography.label).foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(caption).font(Typography.caption).foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1).truncationMode(.tail).help(caption)
            }
            Spacer(minLength: 0)
            Group {
                if let money {
                    CostMoneyHero(amount: money.0, symbol: money.1, wholeUnits: money.2,
                                  color: IslandProvider.deepseek.color, glowOpacity: 0.45)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(value).font(Typography.bigNumber).foregroundStyle(IslandProvider.deepseek.color)
                            .shadow(color: IslandProvider.deepseek.color.opacity(0.45), radius: 6)
                            .shadow(color: IslandProvider.deepseek.color.opacity(0.225), radius: 14)
                            .lineLimit(1).minimumScaleFactor(0.5)
                        Text(unit).font(Typography.unit).foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .offset(y: -10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: IslandPanelLayout.tileHeight)
    }
}

struct DeepSeekBalanceBlock: View {
    @ObservedObject private var store = DeepSeekBalanceStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("Available balance"))
                .font(Typography.label).foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 0)
            if let entries = store.balance?.balance_infos {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(entry.total_balance)
                            .font(Typography.bigNumber)
                            .foregroundStyle(IslandProvider.deepseek.color)
                            .lineLimit(1).minimumScaleFactor(0.5)
                        Text(entry.currency)
                            .font(Typography.unit).foregroundStyle(.white.opacity(0.4))
                    }
                }
            } else {
                Text("—").font(Typography.bigNumber).foregroundStyle(IslandProvider.deepseek.color)
            }
            Spacer(minLength: 0)
            ChartFoot(caption: store.error ?? L10n.tr(store.balance == nil
                ? "Configure DeepSeek in Settings"
                : store.balance?.is_available == true ? "Available balance" : "Insufficient balance"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, IslandPanelLayout.columnInset)
        .task { if store.updatedAt == nil { await store.refresh() } }
    }
}
