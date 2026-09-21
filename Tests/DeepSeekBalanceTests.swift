import Foundation
import Security

enum SyntheticBalanceNetworkError: Error { case offline }

final class MockAPIKeyStore: DeepSeekAPIKeyStoring {
    var key: String?
    var saves = 0
    var loads = 0
    var failure: OSStatus?

    func containsAPIKey() -> Bool { key != nil }

    func loadAPIKey() throws -> String? {
        loads += 1
        if let failure { throw DeepSeekAPIKeyStoreError(status: failure) }
        return key
    }

    func saveAPIKey(_ value: String) throws {
        if let failure { throw DeepSeekAPIKeyStoreError(status: failure) }
        saves += 1
        key = DeepSeekBalanceClient.normalizeAPIKey(value)
    }

    func removeAPIKey() throws {
        if let failure { throw DeepSeekAPIKeyStoreError(status: failure) }
        key = nil
    }
}

final class MockPlatformTokenStore: DeepSeekPlatformTokenStoring {
    var token: String?
    var failure: OSStatus?
    func containsToken() -> Bool { token != nil }
    func loadToken() throws -> String? {
        if let failure { throw DeepSeekPlatformTokenStoreError(status: failure) }
        return token
    }
    func saveToken(_ token: String) throws {
        if let failure { throw DeepSeekPlatformTokenStoreError(status: failure) }
        self.token = token
    }
    func removeToken() throws { token = nil }
}

final class BalanceRequestRecorder {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); storage.append(request); lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return storage }
}

@main
struct DeepSeekBalanceTests {
    static let apiKeyFixture = "sk-balance-fixture-1234567890"
    static let platformTokenFixture = "platform-token-fixture-abcdef"
    static let legacyKeyFixture = "sk-legacy-fixture-0987654321"

    static func expect(_ result: Bool, _ label: String) {
        guard result else { print("FAIL \(label)"); exit(1) }
        print("PASS \(label)")
    }

    static func response(_ url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    static func balanceJSON(_ entries: String, available: Bool = true) -> Data {
        Data(#"{"is_available":\#(available),"balance_infos":[\#(entries)]}"#.utf8)
    }

    static let cnyEntry = #"{"currency":"CNY","total_balance":"12.34","granted_balance":"2.34","topped_up_balance":"10.00"}"#
    static let usdEntry = #"{"currency":"USD","total_balance":"5.60","granted_balance":"0.00","topped_up_balance":"5.60"}"#
    static let zeroEntry = #"{"currency":"EUR","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}"#

    static let emptyCostEnvelope = Data(#"{"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":{"data":[{"currency":"CNY","series":[]}]}}}"#.utf8)

    /// Tests must never read the machine's real DSH credential store.
    static let emptyWorkerSource = DeepSeekWorkerCredentialSource(
        fileURL: URL(fileURLWithPath: "/nonexistent/DeepSeekBalanceTests/.credentials.yaml"))

    static func workerCredentialFixture(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(".credentials.yaml")
        try Data(contents.utf8).write(to: file)
        registeredDirectories.append(directory)
        return file
    }

    /// Sandboxed legacy path + UserDefaults suite per case.
    static var registeredSuites: [String] = []
    static var registeredDirectories: [URL] = []

    static func legacyFixture(contents: String?) throws -> (file: URL, defaults: UserDefaults, suite: String) {
        let suite = "DeepSeekBalanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("key")
        if let contents {
            try Data(contents.utf8).write(to: file)
        }
        defaults.set(file.path, forKey: DeepSeekLegacyKeyFile.pathKey)
        registeredSuites.append(suite)
        registeredDirectories.append(directory)
        return (file, defaults, suite)
    }

    static func makeLegacy(contents: String?) throws -> (legacy: DeepSeekLegacyKeyFile, file: URL, defaults: UserDefaults) {
        let fixture = try legacyFixture(contents: contents)
        return (DeepSeekLegacyKeyFile(defaults: fixture.defaults), fixture.file, fixture.defaults)
    }

    static func fetchFailure(apiKey: String, status: Int) async -> DeepSeekBalanceError? {
        do {
            _ = try await DeepSeekBalanceClient.fetch(apiKey: apiKey) { request in
                (Data("{}".utf8), response(request.url!, status: status))
            }
            return nil
        } catch let error as DeepSeekBalanceError {
            return error
        } catch {
            return nil
        }
    }

    @MainActor
    static func main() async throws {
        // 1. Keychain API key load.
        let storedKeys = MockAPIKeyStore()
        storedKeys.key = apiKeyFixture
        let missingLegacy = try makeLegacy(contents: nil).legacy
        let storedResolver = DeepSeekAPIKeyResolver(keychain: storedKeys, legacy: missingLegacy, worker: Self.emptyWorkerSource)
        expect(try storedResolver.resolveAPIKey() == apiKeyFixture && storedResolver.containsAPIKey(),
               "API key loads from the Keychain source")

        // 2. Whitespace/prefix normalization.
        expect(DeepSeekBalanceClient.normalizeAPIKey("  \(apiKeyFixture)\n ") == apiKeyFixture,
               "API key trims surrounding whitespace and newlines")
        expect(DeepSeekBalanceClient.normalizeAPIKey("Bearer \(apiKeyFixture)") == apiKeyFixture,
               "pasted bearer prefix is not duplicated")
        let trimmingKeys = MockAPIKeyStore()
        let trimmingResolver = DeepSeekAPIKeyResolver(keychain: trimmingKeys, legacy: missingLegacy, worker: Self.emptyWorkerSource)
        try trimmingResolver.saveAPIKey("  \(apiKeyFixture)\n")
        expect(try trimmingKeys.loadAPIKey() == apiKeyFixture && trimmingKeys.saves == 1,
               "saved API key is normalized before it reaches the Keychain")

        // 3. Missing credential.
        let emptyKeys = MockAPIKeyStore()
        let emptyResolver = DeepSeekAPIKeyResolver(keychain: emptyKeys, legacy: missingLegacy, worker: Self.emptyWorkerSource)
        do {
            _ = try emptyResolver.resolveAPIKey()
            expect(false, "missing credential rejected")
        } catch DeepSeekBalanceError.credentialNotFound {
            expect(true, "missing API key maps to credentialNotFound")
        }
        let blankRecorder = BalanceRequestRecorder()
        do {
            _ = try await DeepSeekBalanceClient.fetch(apiKey: "   \n") { request in
                blankRecorder.append(request)
                return (balanceJSON(cnyEntry), response(request.url!))
            }
            expect(false, "blank key rejected before networking")
        } catch DeepSeekBalanceError.credentialNotFound {
            expect(blankRecorder.requests.isEmpty, "blank key never reaches the network")
        }

        // 4. 200 with a valid response, plus request shape.
        let recorder = BalanceRequestRecorder()
        let send: DeepSeekBalanceClient.Send = { request in
            recorder.append(request)
            return (balanceJSON(cnyEntry), response(request.url!))
        }
        let balance = try await DeepSeekBalanceClient.fetch(apiKey: apiKeyFixture, send: send)
        expect(balance.is_available && balance.balance_infos.count == 1,
               "valid 200 response decodes into balance entries")
        expect(recorder.requests.count == 1
            && recorder.requests[0].url?.absoluteString == "https://api.deepseek.com/user/balance"
            && recorder.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKeyFixture)",
               "balance request targets api.deepseek.com with the API key as bearer")

        // 5/6/7. Currency formatting: never summed across currencies.
        let cny = try DeepSeekBalance.decode(balanceJSON(cnyEntry))
        expect(cny.headline == "¥12.34", "CNY balance formats with the ¥ symbol")
        let usd = try DeepSeekBalance.decode(balanceJSON(usdEntry))
        expect(usd.headline == "$5.60", "USD balance formats with the $ symbol")
        let mixed = try DeepSeekBalance.decode(balanceJSON("\(cnyEntry),\(usdEntry),\(zeroEntry)"))
        expect(mixed.headline == "¥12.34 / $5.60",
               "multiple currencies are shown side by side and zero entries are hidden")
        expect(!mixed.headline.contains("17.94"),
               "different currencies are never added together")

        // 8. Malformed JSON.
        do {
            _ = try DeepSeekBalance.decode(Data("{}".utf8))
            expect(false, "malformed response rejected")
        } catch DeepSeekBalanceError.invalidResponse {
            expect(true, "malformed JSON maps to invalidResponse")
        }
        let malformed = await fetchFailure(apiKey: apiKeyFixture, status: 200)
        expect(malformed == .invalidResponse, "200 with an unexpected body maps to invalidResponse")

        // 9/10/11/12. HTTP and transport classification.
        expect(await fetchFailure(apiKey: apiKeyFixture, status: 401) == .unauthorized,
               "401 maps to unauthorized")
        expect(await fetchFailure(apiKey: apiKeyFixture, status: 403) == .unauthorized,
               "403 maps to unauthorized")
        expect(await fetchFailure(apiKey: apiKeyFixture, status: 503) == .serverError(503),
               "5xx maps to serverError with its status")
        do {
            _ = try await DeepSeekBalanceClient.fetch(apiKey: apiKeyFixture) { _ in
                throw SyntheticBalanceNetworkError.offline
            }
            expect(false, "URLSession failure rejected")
        } catch DeepSeekBalanceError.networkFailure {
            expect(true, "URLSession failure maps to networkFailure")
        }

        // 13. Legacy key-file migration.
        let migrationFixture = try makeLegacy(contents: """
        # CodexIsland legacy key file
        OPENAI_API_KEY=not-a-deepseek-key
        DEEPSEEK_API_KEY=  \(legacyKeyFixture)
        """)
        let migrationKeys = MockAPIKeyStore()
        let migrationResolver = DeepSeekAPIKeyResolver(keychain: migrationKeys, legacy: migrationFixture.legacy, worker: Self.emptyWorkerSource)
        expect(try migrationResolver.resolveAPIKey() == legacyKeyFixture,
               "legacy key file seeds the API key after trimming")
        expect(try migrationKeys.loadAPIKey() == legacyKeyFixture && migrationKeys.saves == 1,
               "migrated key is written to the Keychain exactly once")
        expect(FileManager.default.fileExists(atPath: migrationFixture.file.path),
               "migration never deletes the user's original key file")
        try Data("sk-first-0000\nsk-second-0000\n".utf8).write(to: migrationFixture.file)
        expect(try migrationResolver.resolveAPIKey() == legacyKeyFixture,
               "once the Keychain holds a key the legacy file is never consulted again")

        // 14. Keychain wins over the legacy file.
        let winnerKeys = MockAPIKeyStore()
        winnerKeys.key = apiKeyFixture
        let winnerFixture = try makeLegacy(contents: "sk-legacy-0000\nsk-legacy-1111\n")
        let winnerResolver = DeepSeekAPIKeyResolver(keychain: winnerKeys, legacy: winnerFixture.legacy, worker: Self.emptyWorkerSource)
        expect(try winnerResolver.resolveAPIKey() == apiKeyFixture,
               "Keychain value wins even when the legacy file would fail migration")

        // Migration failure is a clear, one-shot error.
        let brokenFixture = try makeLegacy(contents: "no key material here\n")
        let brokenResolver = DeepSeekAPIKeyResolver(keychain: MockAPIKeyStore(), legacy: brokenFixture.legacy, worker: Self.emptyWorkerSource)
        do {
            _ = try brokenResolver.resolveAPIKey()
            expect(false, "legacy file without a unique key rejected")
        } catch DeepSeekBalanceError.legacyMigrationFailed(.keyFileHasNoUniqueKey) {
            expect(true, "unusable legacy file maps to a distinct migration error")
        }
        try Data("sk-repaired-0000\n".utf8).write(to: brokenFixture.file)
        do {
            _ = try brokenResolver.resolveAPIKey()
            expect(false, "migration is not retried inside one store session")
        } catch DeepSeekBalanceError.legacyMigrationFailed(.keyFileHasNoUniqueKey) {
            expect(true, "the cached migration failure is re-reported instead of re-reading the file")
        }
        let unreadableFixture = try makeLegacy(contents: "")
        try FileManager.default.removeItem(at: unreadableFixture.file)
        try FileManager.default.createDirectory(at: unreadableFixture.file, withIntermediateDirectories: true)
        let unreadableResolver = DeepSeekAPIKeyResolver(keychain: MockAPIKeyStore(),
                                                        legacy: DeepSeekLegacyKeyFile(defaults: unreadableFixture.defaults),
                                                        worker: Self.emptyWorkerSource)
        do {
            _ = try unreadableResolver.resolveAPIKey()
            expect(false, "unreadable legacy target rejected")
        } catch DeepSeekBalanceError.legacyMigrationFailed(.keyFileUnreadable) {
            expect(true, "unreadable legacy target maps to keyFileUnreadable")
        }

        // 15. The Platform token is never used by the balance client.
        let platformOnly = MockPlatformTokenStore()
        platformOnly.token = platformTokenFixture
        let platformOnlyRecorder = BalanceRequestRecorder()
        let platformOnlyResolver = DeepSeekAPIKeyResolver(keychain: MockAPIKeyStore(), legacy: missingLegacy, worker: Self.emptyWorkerSource)
        let platformOnlyStore = DeepSeekBalanceStore(resolver: platformOnlyResolver) { request in
            platformOnlyRecorder.append(request)
            return (balanceJSON(cnyEntry), response(request.url!))
        }
        await platformOnlyStore.refresh()
        expect(platformOnly.token == platformTokenFixture
            && platformOnlyStore.error == .credentialNotFound
            && platformOnlyRecorder.requests.isEmpty,
               "a Platform token alone never produces a balance request")

        let bothRecorder = BalanceRequestRecorder()
        let bothStore = DeepSeekBalanceStore(resolver: storedResolver) { request in
            bothRecorder.append(request)
            return (balanceJSON(cnyEntry), response(request.url!))
        }
        await bothStore.refresh()
        expect(bothRecorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") != "Bearer \(platformTokenFixture)"
                && $0.url?.host == "api.deepseek.com"
        }, "the balance client only ever sends the API key, never the Platform token")
        expect(DeepSeekAPIKeyKeychain.service != DeepSeekPlatformTokenKeychain.service
            && DeepSeekAPIKeyKeychain.account != DeepSeekPlatformTokenKeychain.account,
               "API key and Platform token live in separate Keychain namespaces")

        // 16. No secret in any user-facing error text.
        let errors: [DeepSeekBalanceError] = [
            .credentialNotFound,
            .legacyMigrationFailed(.keyFileUnreadable),
            .legacyMigrationFailed(.keyFileHasNoUniqueKey),
            .legacyMigrationFailed(.keychainWriteFailed),
            .keychainFailure(Int(errSecAuthFailed), "User interaction is not allowed."),
            .unauthorized,
            .networkFailure,
            .serverError(503),
            .unexpectedStatus(429),
            .invalidResponse,
        ]
        expect(errors.allSatisfy {
            !$0.message.contains(apiKeyFixture) && !String(describing: $0).contains(apiKeyFixture)
        }, "no balance error description ever contains the API key")
        let thrown = [
            await fetchFailure(apiKey: apiKeyFixture, status: 401),
            await fetchFailure(apiKey: apiKeyFixture, status: 503),
            await fetchFailure(apiKey: apiKeyFixture, status: 200),
        ].compactMap { $0 }
        expect(thrown.count == 3 && thrown.allSatisfy {
            !$0.message.contains(apiKeyFixture) && !($0.errorDescription ?? "").contains(apiKeyFixture)
        }, "no thrown balance error leaks the API key")

        // 17. DSH / DeepSeek worker credential source (read-only reuse).
        let workerFixture = try workerCredentialFixture("""
        version: 1
        records:
          record-id-fixture:
            kind: token
            payload:
              version: 1
              secret: not-a-deepseek-key-fixture
        refs:
          DEEPSEEK_API_KEY: \(apiKeyFixture)
        """)
        let workerSource = DeepSeekWorkerCredentialSource(fileURL: workerFixture)
        expect(workerSource.apiKeys() == [apiKeyFixture],
               "DSH worker store yields only its sk-shaped DeepSeek key")
        let workerBefore = try String(contentsOf: workerFixture, encoding: .utf8)
        let workerKeys = MockAPIKeyStore()
        let workerLegacy = try makeLegacy(contents: nil).legacy
        let workerResolver = DeepSeekAPIKeyResolver(keychain: workerKeys, legacy: workerLegacy, worker: workerSource)
        let workerCandidates = try workerResolver.candidates()
        expect(workerCandidates.count == 1 && workerCandidates[0].source == .workerCredentialStore
            && workerCandidates[0].apiKey == apiKeyFixture,
               "the existing worker key is the first balance candidate")
        expect(try String(contentsOf: workerFixture, encoding: .utf8) == workerBefore && workerKeys.saves == 0,
               "reusing the worker key never rewrites it nor copies the secret into the Keychain")

        let workerOnlyStore = DeepSeekBalanceStore(resolver: workerResolver) { request in
            (balanceJSON(cnyEntry), response(request.url!))
        }
        await workerOnlyStore.refresh(force: true)
        expect(workerOnlyStore.hasAPIKey && !workerOnlyStore.hasStoredAPIKey
            && workerOnlyStore.activeSource == .workerCredentialStore
            && workerOnlyStore.balance?.headline == "¥12.34"
            && workerOnlyStore.error == nil,
               "the existing worker key answers the account balance with no CodexIsland Keychain item")
        expect(workerOnlyStore.credentialSourceLabel == L10n.tr("Using the DSH / DeepSeek worker key"),
               "Settings reports which credential source answered")

        let orderedKeys = MockAPIKeyStore()
        orderedKeys.key = "sk-codexisland-fixture-2222"
        let orderedResolver = DeepSeekAPIKeyResolver(keychain: orderedKeys, legacy: workerLegacy,
                                                     worker: workerSource)
        expect(try orderedResolver.candidates().map(\.source) == [.workerCredentialStore, .keychain],
               "candidate order is worker store, then the CodexIsland Keychain")

        // 18. Multiple candidates: try in order, stop at the first success,
        // and never add balances from different responses.
        let fallbackRecorder = BalanceRequestRecorder()
        let fallbackStore = DeepSeekBalanceStore(resolver: orderedResolver) { request in
            fallbackRecorder.append(request)
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            if authorization == "Bearer \(apiKeyFixture)" {
                return (Data(), response(request.url!, status: 401))
            }
            return (balanceJSON(#"{"currency":"CNY","total_balance":"77.70","granted_balance":"0.00","topped_up_balance":"77.70"}"#),
                    response(request.url!))
        }
        await fallbackStore.refresh(force: true)
        expect(fallbackRecorder.requests.count == 2
            && fallbackStore.balance?.headline == "¥77.70"
            && fallbackStore.activeSource == .keychain
            && fallbackStore.error == nil,
               "a 401 on the first candidate falls through to the next and stops at the first success")

        let firstWinsRecorder = BalanceRequestRecorder()
        let firstWinsStore = DeepSeekBalanceStore(resolver: orderedResolver) { request in
            firstWinsRecorder.append(request)
            return (balanceJSON(#"{"currency":"CNY","total_balance":"55.50","granted_balance":"0.00","topped_up_balance":"55.50"}"#),
                    response(request.url!))
        }
        await firstWinsStore.refresh(force: true)
        expect(firstWinsRecorder.requests.count == 1
            && firstWinsStore.balance?.headline == "¥55.50"
            && firstWinsStore.activeSource == .workerCredentialStore,
               "the first usable key answers the account balance; responses are never added together")

        let rejectedRecorder = BalanceRequestRecorder()
        let rejectedStore = DeepSeekBalanceStore(resolver: orderedResolver) { request in
            rejectedRecorder.append(request)
            return (Data(), response(request.url!, status: 403))
        }
        await rejectedStore.refresh(force: true)
        expect(rejectedStore.error == .unauthorized && rejectedStore.balance == nil
            && rejectedStore.updatedAt == nil && rejectedRecorder.requests.count == 2,
               "when every candidate is rejected the result is unauthorized, not an invented balance")

        // Store-level behavior + failure isolation from the Platform cost source.
        let fixedNow = ISO8601DateFormatter().date(from: "2026-09-15T04:00:00Z")!
        let failingKeys = MockAPIKeyStore()
        failingKeys.key = apiKeyFixture
        let failingSendCount = Counter()
        let failingBalance = DeepSeekBalanceStore(
            resolver: DeepSeekAPIKeyResolver(keychain: failingKeys, legacy: missingLegacy, worker: Self.emptyWorkerSource),
            send: { request in
                failingSendCount.increment()
                return (Data("{}".utf8), response(request.url!, status: 401))
            },
            now: { fixedNow })
        await failingBalance.refresh()
        expect(failingBalance.error == .unauthorized && failingBalance.balance == nil && failingBalance.updatedAt == nil,
               "balance store surfaces the structured failure and drops the stale value")
        await failingBalance.refresh()
        expect(failingSendCount.value == 1,
               "a failed balance fetch is throttled instead of re-firing on every refresh")
        await failingBalance.refresh(force: true)
        expect(failingSendCount.value == 2, "a forced refresh still retries")

        var costCalendar = Calendar(identifier: .gregorian)
        costCalendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let accountToken = MockPlatformTokenStore()
        accountToken.token = platformTokenFixture
        let accountCost = DeepSeekAccountCostStore(tokenStore: accountToken, send: { request in
            (emptyCostEnvelope, response(request.url!))
        }, calendar: costCalendar, now: { fixedNow })
        await accountCost.refresh()
        expect(accountCost.status == nil && accountCost.snapshot?.total.amount == 0
            && accountCost.snapshot?.total.hasMatchingSeries == false,
               "account cost store publishes a zero-usage 30-day window")
        expect(failingBalance.error == .unauthorized && failingBalance.balance == nil,
               "a Platform cost success never touches the failing balance state")

        let missingTokenCost = DeepSeekAccountCostStore(tokenStore: MockPlatformTokenStore(), send: { request in
            (emptyCostEnvelope, response(request.url!))
        }, calendar: costCalendar, now: { fixedNow })
        await missingTokenCost.refresh()
        expect(missingTokenCost.status == .noPlatformToken && missingTokenCost.snapshot == nil,
               "account cost is unavailable without a Platform token, independently of the balance")

        for suite in registeredSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        for directory in registeredDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

final class Counter {
    private let lock = NSLock()
    private var storage = 0
    func increment() { lock.lock(); storage += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
}
