import SwiftUI

struct DeepSeekHistoryBlock: View {
    @ObservedObject private var store = DeepSeekAccountUsageStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.tr("Total token usage"))
                    .font(Typography.label)
                    .foregroundStyle(.white.opacity(0.72))
                Text(connectionLabel)
                    .font(Typography.caption)
                    .foregroundStyle(connectionColor)
                Spacer(minLength: 0)
            }

            if let snapshot = store.snapshot {
                HStack(spacing: 18) {
                    DeepSeekAccountPeriodColumn(label: "Today", period: snapshot.today)
                    DeepSeekAccountPeriodColumn(label: "This Month", period: snapshot.month)
                }
            } else {
                Spacer(minLength: 0)
                Text(store.loading ? L10n.tr("Loading") : (store.status?.message ?? "Token usage is unavailable"))
                    .font(Typography.label)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            }

            Text("Source: DeepSeek Platform Billing · all API keys")
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.36))
        }
        .padding(.horizontal, IslandPanelLayout.columnInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await store.refresh() }
    }

    private var connectionLabel: String {
        store.connectionMessage
    }

    private var connectionColor: Color {
        store.snapshot == nil ? .orange.opacity(0.8) : .green.opacity(0.8)
    }
}

/// One period of the account-wide totals: the account's token total for the
/// period, the API-key count it was aggregated over, and the breakdown.
private struct DeepSeekAccountPeriodColumn: View {
    let label: String
    let period: DeepSeekWorkerBillingPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(Typography.label).foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(costLabel).font(Typography.caption)
                    .foregroundStyle(period.actualCostCNY == nil ? .orange.opacity(0.8) : .white.opacity(0.5))
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(format(period.usage.totalTokens))
                    .font(Typography.bigNumber)
                    .foregroundStyle(IslandProvider.deepseek.color)
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text("tokens").font(Typography.unit).foregroundStyle(.white.opacity(0.4))
            }
            Text(scopeCaption)
                .font(Typography.caption).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
            HStack(spacing: 8) {
                metric("Req", period.usage.requests)
                metric("In", period.usage.inputTokens)
                metric("Out", period.usage.outputTokens)
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 8) {
                metric("Hit", period.usage.cacheHitTokens)
                metric("Miss", period.usage.cacheMissTokens)
                Text(hitRateLabel).font(Typography.caption).foregroundStyle(.white.opacity(0.42))
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            if !period.models.isEmpty {
                Text(period.models.prefix(2).map { "\($0.model) \(format($0.usage.totalTokens))" }.joined(separator: " · "))
                    .font(Typography.caption).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(detailHelp)
    }

    /// Says which API keys the total covers; the count comes from the
    /// response, so a single-series reply is not passed off as the account.
    private var scopeCaption: String {
        guard period.hasMatchingSeries else { return L10n.tr("No usage in this period") }
        return period.apiKeyCount == 1
            ? L10n.tr("1 API key")
            : L10n.tr("%d API keys", period.apiKeyCount)
    }

    private func metric(_ name: String, _ value: Int) -> some View {
        Text("\(name) \(format(value))")
            .font(Typography.caption)
            .foregroundStyle(.white.opacity(0.46))
            .lineLimit(1)
    }

    /// Compact enough for a half-width period column; the full wording lives
    /// in `detailHelp`.
    private var costLabel: String {
        guard let cost = period.actualCostCNY else { return L10n.tr("Cost —") }
        return String(format: "Cost ¥%.2f", NSDecimalNumber(decimal: cost).doubleValue)
    }

    private var hitRateLabel: String {
        guard let rate = period.usage.cacheHitRate else { return "hit —" }
        return String(format: "%.0f%% hit", rate * 100)
    }

    private var detailHelp: String {
        "Account-wide over \(period.apiKeyCount) API key(s). Requests \(period.usage.requests), input \(period.usage.inputTokens), cache hit \(period.usage.cacheHitTokens), cache miss \(period.usage.cacheMissTokens), output \(period.usage.outputTokens), total \(period.usage.totalTokens). \(costLabel)."
    }

    private func format(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

/// Two independent DeepSeek credentials live here, and each label says which
/// endpoint it feeds:
///   • DeepSeek API Key      → api.deepseek.com (available balance, API calls)
///   • DeepSeek Platform Token → platform.deepseek.com (usage / 30-day cost)
/// They are different secrets in different Keychain items; neither is ever
/// written to UserDefaults or shown back to the UI.
struct DeepSeekSettingsSection: View {
    @ObservedObject private var billing = DeepSeekWorkerBillingStore.shared
    @ObservedObject private var balance = DeepSeekBalanceStore.shared
    @ObservedObject private var accountCost = DeepSeekAccountCostStore.shared
    @State private var apiKey = ""
    @State private var platformToken = ""
    @State private var trackingID = ""
    @State private var keyLabel = ""
    @State private var credentialMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            apiKeyGroup
            Divider().overlay(.white.opacity(0.08))
            platformTokenGroup
            if let credentialMessage {
                Text(credentialMessage).font(Typography.caption).foregroundStyle(.orange)
            }
        }
        .onAppear {
            trackingID = billing.configuredTrackingID
            keyLabel = billing.configuredKeyLabel
        }
        .onDisappear {
            apiKey = ""
            platformToken = ""
        }
    }

    @ViewBuilder
    private var apiKeyGroup: some View {
        Text("DeepSeek API Key")
            .font(Typography.label).foregroundStyle(.white.opacity(0.78))
        SecureField("sk-… (api.deepseek.com)", text: $apiKey)
            .textFieldStyle(.roundedBorder)
        Text("Used to authenticate the DeepSeek account balance on api.deepseek.com. A key entered here is stored in the macOS Keychain.")
            .font(Typography.caption).foregroundStyle(.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Button(balance.hasStoredAPIKey ? "Update API Key" : "Save API Key") { saveAPIKey() }
            Button("Remove API Key") { removeAPIKey() }
                .disabled(!balance.hasStoredAPIKey)
            Button(L10n.tr("Refresh balance")) { Task { await balance.refresh(force: true) } }
        }
        Text(balanceStatus)
            .font(Typography.label)
            .foregroundStyle(balance.error == nil ? .green : .orange)
    }

    @ViewBuilder
    private var platformTokenGroup: some View {
        Text("DeepSeek Platform Token")
            .font(Typography.label).foregroundStyle(.white.opacity(0.78))
        SecureField("Platform login token (platform.deepseek.com)", text: $platformToken)
            .textFieldStyle(.roundedBorder)
        Text("Used for Platform usage and the last-30-days cost. Stored in the macOS Keychain.")
            .font(Typography.caption).foregroundStyle(.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
        TextField("Worker Tracking ID", text: $trackingID)
            .textFieldStyle(.roundedBorder)
        TextField("API Key Label/Name (optional)", text: $keyLabel)
            .textFieldStyle(.roundedBorder)
        HStack {
            Button(billing.hasPlatformToken ? "Update Platform Token" : "Save Platform Token") { savePlatformToken() }
            Button("Remove Platform Token") { removePlatformToken() }
                .disabled(!billing.hasPlatformToken)
            Button("Test Connection") { testConnection() }
                .disabled(!billing.hasPlatformToken)
        }
        Text(connectionStatus)
            .font(Typography.label)
            .foregroundStyle(billing.snapshot == nil ? .orange : .green)
        Text(last30DaysStatus)
            .font(Typography.caption)
            .foregroundStyle(accountCost.status == nil ? .white.opacity(0.5) : .orange)
        if !billing.configuredKeyLabel.isEmpty {
            Text("API Key Label: \(billing.configuredKeyLabel)")
                .font(Typography.caption).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var balanceStatus: String {
        if let error = balance.error { return error.message }
        return balance.credentialSourceLabel
    }

    private var connectionStatus: String {
        billing.connectionMessage
    }

    private var last30DaysStatus: String {
        if let status = accountCost.status { return "Last 30 days: \(status.message)" }
        guard let total = accountCost.snapshot?.total else { return "Last 30 days: —" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let amount = formatter.string(from: NSDecimalNumber(decimal: total.amount)) ?? "—"
        return "Last 30 days: \(total.currency) \(amount) · \(total.apiKeyCount) API key(s)"
    }

    private func saveAPIKey() {
        credentialMessage = nil
        do {
            try balance.saveAPIKey(apiKey)
            apiKey = ""
            Task { await balance.refresh(force: true) }
        } catch {
            credentialMessage = "DeepSeek API Key could not be saved to Keychain: \(error.localizedDescription)"
        }
    }

    private func removeAPIKey() {
        credentialMessage = nil
        do {
            try balance.removeAPIKey()
            apiKey = ""
        } catch {
            credentialMessage = "DeepSeek API Key could not be removed from Keychain: \(error.localizedDescription)"
        }
    }

    private func savePlatformToken() {
        credentialMessage = nil
        do {
            try billing.saveToken(platformToken)
            platformToken = ""
        } catch {
            credentialMessage = "Platform token could not be saved to Keychain: \(error.localizedDescription)"
        }
    }

    private func removePlatformToken() {
        credentialMessage = nil
        do {
            try billing.removeToken()
            platformToken = ""
        } catch {
            credentialMessage = "Platform token could not be removed from Keychain: \(error.localizedDescription)"
        }
    }

    private func testConnection() {
        credentialMessage = nil
        billing.configure(trackingID: trackingID, keyLabel: keyLabel)
        Task { await billing.refresh() }
        Task { await accountCost.refresh(force: true) }
    }
}
