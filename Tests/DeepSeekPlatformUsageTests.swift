import Foundation

enum SyntheticNetworkError: Error { case offline }

final class MockPlatformTokenStore: DeepSeekPlatformTokenStoring {
    var token: String?
    var saves = 0
    func containsToken() -> Bool { token != nil }
    func loadToken() throws -> String? { token }
    func saveToken(_ token: String) throws { saves += 1; self.token = token }
    func removeToken() throws { token = nil }
}

final class RequestRecorder {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); storage.append(request); lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return storage }
}

@main
struct DeepSeekPlatformUsageTests {
    static let workerID = "tracking-worker-fixture"

    static func expect(_ result: Bool, _ label: String) {
        guard result else { print("FAIL \(label)"); exit(1) }
        print("PASS \(label)")
    }

    static func response(_ url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    static func envelope(series: String) -> Data {
        Data(#"{"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":{"series":\#(series)}}}"#.utf8)
    }

    static func costEnvelope(series: String) -> Data {
        Data(#"{"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":{"data":[{"currency":"CNY","series":\#(series)}]}}}"#.utf8)
    }

    static func amountFixture() -> Data {
        envelope(series: #"""
        [
          {"api_key":{"tracking_id":"tracking-worker-fixture","name":"Display only","sensitive_id":"masked-a"},"model":"model-a","buckets":[{"usage":{"PROMPT_CACHE_HIT_TOKEN":"100","PROMPT_CACHE_MISS_TOKEN":"30","RESPONSE_TOKEN":"20","REQUEST":"2"}}]},
          {"api_key":{"tracking_id":"tracking-worker-fixture","name":"Renamed label","sensitive_id":"masked-a"},"model":"model-b","buckets":[{"usage":{"PROMPT_CACHE_HIT_TOKEN":"50","PROMPT_CACHE_MISS_TOKEN":"20","RESPONSE_TOKEN":"10","REQUEST":"1"}}]},
          {"api_key":{"tracking_id":"tracking-other-fixture","name":"Other","sensitive_id":"masked-b"},"model":"model-a","buckets":[{"usage":{"PROMPT_CACHE_HIT_TOKEN":"9000","PROMPT_CACHE_MISS_TOKEN":"9000","RESPONSE_TOKEN":"9000","REQUEST":"90"}}]}
        ]
        """#)
    }

    static func costFixture() -> Data {
        costEnvelope(series: #"""
        [
          {"api_key":{"tracking_id":"tracking-worker-fixture","name":"Display only"},"model":"model-a","buckets":[{"cost":"1.25"}]},
          {"api_key":{"tracking_id":"tracking-worker-fixture","name":"Renamed label"},"model":"model-b","buckets":[{"cost":0.75}]},
          {"api_key":{"tracking_id":"tracking-other-fixture","name":"Other"},"model":"model-a","buckets":[{"cost":"99"}]}
        ]
        """#)
    }

    /// Key A: 100 input + 20 output = 120. Key B: 200 input + 50 output = 250.
    /// Account-wide total must be 370 and must not double count components.
    static func amountScopeFixture() -> Data {
        envelope(series: #"""
        [
          {"api_key":{"tracking_id":"key-a-fixture","name":"Key A"},"model":"model-a","buckets":[{"usage":{"PROMPT_CACHE_HIT_TOKEN":"60","PROMPT_CACHE_MISS_TOKEN":"40","RESPONSE_TOKEN":"20","REQUEST":"2"}}]},
          {"api_key":{"tracking_id":"key-b-fixture","name":"Key B"},"model":"model-b","buckets":[{"usage":{"PROMPT_CACHE_HIT_TOKEN":"120","PROMPT_CACHE_MISS_TOKEN":"80","RESPONSE_TOKEN":"50","REQUEST":"3"}}]},
          {"api_key":{"tracking_id":"key-b-fixture","name":"Key B"},"model":"model-a","buckets":[{"usage":{"PROMPT_CACHE_HIT_TOKEN":"0","PROMPT_CACHE_MISS_TOKEN":"0","RESPONSE_TOKEN":"0","REQUEST":"0"}}]}
        ]
        """#)
    }

    @MainActor
    static func main() async throws {
        let parsed = try DeepSeekPlatformUsageClient.parseAmount(amountFixture(), trackingID: workerID)
        expect(parsed.hasMatchingSeries, "tracking_id directly selects Worker series")
        expect(parsed.usage.requests == 3, "REQUEST aggregates only as request count")
        expect(parsed.usage.inputTokens == 200 && parsed.usage.outputTokens == 30,
               "official token buckets map to input and output")
        expect(parsed.usage.totalTokens == 230, "REQUEST is excluded from total tokens")
        expect(parsed.models.count == 2 && Set(parsed.models.map(\.model)) == ["model-a", "model-b"],
               "all models sharing tracking_id aggregate without model filtering")
        expect(try DeepSeekPlatformUsageClient.parseCost(costFixture(), trackingID: workerID) == 2,
               "official CNY cost buckets aggregate for tracking_id")

        let empty = try DeepSeekPlatformUsageClient.parseAmount(envelope(series: "[]"), trackingID: workerID)
        expect(!empty.hasMatchingSeries && empty.usage.totalTokens == 0,
               "amount series empty means connected zero usage")
        let otherOnly = try DeepSeekPlatformUsageClient.parseAmount(
            envelope(series: #"[{"api_key":{"tracking_id":"tracking-other-fixture"},"model":"x","buckets":[]}]"#),
            trackingID: workerID)
        expect(!otherOnly.hasMatchingSeries && otherOnly.usage == DeepSeekWorkerUsage(),
               "other tracking IDs present still means zero for configured ID")
        expect(try DeepSeekPlatformUsageClient.parseCost(costEnvelope(series: "[]"),
                                                        trackingID: workerID) == 0,
               "cost with no target series is official zero CNY")

        let accountTotal = try DeepSeekPlatformUsageClient.parseCost(costFixture(), scope: .accountWide)
        expect(accountTotal.amount == 101,
               "account-wide cost sums every API key series the Platform returns")
        expect(accountTotal.seriesCount == 3 && accountTotal.apiKeyCount == 2 && accountTotal.currency == "CNY",
               "account-wide cost reports the series and API key counts the UI labels")
        let trackedTotal = try DeepSeekPlatformUsageClient.parseCost(costFixture(), scope: .trackingID(workerID))
        expect(trackedTotal.amount == 2 && trackedTotal.seriesCount == 2 && trackedTotal.apiKeyCount == 1,
               "tracked-key scope still aggregates only the configured tracking_id")
        let zeroTotal = try DeepSeekPlatformUsageClient.parseCost(costEnvelope(series: "[]"), scope: .accountWide)
        expect(zeroTotal.amount == 0 && !zeroTotal.hasMatchingSeries && zeroTotal.apiKeyCount == 0,
               "account-wide cost with no series is a real zero, not a missing reading")

        // Account-wide token scope (second page).
        let scoped = try DeepSeekPlatformUsageClient.parseAmount(amountScopeFixture(), scope: .accountWide)
        expect(scoped.usage.totalTokens == 370 && scoped.usage.inputTokens == 300 && scoped.usage.outputTokens == 70,
               "account-wide tokens sum every API key: key A 120 plus key B 250 = 370")
        expect(scoped.usage.totalTokens == scoped.usage.inputTokens + scoped.usage.outputTokens,
               "total tokens are input plus output with no component double count")
        expect(scoped.usage.cacheHitTokens == 180 && scoped.usage.cacheMissTokens == 120 && scoped.usage.requests == 5,
               "cache hit/miss/request counters aggregate once alongside the token totals")
        expect(scoped.apiKeyCount == 2 && scoped.seriesCount == 3,
               "account-wide amount reports both API keys and every returned series")
        expect(scoped.models.count == 2 && Set(scoped.models.map(\.model)) == ["model-a", "model-b"],
               "multiple models aggregate without model filtering")
        let trackedA = try DeepSeekPlatformUsageClient.parseAmount(amountScopeFixture(), scope: .trackedKey("key-a-fixture"))
        expect(trackedA.usage.totalTokens == 120 && trackedA.apiKeyCount == 1 && trackedA.seriesCount == 1,
               "tracked-key scope still returns key A's own 120 tokens")
        let trackedB = try DeepSeekPlatformUsageClient.parseAmount(amountScopeFixture(), scope: .trackedKey("key-b-fixture"))
        expect(trackedB.usage.totalTokens == 250 && trackedB.apiKeyCount == 1,
               "tracked key B returns its own 250 tokens, not the account total")
        let emptyScope = try DeepSeekPlatformUsageClient.parseAmount(envelope(series: "[]"), scope: .accountWide)
        expect(emptyScope.usage == DeepSeekWorkerUsage() && !emptyScope.hasMatchingSeries && emptyScope.apiKeyCount == 0,
               "account-wide amount with no series is a real zero with no API keys")
        do {
            _ = try DeepSeekPlatformUsageClient.parseAmount(
                envelope(series: #"[{"api_key":{"tracking_id":"key-a-fixture"},"model":"x","buckets":[{"usage":{"UNKNOWN_FIELD":"1"}}]}]"#),
                scope: .accountWide)
            expect(false, "malformed account-wide series rejected")
        } catch DeepSeekPlatformUsageError.invalidResponseSchema {
            expect(true, "malformed series fails safely in account-wide scope too")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = ISO8601DateFormatter().date(from: "2026-09-15T04:00:00Z")!
        let today = DeepSeekBillingRange.today(now: now, calendar: calendar)
        let month = DeepSeekBillingRange.month(now: now, calendar: calendar)
        expect(calendar.component(.hour, from: today.start) == 0
            && calendar.dateComponents([.day], from: today.start, to: today.end).day == 1,
               "Today uses local midnight boundaries")
        expect(calendar.component(.day, from: month.start) == 1 && calendar.component(.month, from: month.end) == 10,
               "This Month uses local calendar boundaries")
        expect(today.timezoneOffsetSeconds == 28800 && month.timezoneOffsetSeconds == 28800,
               "local timezone offset is sent in seconds")

        let last30 = DeepSeekBillingRange.last30Days(now: now, calendar: calendar)
        expect(calendar.component(.hour, from: last30.start) == 0
            && calendar.component(.hour, from: last30.end) == 0
            && calendar.dateComponents([.day], from: last30.start, to: last30.end).day == 30,
               "Last 30 days is exactly 30 local calendar days ending tomorrow midnight")
        expect(calendar.component(.day, from: last30.start) == 17
            && calendar.component(.month, from: last30.start) == 8
            && calendar.component(.day, from: last30.end) == 16,
               "Last 30 days starts 29 days ago and includes today")
        var westCalendar = Calendar(identifier: .gregorian)
        westCalendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
        let west = DeepSeekBillingRange.last30Days(now: now, calendar: westCalendar)
        expect(west.timezoneOffsetSeconds == -18000
            && west.start != last30.start
            && westCalendar.dateComponents([.day], from: west.start, to: west.end).day == 30,
               "the 30-day window follows the user's local calendar across the timezone boundary")

        let recorder = RequestRecorder()
        let send: DeepSeekPlatformUsageClient.Send = { request in
            recorder.append(request)
            let data = request.url?.path.hasSuffix("/cost") == true ? costFixture() : amountFixture()
            return (data, response(request.url!))
        }
        let snapshot = try await DeepSeekPlatformUsageClient.fetch(
            token: "  Bearer synthetic-platform-token  ", trackingID: "  \(workerID)  ",
            keyLabel: "Optional label", now: now, calendar: calendar, send: send)
        expect(snapshot.trackingID == workerID && snapshot.keyLabel == "Optional label",
               "tracking_id trims whitespace and label remains display-only")
        expect(snapshot.today.usage.totalTokens == 230 && snapshot.month.usage.totalTokens == 230,
               "Today and month retain independent official amount data")
        expect(snapshot.today.actualCostCNY == 2 && snapshot.month.actualCostCNY == 2,
               "Today and month display official Actual Cost")
        expect(snapshot.today.apiKeyCount == 1 && snapshot.month.apiKeyCount == 1,
               "the Worker view still reports a single tracked key")
        expect(recorder.requests.count == 4 && recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-platform-token"
        }, "plain or prefixed input produces exactly one Bearer prefix")
        expect(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie") == nil
                && $0.value(forHTTPHeaderField: "x-client-platform") == "web"
                && $0.url?.host == "platform.deepseek.com"
        }, "requests use Platform billing headers without browser cookies")
        let queries = recorder.requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false) }
        expect(queries.allSatisfy { Set($0.queryItems?.map(\.name) ?? []) == ["start", "end", "tz"] },
               "billing requests contain only local range parameters")

        let accountRecorder = RequestRecorder()
        let accountSnapshot = try await DeepSeekPlatformUsageClient.fetchAccountCost(
            token: "  Bearer synthetic-platform-token  ", now: now, calendar: calendar
        ) { request in
            accountRecorder.append(request)
            return (costFixture(), response(request.url!))
        }
        expect(accountSnapshot.range == last30 && accountSnapshot.total.amount == 101
            && accountSnapshot.total.apiKeyCount == 2,
               "account cost fetch uses the 30-day window and the account-wide total")
        expect(accountRecorder.requests.count == 1
            && accountRecorder.requests[0].url?.path == "/api/v0/usage/by_api_key/cost"
            && accountRecorder.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-platform-token",
               "account cost hits the Platform cost endpoint once with one Bearer prefix")
        let accountQuery = accountRecorder.requests.first
            .flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false) }
        expect(accountQuery?.queryItems?.count == 3
            && accountQuery?.queryItems?.first { $0.name == "start" }?.value
                == String(Int64(last30.start.timeIntervalSince1970))
            && accountQuery?.queryItems?.first { $0.name == "end" }?.value
                == String(Int64(last30.end.timeIntervalSince1970))
            && accountQuery?.queryItems?.first { $0.name == "tz" }?.value == "28800",
               "account cost sends the exact local 30-day window and timezone offset")

        do {
            _ = try await DeepSeekPlatformUsageClient.fetchAccountCost(token: "synthetic", now: now,
                                                                       calendar: calendar) { request in
                (Data(), response(request.url!, status: 404))
            }
            expect(false, "account cost 404 rejected")
        } catch DeepSeekPlatformUsageError.costUnavailable {
            expect(true, "account cost unavailability keeps its distinct error")
        }

        var missingTrackingRequests = 0
        do {
            _ = try await DeepSeekPlatformUsageClient.fetch(token: "synthetic", trackingID: "  ") { request in
                missingTrackingRequests += 1
                return (amountFixture(), response(request.url!))
            }
            expect(false, "missing tracking_id fails")
        } catch DeepSeekPlatformUsageError.trackingIDRequired {
            expect(missingTrackingRequests == 0, "missing tracking_id is rejected before billing requests")
        }
        do {
            _ = try await DeepSeekPlatformUsageClient.fetch(token: "synthetic", trackingID: workerID) { request in
                (Data(), response(request.url!, status: 401))
            }
            expect(false, "401 rejected")
        } catch DeepSeekPlatformUsageError.unauthorized {
            expect(true, "401 maps to invalid or expired Platform token")
        }
        do {
            _ = try await DeepSeekPlatformUsageClient.fetch(token: "  ", trackingID: workerID, send: send)
            expect(false, "missing token rejected")
        } catch DeepSeekPlatformUsageError.noPlatformToken {
            expect(true, "missing Platform token has a distinct error")
        }
        do {
            _ = try await DeepSeekPlatformUsageClient.fetch(token: "synthetic", trackingID: workerID) { _ in
                throw SyntheticNetworkError.offline
            }
            expect(false, "network failure rejected")
        } catch DeepSeekPlatformUsageError.networkFailure {
            expect(true, "network failure has a distinct error")
        }
        do {
            _ = try await DeepSeekPlatformUsageClient.fetch(token: "synthetic", trackingID: workerID) { request in
                (Data(), response(request.url!, status: 404))
            }
            expect(false, "amount unavailable rejected")
        } catch DeepSeekPlatformUsageError.amountUnavailable {
            expect(true, "amount endpoint unavailability has a distinct error")
        }

        let businessFailure = Data(#"{"code":0,"data":{"biz_code":710,"biz_msg":"billing unavailable","biz_data":{"series":[]}}}"#.utf8)
        do {
            _ = try DeepSeekPlatformUsageClient.parseAmount(businessFailure, trackingID: workerID)
            expect(false, "business error rejected")
        } catch DeepSeekPlatformUsageError.platformBusinessError(710, "billing unavailable") {
            expect(true, "nonzero biz_code remains a distinct Platform business error")
        }
        do {
            _ = try DeepSeekPlatformUsageClient.parseAmount(Data("{}".utf8), trackingID: workerID)
            expect(false, "malformed schema rejected")
        } catch DeepSeekPlatformUsageError.invalidResponseSchema {
            expect(true, "missing critical envelope fields maps to schema error")
        }

        let partial = try await DeepSeekPlatformUsageClient.fetch(
            token: "synthetic", trackingID: workerID, now: now, calendar: calendar
        ) { request in
            if request.url?.path.hasSuffix("/cost") == true { return (Data("{}".utf8), response(request.url!)) }
            return (amountFixture(), response(request.url!))
        }
        expect(partial.today.usage.totalTokens == 230 && partial.month.usage.totalTokens == 230
            && partial.today.actualCostCNY == nil && partial.month.actualCostCNY == nil
            && partial.today.costError == .invalidResponseSchema && partial.month.costError == .invalidResponseSchema,
               "amount success with cost failure preserves tokens and marks cost unavailable")

        let credential = MockPlatformTokenStore()
        try credential.saveToken("first-synthetic-secret")
        try credential.saveToken("second-synthetic-secret")
        let updatedToken = try credential.loadToken()
        expect(credential.saves == 2 && updatedToken == "second-synthetic-secret",
               "token storage abstraction supports update-or-add and load")
        try credential.removeToken()
        let removedToken = try credential.loadToken()
        expect(!credential.containsToken() && removedToken == nil,
               "token storage abstraction supports delete")

        let suiteName = "DeepSeekPlatformUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storeCredential = MockPlatformTokenStore()
        let store = DeepSeekWorkerBillingStore(defaults: defaults, tokenStore: storeCredential, send: send)
        store.configure(trackingID: "  \(workerID)  ", keyLabel: "  Display only  ")
        try store.saveToken("Bearer stored-synthetic-secret")
        await store.refresh()
        expect(store.snapshot?.trackingID == workerID
            && defaults.string(forKey: DeepSeekWorkerBillingStore.trackingIDKey) == workerID,
               "store persists directly configured canonical tracking_id")
        expect(defaults.string(forKey: DeepSeekWorkerBillingStore.keyLabelKey) == "Display only"
            && storeCredential.token == "stored-synthetic-secret",
               "optional label is non-secret while normalized token stays in token store")

        let zeroCredential = MockPlatformTokenStore()
        zeroCredential.token = "synthetic"
        let zeroStore = DeepSeekWorkerBillingStore(defaults: defaults, tokenStore: zeroCredential) { request in
            let data = request.url?.path.hasSuffix("/cost") == true
                ? costEnvelope(series: "[]") : envelope(series: "[]")
            return (data, response(request.url!))
        }
        await zeroStore.refresh()
        expect(zeroStore.snapshot?.today.usage.totalTokens == 0
            && zeroStore.snapshot?.today.actualCostCNY == 0
            && zeroStore.connectionMessage == "Connected · No usage in selected period",
               "empty official series is connected with zero usage and zero Actual Cost")

        let noTrackingDefaults = UserDefaults(suiteName: "DeepSeekPlatformUsageTests.missing.\(UUID().uuidString)")!
        let noTrackingCredential = MockPlatformTokenStore()
        noTrackingCredential.token = "synthetic"
        let noTrackingStore = DeepSeekWorkerBillingStore(defaults: noTrackingDefaults,
                                                          tokenStore: noTrackingCredential, send: send)
        await noTrackingStore.refresh()
        expect(noTrackingStore.status == .trackingIDRequired, "store reports Tracking ID required")

        let accountTokenStore = MockPlatformTokenStore()
        accountTokenStore.token = "synthetic"
        let accountStore = DeepSeekAccountCostStore(tokenStore: accountTokenStore, send: { request in
            (costFixture(), response(request.url!))
        }, calendar: calendar, now: { now })
        await accountStore.refresh()
        expect(accountStore.status == nil && accountStore.snapshot?.total.amount == 101
            && accountStore.hasPlatformToken,
               "account cost store publishes the account-wide 30-day total")
        let tokenlessCostStore = DeepSeekAccountCostStore(tokenStore: MockPlatformTokenStore(), send: { request in
            (costFixture(), response(request.url!))
        }, calendar: calendar, now: { now })
        await tokenlessCostStore.refresh()
        expect(tokenlessCostStore.status == .noPlatformToken && tokenlessCostStore.snapshot == nil,
               "account cost store reports a missing Platform token independently of the Worker store")

        let accountUsageTokenStore = MockPlatformTokenStore()
        accountUsageTokenStore.token = "synthetic"
        let accountUsageStore = DeepSeekAccountUsageStore(tokenStore: accountUsageTokenStore, send: { request in
            let data = request.url?.path.hasSuffix("/cost") == true ? costFixture() : amountScopeFixture()
            return (data, response(request.url!))
        }, calendar: calendar, now: { now })
        await accountUsageStore.refresh()
        expect(accountUsageStore.status == nil
            && accountUsageStore.snapshot?.today.usage.totalTokens == 370
            && accountUsageStore.snapshot?.month.usage.totalTokens == 370
            && accountUsageStore.snapshot?.today.apiKeyCount == 2,
               "account usage store publishes account-wide token totals for today and this month")
        expect(accountUsageStore.snapshot?.today.actualCostCNY == 101
            && accountUsageStore.snapshot?.month.actualCostCNY == 101,
               "account usage store keeps account-wide per-period cost beside the tokens")
        let tokenlessUsageStore = DeepSeekAccountUsageStore(tokenStore: MockPlatformTokenStore(), send: { request in
            (amountScopeFixture(), response(request.url!))
        }, calendar: calendar, now: { now })
        await tokenlessUsageStore.refresh()
        expect(tokenlessUsageStore.status == .noPlatformToken && tokenlessUsageStore.snapshot == nil,
               "account usage store reports a missing Platform token independently")

        let codexRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexRoot) }
        let codex = #"""
        {"type":"turn_context","payload":{"model":"gpt-5.4"}}
        {"type":"event_msg","timestamp":"2026-09-14T12:00:00.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":20}}}}
        """#
        try Data(codex.utf8).write(to: codexRoot.appendingPathComponent("rollout-regression.jsonl"))
        let codexEvents = CodexLogReader.scan(lookbackDays: nil, root: codexRoot)
        expect(codexEvents.count == 1 && codexEvents[0].provider == .codex && codexEvents[0].inputTokens == 40,
               "normal Codex local usage parsing remains unchanged")
    }
}
