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

/// One first-page DeepSeek metric. `value == nil` renders the unavailable
/// dash so a failed fetch keeps its column width and never hides its sibling.
private struct DeepSeekMetricColumn: View {
    let label: String
    let value: String?
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Typography.label)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 0)
            Group {
                if let value {
                    Text(value)
                        .font(Typography.bigNumber)
                        .foregroundStyle(IslandProvider.deepseek.color)
                        .shadow(color: IslandProvider.deepseek.color.opacity(0.45), radius: 6)
                        .shadow(color: IslandProvider.deepseek.color.opacity(0.225), radius: 14)
                } else {
                    Text("—")
                        .font(Typography.bigNumber)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            Spacer(minLength: 0)
            Text(caption)
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// First-page DeepSeek column: available balance (`api.deepseek.com`) and the
/// Platform account's billed cost over the last 30 local calendar days. The
/// two sources are fetched and reported independently — either one can be
/// unavailable without taking the other (or the block) down with it.
struct DeepSeekBalanceBlock: View {
    @ObservedObject private var store = DeepSeekBalanceStore.shared
    @ObservedObject private var cost = DeepSeekAccountCostStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 18) {
                DeepSeekMetricColumn(label: L10n.tr("Account balance"),
                                     value: balanceValue,
                                     caption: balanceCaption)
                DeepSeekMetricColumn(label: L10n.tr("Last 30 days"),
                                     value: costValue,
                                     caption: costCaption)
            }
            ChartFoot(caption: footerCaption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, IslandPanelLayout.columnInset)
        .task { if store.updatedAt == nil { await store.refresh() } }
        .task { if cost.snapshot == nil { await cost.refresh() } }
    }

    private var balanceValue: String? {
        store.balance?.headline
    }

    private var balanceCaption: String {
        if let error = store.error { return error.message }
        guard let balance = store.balance else {
            return store.loading ? L10n.tr("Loading") : L10n.tr("DeepSeek API key not configured")
        }
        return balance.is_available ? "" : L10n.tr("Insufficient balance")
    }

    private var costValue: String? {
        guard let total = cost.snapshot?.total else { return nil }
        return Self.money(total)
    }

    /// Says exactly which series the number covers: the API-key count comes
    /// from the response itself, so a single-series reply is labelled as a
    /// tracked key instead of being passed off as the account total.
    private var costCaption: String {
        if let status = cost.status { return status.message }
        guard let total = cost.snapshot?.total else {
            return cost.hasPlatformToken
                ? (cost.loading ? L10n.tr("Loading") : L10n.tr("Platform usage unavailable"))
                : L10n.tr("DeepSeek Platform token not configured")
        }
        switch total.apiKeyCount {
        case 0: return L10n.tr("No usage in the last 30 days")
        case 1: return L10n.tr("tracked key")
        default: return L10n.tr("%d API keys", total.apiKeyCount)
        }
    }

    private var footerCaption: String {
        let stamps = [store.updatedAt, cost.snapshot?.refreshedAt].compactMap { $0 }
        guard let latest = stamps.max() else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return L10n.tr("Updated %@", formatter.string(from: latest))
    }

    private static func money(_ total: DeepSeekCostTotal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let number = NSDecimalNumber(decimal: total.amount)
        let text = formatter.string(from: number) ?? number.stringValue
        switch total.currency.uppercased() {
        case "CNY", "RMB", "JPY": return "¥" + text
        case "USD": return "$" + text
        case "EUR": return "€" + text
        default: return total.currency + " " + text
        }
    }
}
