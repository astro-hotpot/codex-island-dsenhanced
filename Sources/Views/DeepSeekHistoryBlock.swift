import SwiftUI

struct DeepSeekHistoryBlock: View {
    var body: some View {
        HStack(spacing: 18) {
            DeepSeekHistoryColumn(store: .shared, slot: 0)
            DeepSeekHistoryColumn(store: .second, slot: 1)
        }
        .padding(.horizontal, IslandPanelLayout.columnInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DeepSeekHistoryColumn: View {
    @ObservedObject var store: DeepSeekHistoryStore
    let slot: Int
    @AppStorage("MacIsland.deepSeekColumn.0.metric") private var firstMetric = "cost"
    @AppStorage("MacIsland.deepSeekColumn.1.metric") private var secondMetric = "cost"

    var body: some View {
        let tokens = (slot == 0 ? firstMetric : secondMetric) == "tokens"
        let raw = store.range == .total
            ? (tokens ? store.summary?.totalTokens : store.summary?.totalCost)
            : (tokens ? store.summary?.tokens : store.summary?.cost)
        let display = formatted(raw, tokens: tokens)
        DeepSeekMetricTile(label: store.range.pageLabel, value: display.0, unit: display.1,
            caption: store.message ?? (raw == nil
                ? L10n.tr(store.loading ? "Loading" : "No data")
                : tokens ? "Tokens" : L10n.tr("Cost")))
            .help(raw ?? store.message ?? L10n.tr("No data"))
            .task { store.refresh() }
    }

    private func formatted(_ raw: String?, tokens: Bool) -> (String, String) {
        guard let raw else { return ("—", "") }
        guard tokens, let n = Double(raw.replacingOccurrences(of: ",", with: "")) else { return (raw, "") }
        if n >= 1_000_000 { return (String(format: "%.1f", n / 1_000_000), "M") }
        if n >= 1_000 { return (String(format: "%.1f", n / 1_000), "K") }
        return (raw, "")
    }
}

struct DeepSeekSettingsSection: View {
    @ObservedObject private var history = DeepSeekHistoryStore.shared
    @ObservedObject private var second = DeepSeekHistoryStore.second
    @ObservedObject private var balance = DeepSeekBalanceStore.shared
    @AppStorage("MacIsland.deepSeekColumn.0.metric") private var firstMetric = "cost"
    @AppStorage("MacIsland.deepSeekColumn.1.metric") private var secondMetric = "cost"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            columnSettings("First column", range: $history.range, metric: $firstMetric)
            columnSettings("Second column", range: $second.range, metric: $secondMetric)
            HStack {
                Button(L10n.tr("Open DeepSeek")) { history.connect() }
                Button(L10n.tr("Refresh")) {
                    Task { await balance.refresh() }
                    history.refresh()
                    second.refresh()
                }
            }
            Text(L10n.tr("Lifetime tokens unavailable unless full history is returned"))
                .font(Typography.caption).foregroundStyle(.white.opacity(0.5))
            ForEach([history, second], id: \.self) { store in
                if let error = store.message {
                    Text(error).font(Typography.label).foregroundStyle(.orange)
                }
            }
        }
    }

    private func columnSettings(_ title: String, range: Binding<DeepSeekHistoryRange>, metric: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr(title)).font(Typography.label)
            Picker(L10n.tr("Display time range"), selection: range) {
                ForEach(DeepSeekHistoryRange.allCases) { item in
                    Text(L10n.tr(item.pageLabel)).tag(item)
                }
            }
            Picker(L10n.tr("Display metric"), selection: metric) {
                Text("Token").tag("tokens")
                Text(L10n.tr("Cost")).tag("cost")
            }.pickerStyle(.segmented)
        }
    }
}
