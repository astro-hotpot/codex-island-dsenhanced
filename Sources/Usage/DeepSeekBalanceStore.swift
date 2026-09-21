import Combine
import Foundation
import Security

/// `GET https://api.deepseek.com/user/balance` payload.
///
/// `balance_infos` is an array, not a single value: an account can hold more
/// than one currency (e.g. granted CNY plus topped-up USD). Callers must
/// never sum across currencies — each entry keeps its own currency and the
/// joined headline keeps them side by side.
struct DeepSeekBalance: Decodable, Equatable {
    let is_available: Bool
    let balance_infos: [Entry]

    struct Entry: Decodable, Equatable {
        let currency: String
        let total_balance: String
        let granted_balance: String?
        let topped_up_balance: String?

        var symbol: String {
            switch currency.uppercased() {
            case "CNY", "RMB", "JPY": return "¥"
            case "USD": return "$"
            case "EUR": return "€"
            case "GBP": return "£"
            case "KRW": return "₩"
            default: return ""
            }
        }

        /// `¥123.45` for a known currency, `XYZ 123.45` otherwise.
        var formatted: String {
            symbol.isEmpty ? "\(currency) \(total_balance)" : symbol + total_balance
        }

        var isZero: Bool {
            guard let value = Decimal(string: total_balance, locale: Locale(identifier: "en_US_POSIX")) else {
                return false
            }
            return value == 0
        }
    }

    /// Non-zero entries first so a funded account doesn't lead with a 0.00
    /// currency row; falls back to every entry when all are zero.
    var displayEntries: [Entry] {
        let nonZero = balance_infos.filter { !$0.isZero }
        return nonZero.isEmpty ? balance_infos : nonZero
    }

    /// All currencies joined with " / " — never added together.
    var headline: String {
        let text = displayEntries.map(\.formatted).joined(separator: " / ")
        return text.isEmpty ? "—" : text
    }

    static func decode(_ data: Data) throws -> DeepSeekBalance {
        guard let value = try? JSONDecoder().decode(Self.self, from: data) else {
            throw DeepSeekBalanceError.invalidResponse
        }
        let posix = Locale(identifier: "en_US_POSIX")
        let wellFormed = !value.balance_infos.isEmpty && value.balance_infos.allSatisfy { entry in
            guard !entry.currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Decimal(string: entry.total_balance, locale: posix) != nil else { return false }
            return [entry.granted_balance, entry.topped_up_balance]
                .compactMap { $0 }
                .allSatisfy { Decimal(string: $0, locale: posix) != nil }
        }
        guard wellFormed else { throw DeepSeekBalanceError.invalidResponse }
        return value
    }
}

// MARK: - Error model

enum DeepSeekLegacyMigrationFailure: String, Equatable {
    case keyFileUnreadable
    case keyFileHasNoUniqueKey
    case keychainWriteFailed
}

/// Structured balance failures. Messages are user-facing only — no credential
/// ever reaches an error payload (the bearer token is never interpolated).
enum DeepSeekBalanceError: Error, Equatable, LocalizedError {
    case credentialNotFound
    case legacyMigrationFailed(DeepSeekLegacyMigrationFailure)
    case keychainFailure(Int, String)
    case unauthorized
    case networkFailure
    case serverError(Int)
    case unexpectedStatus(Int)
    case invalidResponse

    var httpStatus: Int? {
        switch self {
        case .serverError(let status), .unexpectedStatus(let status): return status
        default: return nil
        }
    }

    var message: String {
        switch self {
        case .credentialNotFound:
            return L10n.tr("DeepSeek API key not configured")
        case .legacyMigrationFailed(.keyFileUnreadable):
            return L10n.tr("Legacy DeepSeek key file could not be read")
        case .legacyMigrationFailed(.keyFileHasNoUniqueKey):
            return L10n.tr("Legacy DeepSeek key file does not contain exactly one API key")
        case .legacyMigrationFailed(.keychainWriteFailed):
            return L10n.tr("DeepSeek API key could not be saved to Keychain")
        case .keychainFailure(let status, let detail):
            return L10n.tr("DeepSeek Keychain error %d: %@", status, detail)
        case .unauthorized:
            return L10n.tr("DeepSeek API authentication failed")
        case .networkFailure:
            return L10n.tr("DeepSeek network connection failed")
        case .serverError:
            return L10n.tr("DeepSeek service is temporarily unavailable")
        case .unexpectedStatus(let status):
            return L10n.tr("DeepSeek returned an unexpected status (%d)", status)
        case .invalidResponse:
            return L10n.tr("DeepSeek returned an unexpected response format")
        }
    }

    var errorDescription: String? { message }
}

// MARK: - API key credential (distinct from the Platform token)

/// DeepSeek **API key** (`sk-…`), the bearer credential for
/// `api.deepseek.com`. This is a different secret from the DeepSeek
/// **Platform token** used by `platform.deepseek.com` usage endpoints, and it
/// lives in its own Keychain namespace.
protocol DeepSeekAPIKeyStoring {
    func containsAPIKey() -> Bool
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ value: String) throws
    func removeAPIKey() throws
}

struct DeepSeekAPIKeyStoreError: LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        "Keychain OSStatus \(status): \(detail)"
    }

    var detail: String {
        SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
    }
}

/// Mirrors `DeepSeekPlatformTokenKeychain`, but the service/account namespace
/// is deliberately different so an API key can never be mistaken for (or
/// overwrite) a Platform login token.
struct DeepSeekAPIKeyKeychain: DeepSeekAPIKeyStoring {
    static let service = "dev.codexisland.CodexIsland.deepseek-api-key"
    static let account = "deepseek-api-key"

    func containsAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func loadAPIKey() throws -> String? {
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
              let value = String(data: data, encoding: .utf8) else {
            throw DeepSeekAPIKeyStoreError(status: status)
        }
        let key = DeepSeekBalanceClient.normalizeAPIKey(value)
        return key.isEmpty ? nil : key
    }

    func saveAPIKey(_ value: String) throws {
        let key = DeepSeekBalanceClient.normalizeAPIKey(value)
        guard !key.isEmpty, let data = key.data(using: .utf8) else {
            throw DeepSeekAPIKeyStoreError(status: errSecParam)
        }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let update = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw DeepSeekAPIKeyStoreError(status: update) }
        var addition = identity
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addition as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeepSeekAPIKeyStoreError(status: status) }
    }

    func removeAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeepSeekAPIKeyStoreError(status: status)
        }
    }
}

// MARK: - Legacy key-file migration

/// The pre-Keychain configuration: `MacIsland.deepSeekKeyFile` in
/// UserDefaults points at a file holding an `sk-…` key. Read-only and used
/// once to seed the Keychain; the user's original file is never touched.
struct DeepSeekLegacyKeyFile {
    static let pathKey = "MacIsland.deepSeekKeyFile"

    let defaults: UserDefaults
    let fileManager: FileManager

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    var configuredPath: String? { defaults.string(forKey: Self.pathKey) }

    var resolvedPath: String {
        configuredPath
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/key/key").path
    }

    func exists() -> Bool { fileManager.fileExists(atPath: resolvedPath) }

    func readAPIKey() throws -> String {
        let raw: String
        do {
            raw = try String(contentsOfFile: resolvedPath, encoding: .utf8)
        } catch {
            throw DeepSeekBalanceError.legacyMigrationFailed(.keyFileUnreadable)
        }
        guard let regex = try? NSRegularExpression(pattern: "sk-[A-Za-z0-9_-]+") else {
            throw DeepSeekBalanceError.legacyMigrationFailed(.keyFileUnreadable)
        }
        let keys = Set(regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).compactMap {
            Range($0.range, in: raw).map { String(raw[$0]) }
        })
        guard keys.count == 1, let key = keys.first else {
            throw DeepSeekBalanceError.legacyMigrationFailed(.keyFileHasNoUniqueKey)
        }
        return DeepSeekBalanceClient.normalizeAPIKey(key)
    }
}

// MARK: - DSH / DeepSeek worker credential source

/// Read-only view of the DSH / DeepSeek worker credential store
/// (`~/.dsh/.credentials.yaml`, mode 0600).
///
/// The worker credential already exists on this machine, and the balance
/// endpoint authenticates with any API key of the account, so the balance
/// query reuses that key instead of asking the user to copy the same secret
/// into a second store. The file is never written, never logged, and only
/// `sk-…` scalars are returned — other secrets in the same file (e.g. the
/// encoded `records.*.payload.secret`) are ignored.
struct DeepSeekWorkerCredentialSource {
    static let relativePath = ".dsh/.credentials.yaml"

    let fileURL: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fileURL = home.appendingPathComponent(Self.relativePath)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var path: String { fileURL.path }

    /// `DEEPSEEK_API_KEY` first, then any other `sk-…` scalar in file order.
    func apiKeys() -> [String] {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        var preferred: [String] = []
        var others: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            guard let colon = text.firstIndex(of: ":") else { continue }
            let name = text[..<colon].trimmingCharacters(in: .whitespaces)
            let value = text[text.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            guard let key = Self.extractAPIKey(value) else { continue }
            if name.uppercased().contains("DEEPSEEK_API_KEY") { preferred.append(key) } else { others.append(key) }
        }
        var seen = Set<String>()
        return (preferred + others).filter { seen.insert($0).inserted }
    }

    private static func extractAPIKey(_ raw: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "sk-[A-Za-z0-9_-]{8,}") else { return nil }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              let keyRange = Range(match.range, in: raw) else { return nil }
        return String(raw[keyRange])
    }
}

/// Where a balance API key came from. Used only for a user-facing label —
/// never for choosing which account's numbers to add together (there is no
/// such addition; the first usable key answers the account balance).
enum DeepSeekAPIKeySource: String, Equatable {
    case workerCredentialStore
    case keychain
    case legacyKeyFile
}

struct DeepSeekAPIKeyCandidate: Equatable {
    let apiKey: String
    let source: DeepSeekAPIKeySource
}

/// Resolves the DeepSeek API key for the balance client, in priority order:
///
/// 1. the DeepSeek worker / DSH credential store (already on the machine)
/// 2. the CodexIsland Keychain item the user saved
/// 3. the legacy key file, migrated once into the Keychain
///
/// Migration runs at most once per store session, and its failure is cached so
/// a refresh loop can't re-read (and re-fail on) the same file.
final class DeepSeekAPIKeyResolver {
    private let keychain: DeepSeekAPIKeyStoring
    private let legacy: DeepSeekLegacyKeyFile
    private let worker: DeepSeekWorkerCredentialSource
    private var migrationAttempted = false
    private var migrationFailure: DeepSeekBalanceError?

    init(keychain: DeepSeekAPIKeyStoring = DeepSeekAPIKeyKeychain(),
         legacy: DeepSeekLegacyKeyFile = DeepSeekLegacyKeyFile(),
         worker: DeepSeekWorkerCredentialSource = DeepSeekWorkerCredentialSource()) {
        self.keychain = keychain
        self.legacy = legacy
        self.worker = worker
    }

    /// Cheap credential-presence probe with no side effects (no migration).
    func containsAPIKey() -> Bool {
        !worker.apiKeys().isEmpty || keychain.containsAPIKey() || legacy.exists()
    }

    /// Only the CodexIsland-owned Keychain item (what Settings can remove).
    func containsStoredAPIKey() -> Bool { keychain.containsAPIKey() }

    /// Ordered, de-duplicated candidates. Balance queries try them one at a
    /// time and stop at the first success — never adding responses together.
    func candidates() throws -> [DeepSeekAPIKeyCandidate] {
        var candidates: [DeepSeekAPIKeyCandidate] = []
        var seen = Set<String>()
        func append(_ raw: String, _ source: DeepSeekAPIKeySource) {
            let key = DeepSeekBalanceClient.normalizeAPIKey(raw)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            candidates.append(DeepSeekAPIKeyCandidate(apiKey: key, source: source))
        }

        worker.apiKeys().forEach { append($0, .workerCredentialStore) }

        var pendingFailure: DeepSeekBalanceError?
        do {
            if let stored = try loadStoredAPIKey() { append(stored, .keychain) }
        } catch let failure as DeepSeekBalanceError {
            pendingFailure = failure
        }

        if candidates.isEmpty {
            do {
                if let migrated = try migrateLegacyKeyIfAvailable() { append(migrated, .legacyKeyFile) }
            } catch let failure as DeepSeekBalanceError {
                if pendingFailure == nil { pendingFailure = failure }
            }
        }
        if candidates.isEmpty, let pendingFailure { throw pendingFailure }
        return candidates
    }

    /// First configured candidate, or `credentialNotFound`.
    func resolveAPIKey() throws -> String {
        guard let first = try candidates().first else { throw DeepSeekBalanceError.credentialNotFound }
        return first.apiKey
    }

    /// Keychain-only read; never consults the other sources.
    func loadStoredAPIKey() throws -> String? {
        do {
            guard let stored = try keychain.loadAPIKey() else { return nil }
            let key = DeepSeekBalanceClient.normalizeAPIKey(stored)
            return key.isEmpty ? nil : key
        } catch let error as DeepSeekAPIKeyStoreError {
            throw DeepSeekBalanceError.keychainFailure(Int(error.status), error.detail)
        }
    }

    private func migrateLegacyKeyIfAvailable() throws -> String? {
        if let failure = migrationFailure { throw failure }
        guard !migrationAttempted else { return nil }
        migrationAttempted = true

        guard legacy.exists() else { return nil }
        let key: String
        do {
            key = try legacy.readAPIKey()
        } catch let failure as DeepSeekBalanceError {
            migrationFailure = failure
            throw failure
        } catch {
            let failure = DeepSeekBalanceError.legacyMigrationFailed(.keyFileUnreadable)
            migrationFailure = failure
            throw failure
        }

        do {
            try keychain.saveAPIKey(key)
            guard let verified = try keychain.loadAPIKey(),
                  DeepSeekBalanceClient.normalizeAPIKey(verified) == key else {
                throw DeepSeekAPIKeyStoreError(status: errSecInternalError)
            }
        } catch {
            let failure = DeepSeekBalanceError.legacyMigrationFailed(.keychainWriteFailed)
            migrationFailure = failure
            throw failure
        }
        return key
    }

    func saveAPIKey(_ value: String) throws {
        let key = DeepSeekBalanceClient.normalizeAPIKey(value)
        guard !key.isEmpty else { throw DeepSeekBalanceError.credentialNotFound }
        do {
            try keychain.saveAPIKey(key)
        } catch let error as DeepSeekAPIKeyStoreError {
            throw DeepSeekBalanceError.keychainFailure(Int(error.status), error.detail)
        }
        migrationFailure = nil
        migrationAttempted = true
    }

    func removeAPIKey() throws {
        do {
            try keychain.removeAPIKey()
        } catch let error as DeepSeekAPIKeyStoreError {
            throw DeepSeekBalanceError.keychainFailure(Int(error.status), error.detail)
        }
    }
}

// MARK: - Client

enum DeepSeekBalanceClient {
    typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    static let balanceEndpoint = URL(string: "https://api.deepseek.com/user/balance")!

    /// Trims surrounding whitespace/newlines and tolerates a pasted
    /// `Bearer sk-…` prefix. Empty input stays empty so callers can reject it.
    static func normalizeAPIKey(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("bearer ") {
            value = String(value.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    static func fetch(
        apiKey: String,
        send: @escaping Send = { try await URLSession.shared.data(for: $0) }
    ) async throws -> DeepSeekBalance {
        let key = normalizeAPIKey(apiKey)
        guard !key.isEmpty else { throw DeepSeekBalanceError.credentialNotFound }

        var request = URLRequest(url: balanceEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            throw DeepSeekBalanceError.networkFailure
        }
        guard let http = response as? HTTPURLResponse else { throw DeepSeekBalanceError.networkFailure }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw DeepSeekBalanceError.unauthorized
        case 500...599: throw DeepSeekBalanceError.serverError(http.statusCode)
        default: throw DeepSeekBalanceError.unexpectedStatus(http.statusCode)
        }
        return try DeepSeekBalance.decode(data)
    }
}

// MARK: - Store

@MainActor
final class DeepSeekBalanceStore: ObservableObject {
    static let shared = DeepSeekBalanceStore()

    /// A failed fetch keeps re-firing on every panel expand; one attempt per
    /// minute is enough for a balance the Platform itself updates lazily.
    static let minimumRefreshInterval: TimeInterval = 60

    @Published private(set) var balance: DeepSeekBalance?
    @Published private(set) var error: DeepSeekBalanceError?
    @Published private(set) var loading = false
    @Published private(set) var updatedAt: Date?
    /// Cached so Settings doesn't hit the Keychain on every render.
    @Published private(set) var hasAPIKey: Bool
    /// CodexIsland-owned Keychain item only (drives the Settings buttons).
    @Published private(set) var hasStoredAPIKey: Bool
    /// Which configured credential answered the last successful query.
    @Published private(set) var activeSource: DeepSeekAPIKeySource?

    private let resolver: DeepSeekAPIKeyResolver
    private let send: DeepSeekBalanceClient.Send
    private let now: () -> Date
    private var cooldown: Date?
    private var lastAttempt: Date?

    init(resolver: DeepSeekAPIKeyResolver = DeepSeekAPIKeyResolver(),
         send: @escaping DeepSeekBalanceClient.Send = { try await URLSession.shared.data(for: $0) },
         now: @escaping () -> Date = Date.init) {
        self.resolver = resolver
        self.send = send
        self.now = now
        self.hasAPIKey = resolver.containsAPIKey()
        self.hasStoredAPIKey = resolver.containsStoredAPIKey()
    }

    /// The account balance — one account, authenticated by any API key of that
    /// account. Never a per-key or per-worker balance.
    var headline: String { balance?.headline ?? "—" }

    var credentialSourceLabel: String {
        switch activeSource {
        case .workerCredentialStore: return L10n.tr("Using the DSH / DeepSeek worker key")
        case .keychain: return L10n.tr("Using the saved CodexIsland API key")
        case .legacyKeyFile: return L10n.tr("Using the migrated legacy key file")
        case nil:
            return hasAPIKey
                ? L10n.tr("DeepSeek API key configured")
                : L10n.tr("DeepSeek API key not configured")
        }
    }

    func saveAPIKey(_ value: String) throws {
        try resolver.saveAPIKey(value)
        hasAPIKey = true
        hasStoredAPIKey = true
        error = nil
    }

    func removeAPIKey() throws {
        try resolver.removeAPIKey()
        hasAPIKey = resolver.containsAPIKey()
        hasStoredAPIKey = resolver.containsStoredAPIKey()
        balance = nil
        updatedAt = nil
    }

    func refresh(force: Bool = false) async {
        guard !loading else { return }
        let moment = now()
        if let cooldown, cooldown > moment { return }
        if !force, let lastAttempt, moment.timeIntervalSince(lastAttempt) < Self.minimumRefreshInterval {
            return
        }
        lastAttempt = moment
        loading = true
        defer { loading = false }

        if AppEnvironment.isDemo {
            balance = DeepSeekBalance(is_available: true, balance_infos: [
                .init(currency: "CNY", total_balance: "100.00",
                      granted_balance: "0.00", topped_up_balance: "100.00")
            ])
            updatedAt = now()
            error = nil
            return
        }

        do {
            let candidates = try resolver.candidates()
            guard !candidates.isEmpty else { throw DeepSeekBalanceError.credentialNotFound }

            // One balance query per candidate, first success wins. Keys are
            // alternative authentications for the same account — balances are
            // never added together.
            var unauthorized = false
            for candidate in candidates {
                do {
                    let fetched = try await DeepSeekBalanceClient.fetch(apiKey: candidate.apiKey, send: send)
                    balance = fetched
                    activeSource = candidate.source
                    updatedAt = now()
                    error = nil
                    hasAPIKey = true
                    return
                } catch DeepSeekBalanceError.unauthorized {
                    unauthorized = true
                }
            }
            throw unauthorized ? DeepSeekBalanceError.unauthorized : .credentialNotFound
        } catch let failure as DeepSeekBalanceError {
            balance = nil
            updatedAt = nil
            if failure.httpStatus == 429 { cooldown = now().addingTimeInterval(900) }
            error = failure
        } catch {
            balance = nil
            updatedAt = nil
            self.error = .networkFailure
        }
    }
}
