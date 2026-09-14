import Foundation

struct DeepSeekBalance: Decodable {
    let is_available: Bool
    let balance_infos: [Entry]

    struct Entry: Decodable {
        let currency: String
        let total_balance: String
        let granted_balance: String
        let topped_up_balance: String

        var formatted: String { (currency == "CNY" ? "¥" : currency == "USD" ? "$" : currency + " ") + total_balance }
    }

    static func decode(_ data: Data) throws -> DeepSeekBalance {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard !value.balance_infos.isEmpty, value.balance_infos.allSatisfy({ entry in
            !entry.currency.isEmpty && [entry.total_balance, entry.granted_balance, entry.topped_up_balance]
                .allSatisfy { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) != nil }
        }) else { throw URLError(.cannotParseResponse) }
        return value
    }
}

enum DeepSeekBalanceClient {
    static func fetch() async throws -> DeepSeekBalance {
        let path = UserDefaults.standard.string(forKey: "MacIsland.deepSeekKeyFile")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/key/key").path
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: "sk-[A-Za-z0-9_-]+")
        let keys = Set(regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).compactMap {
            Range($0.range, in: raw).map { String(raw[$0]) }
        })
        guard keys.count == 1, let key = keys.first else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.timeoutInterval = 20
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw BalanceError.http(http.statusCode) }
        return try DeepSeekBalance.decode(data)
    }

    enum BalanceError: Error { case http(Int) }
}

@MainActor
final class DeepSeekBalanceStore: ObservableObject {
    static let shared = DeepSeekBalanceStore()
    @Published private(set) var balance: DeepSeekBalance?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var updatedAt: Date?
    private var cooldown: Date?

    var headline: String { balance?.balance_infos.first?.formatted ?? "—" }

    func refresh() async {
        guard !loading, cooldown.map({ $0 <= Date() }) ?? true else { return }
        loading = true
        defer { loading = false }
        if AppEnvironment.isDemo {
            balance = DeepSeekBalance(is_available: true, balance_infos: [
                .init(currency: "CNY", total_balance: "100.00", granted_balance: "0.00", topped_up_balance: "100.00")
            ])
            updatedAt = Date()
            error = nil
            return
        }
        do {
            balance = try await DeepSeekBalanceClient.fetch()
            updatedAt = Date()
            error = nil
        } catch DeepSeekBalanceClient.BalanceError.http(let status) {
            if status == 401 || status == 403 { balance = nil; updatedAt = nil }
            if status == 429 { cooldown = Date().addingTimeInterval(900) }
            error = "DeepSeek HTTP \(status)"
        } catch {
            self.error = L10n.tr("Balance unavailable; check key file and connection")
        }
    }
}
