import Combine
import Foundation
import Security

struct DeepSeekWorkerUsage: Equatable {
    var requests = 0
    var cacheHitTokens = 0
    var cacheMissTokens = 0
    var outputTokens = 0

    var inputTokens: Int { cacheHitTokens + cacheMissTokens }
    var totalTokens: Int { inputTokens + outputTokens }
    var cacheHitRate: Double? {
        let input = inputTokens
        return input > 0 ? Double(cacheHitTokens) / Double(input) : nil
    }

    mutating func add(_ other: DeepSeekWorkerUsage) throws {
        requests = try Self.sum(requests, other.requests)
        cacheHitTokens = try Self.sum(cacheHitTokens, other.cacheHitTokens)
        cacheMissTokens = try Self.sum(cacheMissTokens, other.cacheMissTokens)
        outputTokens = try Self.sum(outputTokens, other.outputTokens)
    }

    private static func sum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard lhs >= 0, rhs >= 0, !result.overflow else {
            throw DeepSeekPlatformUsageError.invalidResponseSchema
        }
        return result.partialValue
    }
}

struct DeepSeekWorkerModelUsage: Equatable, Identifiable {
    let model: String
    var usage: DeepSeekWorkerUsage
    var id: String { model }
}

struct DeepSeekWorkerBillingPeriod: Equatable {
    let start: Date
    let end: Date
    let timezoneOffsetSeconds: Int
    let usage: DeepSeekWorkerUsage
    let actualCostCNY: Decimal?
    let costError: DeepSeekPlatformUsageError?
    let models: [DeepSeekWorkerModelUsage]
    let hasMatchingSeries: Bool
    /// Distinct API keys the numbers were aggregated over: 1 for a
    /// tracked-key period, N for an account-wide one.
    let apiKeyCount: Int
}

struct DeepSeekWorkerBillingSnapshot: Equatable {
    let keyLabel: String
    let trackingID: String
    let today: DeepSeekWorkerBillingPeriod
    let month: DeepSeekWorkerBillingPeriod
    let refreshedAt: Date
}

/// Account-wide token usage for the current day and month (second page), with
/// the per-period billed cost. Same local-calendar ranges as the Worker view —
/// only the scope is account-wide.
struct DeepSeekAccountUsageSnapshot: Equatable {
    let today: DeepSeekWorkerBillingPeriod
    let month: DeepSeekWorkerBillingPeriod
    let refreshedAt: Date
}

enum DeepSeekPlatformUsageError: Error, Equatable {
    case noPlatformToken
    case trackingIDRequired
    case unauthorized
    case networkFailure
    case keychainFailure(Int, String)
    case invalidResponseSchema
    case platformBusinessError(Int, String)
    case amountUnavailable
    case costUnavailable
    case serverError(Int)

    var message: String {
        switch self {
        case .noPlatformToken: return "Platform login token required"
        case .trackingIDRequired: return "Tracking ID required"
        case .unauthorized: return "Platform login token expired or invalid"
        case .networkFailure: return "Network failure while contacting DeepSeek Platform"
        case .keychainFailure(let status, let detail): return "Keychain OSStatus \(status): \(detail)"
        case .invalidResponseSchema: return "DeepSeek Platform returned an unsupported response"
        case .platformBusinessError(let code, let detail):
            return detail.isEmpty ? "DeepSeek Platform business error \(code)"
                : "DeepSeek Platform business error \(code): \(detail)"
        case .amountUnavailable: return "Token usage is unavailable"
        case .costUnavailable: return "Actual cost is unavailable"
        case .serverError(let status): return "DeepSeek Platform HTTP \(status)"
        }
    }
}

struct DeepSeekPlatformTokenStoreError: LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
        return "Keychain OSStatus \(status): \(detail)"
    }
}

struct DeepSeekBillingRange: Equatable {
    let start: Date
    let end: Date
    let timezoneOffsetSeconds: Int

    static func today(now: Date = Date(), calendar: Calendar = .current) -> DeepSeekBillingRange {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return DeepSeekBillingRange(start: start, end: end,
                                    timezoneOffsetSeconds: calendar.timeZone.secondsFromGMT(for: now))
    }

    static func month(now: Date = Date(), calendar: Calendar = .current) -> DeepSeekBillingRange {
        let components = calendar.dateComponents([.year, .month], from: now)
        let start = calendar.date(from: components) ?? calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(31 * 86400)
        return DeepSeekBillingRange(start: start, end: end,
                                    timezoneOffsetSeconds: calendar.timeZone.secondsFromGMT(for: now))
    }

    /// Rolling 30 local calendar days *including today*: start is 29 days ago
    /// at local midnight, end is tomorrow at local midnight.
    static func last30Days(now: Date = Date(), calendar: Calendar = .current) -> DeepSeekBillingRange {
        let todayStart = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -29, to: todayStart)
            ?? todayStart.addingTimeInterval(-29 * 86400)
        let end = calendar.date(byAdding: .day, value: 1, to: todayStart)
            ?? todayStart.addingTimeInterval(86400)
        return DeepSeekBillingRange(start: start, end: end,
                                    timezoneOffsetSeconds: calendar.timeZone.secondsFromGMT(for: now))
    }
}

/// Which series the Platform cost response is summed over.
///
/// `by_api_key/cost` returns the account's series grouped by API key, so
/// `.accountWide` sums them all. The endpoint is not asked to filter by key —
/// the earlier single-worker view filtered client-side, which is what
/// `.trackingID` preserves.
enum DeepSeekCostScope: Equatable {
    case accountWide
    case trackingID(String)
}

struct DeepSeekCostTotal: Equatable {
    let amount: Decimal
    let currency: String
    let seriesCount: Int
    let apiKeyCount: Int

    var hasMatchingSeries: Bool { seriesCount > 0 }
}

/// Which series the Platform amount response is aggregated over.
///
/// `.accountWide` sums every series the account-level endpoint returns (all
/// API keys); `.trackedKey` keeps the single-worker view.
enum DeepSeekUsageScope: Equatable {
    case accountWide
    case trackedKey(String)
}

/// Aggregated token usage plus the provenance the UI needs to label its scope.
struct DeepSeekUsageTotal: Equatable {
    let usage: DeepSeekWorkerUsage
    let models: [DeepSeekWorkerModelUsage]
    let seriesCount: Int
    let apiKeyCount: Int

    var hasMatchingSeries: Bool { seriesCount > 0 }
}

struct DeepSeekAccountCostSnapshot: Equatable {
    let range: DeepSeekBillingRange
    let total: DeepSeekCostTotal
    let refreshedAt: Date
}

protocol DeepSeekPlatformTokenStoring {
    func containsToken() -> Bool
    func loadToken() throws -> String?
    func saveToken(_ token: String) throws
    func removeToken() throws
}

struct DeepSeekPlatformTokenKeychain: DeepSeekPlatformTokenStoring {
    static let service = "dev.codexisland.CodexIsland.deepseek-platform"
    static let account = "platform-login-token"

    func containsToken() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func loadToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw DeepSeekPlatformTokenStoreError(status: status)
        }
        return token
    }

    func saveToken(_ token: String) throws {
        guard !token.isEmpty, let data = token.data(using: .utf8) else {
            throw DeepSeekPlatformTokenStoreError(status: errSecParam)
        }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let update = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw DeepSeekPlatformTokenStoreError(status: update) }
        var addition = identity
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addition as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeepSeekPlatformTokenStoreError(status: status) }
    }

    func removeToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeepSeekPlatformTokenStoreError(status: status)
        }
    }
}

enum DeepSeekPlatformUsageClient {
    typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    private static let amountEndpoint = URL(string: "https://platform.deepseek.com/api/v0/usage/by_api_key/amount")!
    private static let costEndpoint = URL(string: "https://platform.deepseek.com/api/v0/usage/by_api_key/cost")!

    static func fetch(
        token: String,
        trackingID: String,
        keyLabel: String = "",
        now: Date = Date(),
        calendar: Calendar = .current,
        send: @escaping Send = { try await URLSession.shared.data(for: $0) }
    ) async throws -> DeepSeekWorkerBillingSnapshot {
        let normalizedToken = normalizeToken(token)
        let normalizedTrackingID = trackingID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { throw DeepSeekPlatformUsageError.noPlatformToken }
        guard !normalizedTrackingID.isEmpty else { throw DeepSeekPlatformUsageError.trackingIDRequired }

        let todayRange = DeepSeekBillingRange.today(now: now, calendar: calendar)
        let monthRange = DeepSeekBillingRange.month(now: now, calendar: calendar)
        let monthData = try await request(endpoint: amountEndpoint, range: monthRange, token: normalizedToken,
                                          unavailableError: .amountUnavailable, send: send)
        let monthAmount = try parseAmount(monthData, scope: .trackedKey(normalizedTrackingID))

        let todayData = try await request(endpoint: amountEndpoint, range: todayRange, token: normalizedToken,
                                          unavailableError: .amountUnavailable, send: send)
        let todayAmount = try parseAmount(todayData, scope: .trackedKey(normalizedTrackingID))

        async let todayCost = fetchCost(range: todayRange, token: normalizedToken,
                                        trackingID: normalizedTrackingID, send: send)
        async let monthCost = fetchCost(range: monthRange, token: normalizedToken,
                                        trackingID: normalizedTrackingID, send: send)
        let costs = await (todayCost, monthCost)

        return DeepSeekWorkerBillingSnapshot(
            keyLabel: keyLabel,
            trackingID: normalizedTrackingID,
            today: DeepSeekWorkerBillingPeriod(
                start: todayRange.start, end: todayRange.end,
                timezoneOffsetSeconds: todayRange.timezoneOffsetSeconds,
                usage: todayAmount.usage, actualCostCNY: costs.0.value,
                costError: costs.0.error, models: todayAmount.models,
                hasMatchingSeries: todayAmount.hasMatchingSeries,
                apiKeyCount: todayAmount.apiKeyCount
            ),
            month: DeepSeekWorkerBillingPeriod(
                start: monthRange.start, end: monthRange.end,
                timezoneOffsetSeconds: monthRange.timezoneOffsetSeconds,
                usage: monthAmount.usage, actualCostCNY: costs.1.value,
                costError: costs.1.error, models: monthAmount.models,
                hasMatchingSeries: monthAmount.hasMatchingSeries,
                apiKeyCount: monthAmount.apiKeyCount
            ),
            refreshedAt: now
        )
    }

    /// Account-wide billed cost for a range (defaults to the last 30 local
    /// calendar days). Every series the account-level endpoint returns is
    /// summed — no tracking_id is required, and none is sent.
    static func fetchAccountCost(
        token: String,
        range: DeepSeekBillingRange? = nil,
        now: Date = Date(),
        calendar: Calendar = .current,
        send: @escaping Send = { try await URLSession.shared.data(for: $0) }
    ) async throws -> DeepSeekAccountCostSnapshot {
        let normalizedToken = normalizeToken(token)
        guard !normalizedToken.isEmpty else { throw DeepSeekPlatformUsageError.noPlatformToken }
        let window = range ?? DeepSeekBillingRange.last30Days(now: now, calendar: calendar)
        let data = try await request(endpoint: costEndpoint, range: window, token: normalizedToken,
                                     unavailableError: .costUnavailable, send: send)
        return DeepSeekAccountCostSnapshot(range: window,
                                           total: try parseCost(data, scope: .accountWide),
                                           refreshedAt: now)
    }

    /// Account-wide token usage and billed cost for the current day and month.
    /// Every series the account-level endpoints return is aggregated — no
    /// tracking_id is required, and none is sent. The date ranges are the same
    /// local-calendar windows the Worker view used.
    static func fetchAccountUsage(
        token: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        send: @escaping Send = { try await URLSession.shared.data(for: $0) }
    ) async throws -> DeepSeekAccountUsageSnapshot {
        let normalizedToken = normalizeToken(token)
        guard !normalizedToken.isEmpty else { throw DeepSeekPlatformUsageError.noPlatformToken }

        let todayRange = DeepSeekBillingRange.today(now: now, calendar: calendar)
        let monthRange = DeepSeekBillingRange.month(now: now, calendar: calendar)
        let monthData = try await request(endpoint: amountEndpoint, range: monthRange, token: normalizedToken,
                                          unavailableError: .amountUnavailable, send: send)
        let monthAmount = try parseAmount(monthData, scope: .accountWide)
        let todayData = try await request(endpoint: amountEndpoint, range: todayRange, token: normalizedToken,
                                          unavailableError: .amountUnavailable, send: send)
        let todayAmount = try parseAmount(todayData, scope: .accountWide)

        async let todayCost = fetchAccountPeriodCost(range: todayRange, token: normalizedToken, send: send)
        async let monthCost = fetchAccountPeriodCost(range: monthRange, token: normalizedToken, send: send)
        let costs = await (todayCost, monthCost)

        return DeepSeekAccountUsageSnapshot(
            today: DeepSeekWorkerBillingPeriod(
                start: todayRange.start, end: todayRange.end,
                timezoneOffsetSeconds: todayRange.timezoneOffsetSeconds,
                usage: todayAmount.usage, actualCostCNY: costs.0.value,
                costError: costs.0.error, models: todayAmount.models,
                hasMatchingSeries: todayAmount.hasMatchingSeries,
                apiKeyCount: todayAmount.apiKeyCount
            ),
            month: DeepSeekWorkerBillingPeriod(
                start: monthRange.start, end: monthRange.end,
                timezoneOffsetSeconds: monthRange.timezoneOffsetSeconds,
                usage: monthAmount.usage, actualCostCNY: costs.1.value,
                costError: costs.1.error, models: monthAmount.models,
                hasMatchingSeries: monthAmount.hasMatchingSeries,
                apiKeyCount: monthAmount.apiKeyCount
            ),
            refreshedAt: now
        )
    }

    /// Aggregates the official token buckets over the requested scope.
    ///
    /// The amount endpoint returns component counters only
    /// (`PROMPT_CACHE_HIT_TOKEN`, `PROMPT_CACHE_MISS_TOKEN`, `RESPONSE_TOKEN`
    /// and the call counter `REQUEST`) — there is no pre-summed total field —
    /// so adding the three token components once per bucket cannot double
    /// count. `REQUEST` stays out of the token total.
    static func parseAmount(_ data: Data, scope: DeepSeekUsageScope) throws -> DeepSeekUsageTotal {
        let series = try parsedAmountSeries(data)
        var total = DeepSeekWorkerUsage()
        var models: [String: DeepSeekWorkerUsage] = [:]
        var seriesCount = 0
        var apiKeys = Set<String>()

        for item in series {
            if case .trackedKey(let trackingID) = scope, item.trackingID != trackingID { continue }
            seriesCount += 1
            apiKeys.insert(item.trackingID)
            var modelUsage = models[item.model] ?? DeepSeekWorkerUsage()
            for bucket in item.buckets {
                guard let usage = bucket["usage"] as? [String: Any] else {
                    throw DeepSeekPlatformUsageError.invalidResponseSchema
                }
                let recognized = ["PROMPT_CACHE_HIT_TOKEN", "PROMPT_CACHE_MISS_TOKEN", "RESPONSE_TOKEN", "REQUEST"]
                    .contains { usage[$0] != nil }
                guard recognized else { throw DeepSeekPlatformUsageError.invalidResponseSchema }
                let entry = DeepSeekWorkerUsage(
                    requests: try integer(usage["REQUEST"]),
                    cacheHitTokens: try integer(usage["PROMPT_CACHE_HIT_TOKEN"]),
                    cacheMissTokens: try integer(usage["PROMPT_CACHE_MISS_TOKEN"]),
                    outputTokens: try integer(usage["RESPONSE_TOKEN"])
                )
                try total.add(entry)
                try modelUsage.add(entry)
            }
            models[item.model] = modelUsage
        }
        return DeepSeekUsageTotal(
            usage: total,
            models: models.map { DeepSeekWorkerModelUsage(model: $0.key, usage: $0.value) }
                .sorted { $0.usage.totalTokens > $1.usage.totalTokens },
            seriesCount: seriesCount,
            apiKeyCount: apiKeys.count
        )
    }

    /// Single-worker amount, kept for the Worker billing screen and its tests.
    static func parseAmount(
        _ data: Data,
        trackingID: String
    ) throws -> (usage: DeepSeekWorkerUsage, models: [DeepSeekWorkerModelUsage], hasMatchingSeries: Bool) {
        let total = try parseAmount(data, scope: .trackedKey(trackingID))
        return (total.usage, total.models, total.hasMatchingSeries)
    }

    /// Sums billed cost over the requested scope. `.accountWide` adds every
    /// series the account-level endpoint returns (all API keys); no per-key
    /// filter is applied here because the request carries none either.
    static func parseCost(_ data: Data, scope: DeepSeekCostScope) throws -> DeepSeekCostTotal {
        let block = try parsedCostBlock(data)
        var total = Decimal.zero
        var seriesCount = 0
        var apiKeys = Set<String>()
        for item in block.series {
            if case .trackingID(let trackingID) = scope, item.trackingID != trackingID { continue }
            seriesCount += 1
            apiKeys.insert(item.trackingID)
            for bucket in item.buckets {
                guard let rawCost = bucket["cost"], let value = try decimal(rawCost) else {
                    throw DeepSeekPlatformUsageError.invalidResponseSchema
                }
                total += value
            }
        }
        return DeepSeekCostTotal(amount: total, currency: block.currency,
                                 seriesCount: seriesCount, apiKeyCount: apiKeys.count)
    }

    /// Single-worker cost, kept for the Worker billing screen and its tests.
    static func parseCost(_ data: Data, trackingID: String) throws -> Decimal {
        try parseCost(data, scope: .trackingID(trackingID)).amount
    }

    private static func fetchCost(
        range: DeepSeekBillingRange,
        token: String,
        trackingID: String,
        send: @escaping Send
    ) async -> (value: Decimal?, error: DeepSeekPlatformUsageError?) {
        do {
            let data = try await request(endpoint: costEndpoint, range: range, token: token,
                                         unavailableError: .costUnavailable, send: send)
            return (try parseCost(data, trackingID: trackingID), nil)
        } catch let error as DeepSeekPlatformUsageError {
            return (nil, error)
        } catch {
            return (nil, .costUnavailable)
        }
    }

    /// Account-wide cost for one period; a failure here never fails the token
    /// totals it is displayed beside.
    private static func fetchAccountPeriodCost(
        range: DeepSeekBillingRange,
        token: String,
        send: @escaping Send
    ) async -> (value: Decimal?, error: DeepSeekPlatformUsageError?) {
        do {
            let data = try await request(endpoint: costEndpoint, range: range, token: token,
                                         unavailableError: .costUnavailable, send: send)
            return (try parseCost(data, scope: .accountWide).amount, nil)
        } catch let error as DeepSeekPlatformUsageError {
            return (nil, error)
        } catch {
            return (nil, .costUnavailable)
        }
    }

    private static func request(
        endpoint: URL,
        range: DeepSeekBillingRange,
        token: String,
        unavailableError: DeepSeekPlatformUsageError,
        send: @escaping Send
    ) async throws -> Data {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "start", value: String(Int64(range.start.timeIntervalSince1970))),
            URLQueryItem(name: "end", value: String(Int64(range.end.timeIntervalSince1970))),
            URLQueryItem(name: "tz", value: String(range.timezoneOffsetSeconds)),
        ]
        guard let url = components.url else { throw DeepSeekPlatformUsageError.invalidResponseSchema }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web", forHTTPHeaderField: "x-client-platform")
        request.setValue("Mozilla/5.0 CodexIsland", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            throw DeepSeekPlatformUsageError.networkFailure
        }
        guard let http = response as? HTTPURLResponse else { throw DeepSeekPlatformUsageError.networkFailure }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw DeepSeekPlatformUsageError.unauthorized
        case 404: throw unavailableError
        case 500...599: throw DeepSeekPlatformUsageError.serverError(http.statusCode)
        default: throw DeepSeekPlatformUsageError.invalidResponseSchema
        }
    }

    private struct Series {
        let trackingID: String
        let model: String
        let buckets: [[String: Any]]
    }

    private static func businessData(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outerCode = exactInteger(root["code"]),
              let envelope = root["data"] as? [String: Any],
              let businessCode = exactInteger(envelope["biz_code"]) else {
            throw DeepSeekPlatformUsageError.invalidResponseSchema
        }
        let businessMessage = (envelope["biz_msg"] as? String) ?? ""
        guard outerCode == 0 else {
            throw DeepSeekPlatformUsageError.platformBusinessError(outerCode, (root["msg"] as? String) ?? "")
        }
        guard businessCode == 0 else {
            throw DeepSeekPlatformUsageError.platformBusinessError(businessCode, businessMessage)
        }
        guard let business = envelope["biz_data"] as? [String: Any] else {
            throw DeepSeekPlatformUsageError.invalidResponseSchema
        }
        return business
    }

    private static func parsedAmountSeries(_ data: Data) throws -> [Series] {
        let business = try businessData(data)
        guard let rawSeries = business["series"] as? [[String: Any]] else {
            throw DeepSeekPlatformUsageError.invalidResponseSchema
        }
        return try parseSeries(rawSeries)
    }

    private static func parsedCostSeries(_ data: Data) throws -> [Series] {
        try parsedCostBlock(data).series
    }

    /// The cost envelope carries one block per currency. CNY is the Platform
    /// billing currency for this account; other currency blocks are never
    /// added into it.
    private static func parsedCostBlock(_ data: Data) throws -> (currency: String, series: [Series]) {
        let business = try businessData(data)
        guard let currencies = business["data"] as? [[String: Any]],
              let cny = currencies.first(where: { ($0["currency"] as? String) == "CNY" }),
              let rawSeries = cny["series"] as? [[String: Any]] else {
            throw DeepSeekPlatformUsageError.invalidResponseSchema
        }
        return ("CNY", try parseSeries(rawSeries))
    }

    private static func parseSeries(_ rawSeries: [[String: Any]]) throws -> [Series] {
        return try rawSeries.map { item in
            guard let rawKey = item["api_key"] as? [String: Any],
                  let trackingID = rawKey["tracking_id"] as? String, !trackingID.isEmpty,
                  let buckets = item["buckets"] as? [[String: Any]] else {
                throw DeepSeekPlatformUsageError.invalidResponseSchema
            }
            let model = (item["model"] as? String) ?? (item["name"] as? String) ?? "Unknown model"
            return Series(trackingID: trackingID, model: model, buckets: buckets)
        }
    }

    static func normalizeToken(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else {
            return trimmed
        }
        return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func exactInteger(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber else { return nil }
        let value = number.int64Value
        guard NSNumber(value: value) == number, value >= Int64(Int.min), value <= Int64(Int.max) else { return nil }
        return Int(value)
    }

    private static func integer(_ raw: Any?) throws -> Int {
        guard let raw else { return 0 }
        let value: Int64
        if let number = raw as? NSNumber {
            value = number.int64Value
            guard NSNumber(value: value) == number else { throw DeepSeekPlatformUsageError.invalidResponseSchema }
        } else if let text = raw as? String, !text.isEmpty,
                  text.allSatisfy({ $0.isNumber }), let parsed = Int64(text) {
            value = parsed
        } else {
            throw DeepSeekPlatformUsageError.invalidResponseSchema
        }
        guard value >= 0, value <= Int64(Int.max) else { throw DeepSeekPlatformUsageError.invalidResponseSchema }
        return Int(value)
    }

    private static func decimal(_ raw: Any) throws -> Decimal? {
        let text: String
        if let value = raw as? String {
            text = value
        } else if let value = raw as? NSNumber {
            text = value.stringValue
        } else {
            throw DeepSeekPlatformUsageError.invalidResponseSchema
        }
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value >= 0 else {
            throw DeepSeekPlatformUsageError.invalidResponseSchema
        }
        return value
    }
}

@MainActor
final class DeepSeekWorkerBillingStore: ObservableObject {
    static let shared = DeepSeekWorkerBillingStore()

    static let keyLabelKey = "MacIsland.deepSeekWorkerAPIKeyName"
    static let trackingIDKey = "MacIsland.deepSeekWorkerTrackingID"

    @Published private(set) var snapshot: DeepSeekWorkerBillingSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var status: DeepSeekPlatformUsageError?
    @Published private(set) var hasPlatformToken: Bool
    @Published private(set) var configuredTrackingID: String
    @Published private(set) var configuredKeyLabel: String

    private let defaults: UserDefaults
    private let tokenStore: DeepSeekPlatformTokenStoring
    private let send: DeepSeekPlatformUsageClient.Send

    init(
        defaults: UserDefaults = .standard,
        tokenStore: DeepSeekPlatformTokenStoring = DeepSeekPlatformTokenKeychain(),
        send: @escaping DeepSeekPlatformUsageClient.Send = { try await URLSession.shared.data(for: $0) }
    ) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.send = send
        configuredTrackingID = defaults.string(forKey: Self.trackingIDKey) ?? ""
        configuredKeyLabel = defaults.string(forKey: Self.keyLabelKey) ?? ""
        hasPlatformToken = tokenStore.containsToken()
        status = hasPlatformToken ? (configuredTrackingID.isEmpty ? .trackingIDRequired : nil) : .noPlatformToken
    }

    func saveToken(_ token: String) throws {
        let normalized = DeepSeekPlatformUsageClient.normalizeToken(token)
        guard !normalized.isEmpty else { throw DeepSeekPlatformUsageError.noPlatformToken }
        try tokenStore.saveToken(normalized)
        hasPlatformToken = true
        status = configuredTrackingID.isEmpty ? .trackingIDRequired : nil
    }

    func configure(trackingID: String, keyLabel: String) {
        configuredTrackingID = trackingID.trimmingCharacters(in: .whitespacesAndNewlines)
        configuredKeyLabel = keyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(configuredTrackingID, forKey: Self.trackingIDKey)
        defaults.set(configuredKeyLabel, forKey: Self.keyLabelKey)
        if configuredTrackingID.isEmpty {
            snapshot = nil
            status = .trackingIDRequired
        }
    }

    func removeToken() throws {
        try tokenStore.removeToken()
        hasPlatformToken = false
        snapshot = nil
        status = .noPlatformToken
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            guard let token = try tokenStore.loadToken(), !token.isEmpty else {
                throw DeepSeekPlatformUsageError.noPlatformToken
            }
            guard !configuredTrackingID.isEmpty else {
                throw DeepSeekPlatformUsageError.trackingIDRequired
            }
            let fetched = try await DeepSeekPlatformUsageClient.fetch(
                token: token,
                trackingID: configuredTrackingID,
                keyLabel: configuredKeyLabel,
                send: send
            )
            snapshot = fetched
            hasPlatformToken = true
            status = nil
        } catch let error as DeepSeekPlatformUsageError {
            snapshot = nil
            status = error
            if error == .noPlatformToken { hasPlatformToken = false }
        } catch let error as DeepSeekPlatformTokenStoreError {
            snapshot = nil
            let detail = SecCopyErrorMessageString(error.status, nil) as String? ?? "Unknown Keychain error"
            status = .keychainFailure(Int(error.status), detail)
        } catch {
            snapshot = nil
            status = .networkFailure
        }
    }

    var connectionMessage: String {
        if loading { return "Testing Platform Billing…" }
        guard let snapshot else { return status?.message ?? "Platform Billing unavailable" }
        let costErrors = [snapshot.today.costError, snapshot.month.costError].compactMap { $0 }
        if let first = costErrors.first {
            return "Connected · Tokens available · Actual cost unavailable (\(first.message))"
        }
        if !snapshot.today.hasMatchingSeries && !snapshot.month.hasMatchingSeries {
            return "Connected · No usage in selected period"
        }
        return "Connected"
    }
}

/// First-page "last 30 days" cost, kept separate from
/// `DeepSeekWorkerBillingStore` so the two surfaces fail independently: a
/// missing Worker tracking ID never blanks the account cost tile, and a
/// failing account cost query never blanks the balance.
@MainActor
final class DeepSeekAccountCostStore: ObservableObject {
    static let shared = DeepSeekAccountCostStore()

    static let minimumRefreshInterval: TimeInterval = 300

    @Published private(set) var snapshot: DeepSeekAccountCostSnapshot?
    @Published private(set) var status: DeepSeekPlatformUsageError?
    @Published private(set) var loading = false
    @Published private(set) var hasPlatformToken: Bool

    private let tokenStore: DeepSeekPlatformTokenStoring
    private let send: DeepSeekPlatformUsageClient.Send
    private let calendar: Calendar
    private let now: () -> Date
    private var lastAttempt: Date?

    init(
        tokenStore: DeepSeekPlatformTokenStoring = DeepSeekPlatformTokenKeychain(),
        send: @escaping DeepSeekPlatformUsageClient.Send = { try await URLSession.shared.data(for: $0) },
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.tokenStore = tokenStore
        self.send = send
        self.calendar = calendar
        self.now = now
        hasPlatformToken = tokenStore.containsToken()
        status = hasPlatformToken ? nil : .noPlatformToken
    }

    func refresh(force: Bool = false) async {
        guard !loading else { return }
        let moment = now()
        if !force, let lastAttempt, moment.timeIntervalSince(lastAttempt) < Self.minimumRefreshInterval {
            return
        }
        lastAttempt = moment
        loading = true
        defer { loading = false }

        // Screen-recording demo mode: fixed, plausible account figures so the
        // first page renders both tiles without touching the network.
        if AppEnvironment.isDemo {
            snapshot = DeepSeekAccountCostSnapshot(
                range: DeepSeekBillingRange.last30Days(now: moment, calendar: calendar),
                total: DeepSeekCostTotal(amount: Decimal(1842) / 100, currency: "CNY",
                                         seriesCount: 5, apiKeyCount: 3),
                refreshedAt: moment)
            status = nil
            return
        }

        do {
            guard let token = try tokenStore.loadToken(),
                  !DeepSeekPlatformUsageClient.normalizeToken(token).isEmpty else {
                hasPlatformToken = false
                throw DeepSeekPlatformUsageError.noPlatformToken
            }
            hasPlatformToken = true
            let fetched = try await DeepSeekPlatformUsageClient.fetchAccountCost(
                token: token, now: moment, calendar: calendar, send: send)
            snapshot = fetched
            status = nil
        } catch let error as DeepSeekPlatformUsageError {
            snapshot = nil
            status = error
            if error == .noPlatformToken { hasPlatformToken = false }
        } catch let error as DeepSeekPlatformTokenStoreError {
            snapshot = nil
            let detail = SecCopyErrorMessageString(error.status, nil) as String? ?? "Unknown Keychain error"
            status = .keychainFailure(Int(error.status), detail)
        } catch {
            snapshot = nil
            status = .networkFailure
        }
    }
}

/// Second-page account-wide token totals (today + this month, unchanged local
/// calendar ranges) with the per-period billed cost. Deliberately separate
/// from `DeepSeekAccountCostStore` so the 30-day cost tile and the token
/// totals never blank each other.
@MainActor
final class DeepSeekAccountUsageStore: ObservableObject {
    static let shared = DeepSeekAccountUsageStore()

    static let minimumRefreshInterval: TimeInterval = 300

    @Published private(set) var snapshot: DeepSeekAccountUsageSnapshot?
    @Published private(set) var status: DeepSeekPlatformUsageError?
    @Published private(set) var loading = false
    @Published private(set) var hasPlatformToken: Bool

    private let tokenStore: DeepSeekPlatformTokenStoring
    private let send: DeepSeekPlatformUsageClient.Send
    private let calendar: Calendar
    private let now: () -> Date
    private var lastAttempt: Date?

    init(
        tokenStore: DeepSeekPlatformTokenStoring = DeepSeekPlatformTokenKeychain(),
        send: @escaping DeepSeekPlatformUsageClient.Send = { try await URLSession.shared.data(for: $0) },
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.tokenStore = tokenStore
        self.send = send
        self.calendar = calendar
        self.now = now
        hasPlatformToken = tokenStore.containsToken()
        status = hasPlatformToken ? nil : .noPlatformToken
    }

    func refresh(force: Bool = false) async {
        guard !loading else { return }
        let moment = now()
        if !force, let lastAttempt, moment.timeIntervalSince(lastAttempt) < Self.minimumRefreshInterval {
            return
        }
        lastAttempt = moment
        loading = true
        defer { loading = false }

        if AppEnvironment.isDemo {
            snapshot = DeepSeekAccountUsageSnapshot(
                today: Self.demoPeriod(DeepSeekBillingRange.today(now: moment, calendar: calendar),
                                       tokens: 12_340_000, cost: Decimal(234) / 100),
                month: Self.demoPeriod(DeepSeekBillingRange.month(now: moment, calendar: calendar),
                                       tokens: 210_000_000, cost: Decimal(4120) / 100),
                refreshedAt: moment)
            status = nil
            return
        }

        do {
            guard let token = try tokenStore.loadToken(),
                  !DeepSeekPlatformUsageClient.normalizeToken(token).isEmpty else {
                hasPlatformToken = false
                throw DeepSeekPlatformUsageError.noPlatformToken
            }
            hasPlatformToken = true
            let fetched = try await DeepSeekPlatformUsageClient.fetchAccountUsage(
                token: token, now: moment, calendar: calendar, send: send)
            snapshot = fetched
            status = nil
        } catch let error as DeepSeekPlatformUsageError {
            snapshot = nil
            status = error
            if error == .noPlatformToken { hasPlatformToken = false }
        } catch let error as DeepSeekPlatformTokenStoreError {
            snapshot = nil
            let detail = SecCopyErrorMessageString(error.status, nil) as String? ?? "Unknown Keychain error"
            status = .keychainFailure(Int(error.status), detail)
        } catch {
            snapshot = nil
            status = .networkFailure
        }
    }

    private static func demoPeriod(_ range: DeepSeekBillingRange, tokens: Int, cost: Decimal) -> DeepSeekWorkerBillingPeriod {
        let cacheHit = tokens * 9 / 10
        let cacheMiss = tokens / 20
        return DeepSeekWorkerBillingPeriod(
            start: range.start, end: range.end,
            timezoneOffsetSeconds: range.timezoneOffsetSeconds,
            usage: DeepSeekWorkerUsage(requests: 120, cacheHitTokens: cacheHit,
                                       cacheMissTokens: cacheMiss, outputTokens: tokens - cacheHit - cacheMiss),
            actualCostCNY: cost, costError: nil,
            models: [DeepSeekWorkerModelUsage(model: "deepseek-chat", usage: DeepSeekWorkerUsage())],
            hasMatchingSeries: true, apiKeyCount: 3)
    }

    var connectionMessage: String {
        if loading { return "Testing Platform Billing…" }
        guard let snapshot else { return status?.message ?? "Platform Billing unavailable" }
        let costErrors = [snapshot.today.costError, snapshot.month.costError].compactMap { $0 }
        if let first = costErrors.first {
            return "Connected · Tokens available · Actual cost unavailable (\(first.message))"
        }
        if !snapshot.today.hasMatchingSeries && !snapshot.month.hasMatchingSeries {
            return "Connected · No usage in selected period"
        }
        return "Connected"
    }
}
