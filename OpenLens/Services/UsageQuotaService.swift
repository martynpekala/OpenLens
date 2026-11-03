import Foundation
import Observation
import os

/// Checks provider coding-plan usage limits against the z.ai / GLM quota
/// endpoint (`GET /api/monitor/usage/quota/limit`), which reports per-window
/// usage percentages and reset times for the plan bound to the API key.
///
/// The endpoint is provider-specific and unofficial; decoding is defensive and
/// every failure mode is surfaced as a distinct state so the UI can explain
/// *why* usage limits cannot be shown (including a token without the grants
/// to read them).
@MainActor @Observable
final class UsageQuotaService {

    // MARK: - Types

    enum Region: String, CaseIterable, Identifiable {
        case zaiGlobal
        case zaiChina

        var id: String { rawValue }

        var host: String {
            switch self {
            case .zaiGlobal: "https://api.z.ai"
            case .zaiChina: "https://open.bigmodel.cn"
            }
        }

        var displayName: String {
            switch self {
            case .zaiGlobal: "Z.ai (Global)"
            case .zaiChina: "BigModel (China)"
            }
        }
    }

    enum State: Equatable {
        /// No API key configured.
        case idle
        case loading
        case loaded(QuotaSnapshot)
        /// The key was rejected (401/403): it is invalid or lacks the grants
        /// required to read usage limits.
        case keyRejected(String?)
        /// The key is valid but the response reported no usable usage-limit
        /// windows (for example no coding plan, or missing team selectors).
        case noLimitsReported
        case failed(String)
    }

    enum UsageQuotaError: Error, Equatable {
        /// HTTP 401/403 — the token cannot read usage limits.
        case keyRejected(String?)
        /// 200 with no recognizable limit windows.
        case noLimitsReported
        case invalidResponse
    }

    struct QuotaWindow: Equatable, Identifiable {
        let id: String
        let title: String
        /// Whole-percent usage within the window (0–100).
        let percentage: Int
        let resetAt: Date?
    }

    struct QuotaSnapshot: Equatable {
        let planName: String?
        let windows: [QuotaWindow]
        let fetchedAt: Date
    }

    // MARK: - Storage

    nonisolated static let apiKeyKeychainKey = "usageQuotaProviderAPIKey"

    nonisolated static func storedAPIKey() -> String? {
        KeychainService.load(key: apiKeyKeychainKey)
    }

    nonisolated static func storeAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainService.delete(key: apiKeyKeychainKey)
        } else {
            _ = KeychainService.save(key: apiKeyKeychainKey, value: trimmed)
        }
    }

    nonisolated static func storedRegion() -> Region {
        guard let raw = UserDefaults.standard.string(forKey: AppPreferenceKeys.usageQuotaRegion),
              let region = Region(rawValue: raw) else {
            return .zaiGlobal
        }
        return region
    }

    nonisolated static func storeRegion(_ region: Region) {
        UserDefaults.standard.set(region.rawValue, forKey: AppPreferenceKeys.usageQuotaRegion)
    }

    // MARK: - State

    private(set) var state: State = .idle

    private let cacheDuration: TimeInterval
    private let now: () -> Date
    private let apiKeyProvider: () -> String?
    private let load: (Region, String) async throws -> QuotaSnapshot
    private var lastLoadedAt: Date?

    init(
        cacheDuration: TimeInterval = 5 * 60,
        now: @escaping () -> Date = Date.init,
        apiKeyProvider: @escaping () -> String? = UsageQuotaService.storedAPIKey,
        load: @escaping (Region, String) async throws -> QuotaSnapshot = UsageQuotaService.fetch
    ) {
        self.cacheDuration = cacheDuration
        self.now = now
        self.apiKeyProvider = apiKeyProvider
        self.load = load
    }

    /// True when an API key is configured, regardless of the last result.
    var isConfigured: Bool {
        !(Self.storedAPIKey() ?? "").isEmpty
    }

    /// Clears cached state after the stored key changes or is removed.
    func reset() {
        lastLoadedAt = nil
        state = .idle
    }

    /// Installs a screenshot-fixture state, bypassing the network.
    func applyFixtureState(_ newState: State) {
        state = newState
        lastLoadedAt = now()
    }

    /// Fetches the quota snapshot unless a recent one is still fresh.
    /// Keeps the last known snapshot if a refresh fails.
    func refresh(force: Bool = false) async {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            state = .idle
            return
        }
        if case .loading = state { return }
        if !force, let lastLoadedAt, now().timeIntervalSince(lastLoadedAt) < cacheDuration { return }

        let previous = state
        if case .loaded = previous {} else { state = .loading }

        do {
            let snapshot = try await load(Self.storedRegion(), apiKey)
            state = .loaded(snapshot)
            lastLoadedAt = now()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                state = previous
                return
            }
            switch error as? UsageQuotaError {
            case .keyRejected(let detail):
                Logger.usageQuota.error("Usage quota key rejected: \(detail ?? "no detail", privacy: .public)")
                state = .keyRejected(detail)
            case .noLimitsReported:
                state = .noLimitsReported
            default:
                Logger.usageQuota.error("Failed to load usage quota: \(error.localizedDescription, privacy: .public)")
                if case .loaded = previous {
                    state = previous
                } else {
                    state = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Networking

    static func fetch(region: Region, apiKey: String) async throws -> QuotaSnapshot {
        guard let url = URL(string: "\(region.host)/api/monitor/usage/quota/limit") else {
            throw UsageQuotaError.invalidResponse
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageQuotaError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw UsageQuotaError.keyRejected(String(data: data, encoding: .utf8))
        default:
            throw UsageQuotaError.invalidResponse
        }

        return try decodeSnapshot(from: data, fetchedAt: Date())
    }

    // MARK: - Decoding

    static func decodeSnapshot(from data: Data, fetchedAt: Date) throws -> QuotaSnapshot {
        let root = try JSONDecoder().decode(QuotaResponse.self, from: data)

        // Coding-plan windows only; TIME_LIMIT covers MCP lanes, not the plan.
        let limits: [LimitEntry] = root.data?.limits ?? []
        var entries: [LimitEntry] = []
        for entry in limits {
            if let type = entry.type, Self.isCodingPlanLimit(type) {
                entries.append(entry)
            }
        }
        entries.sort { lhs, rhs in (lhs.durationSeconds ?? 0) < (rhs.durationSeconds ?? 0) }

        var windows: [QuotaWindow] = []
        for (index, entry) in entries.enumerated() {
            let percentage: Int = min(max(entry.percentage ?? 0, 0), 100)
            windows.append(
                QuotaWindow(
                    id: "\(entry.type ?? "limit")-\(index)",
                    title: Self.windowTitle(durationSeconds: entry.durationSeconds),
                    percentage: percentage,
                    resetAt: Self.resetDate(fromMilliseconds: entry.nextResetTime)
                )
            )
        }

        guard !windows.isEmpty else {
            throw UsageQuotaError.noLimitsReported
        }

        return QuotaSnapshot(
            planName: root.data?.planName,
            windows: windows,
            fetchedAt: fetchedAt
        )
    }

    private static func resetDate(fromMilliseconds value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        let seconds = value > 1e12 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func isCodingPlanLimit(_ type: String) -> Bool {
        type.uppercased() == "TOKENS_LIMIT" || type.uppercased() == "CREDIT_LIMIT"
    }

    private static func windowTitle(durationSeconds: Int?) -> String {
        switch durationSeconds {
        case .some(0...21600): return AppText.quotaWindow5Hour
        case .some(432000...691200): return AppText.quotaWindowWeekly
        default: return AppText.quotaWindowUsage
        }
    }

    private struct QuotaResponse: Decodable {
        let data: QuotaData?

        enum CodingKeys: String, CodingKey { case data }
    }

    private struct QuotaData: Decodable {
        let planName: String?
        let limits: [LimitEntry]?

        enum CodingKeys: String, CodingKey {
            case planName, limits
            case plan = "plan", planType = "plan_type", packageName = "packageName", level = "level"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var resolvedPlanName: String?
            for key: CodingKeys in [.planName, .plan, .planType, .packageName, .level] {
                if let value = try container.decodeIfPresent(String.self, forKey: key) {
                    resolvedPlanName = value
                    break
                }
            }
            planName = resolvedPlanName
            limits = try container.decodeIfPresent([LimitEntry].self, forKey: .limits)
        }
    }

    private struct LimitEntry: Decodable {
        let type: String?
        let percentage: Int?
        let nextResetTime: Double?
        let durationSeconds: Int?

        private struct Window: Decodable {
            let unit: String?
            let number: Int?
        }

        enum CodingKeys: String, CodingKey {
            case type, percentage
            case nextResetTime
            case duration = "duration"
            case window = "window"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            percentage = try container.decodeIfPresent(Int.self, forKey: .percentage)
            nextResetTime = try container.decodeIfPresent(Double.self, forKey: .nextResetTime)

            var seconds: Int?
            if let window = try container.decodeIfPresent(Window.self, forKey: .window),
               let number = window.number {
                seconds = Self.durationSeconds(unit: window.unit, number: number)
            } else if let window = try container.decodeIfPresent(Window.self, forKey: .duration),
                      let number = window.number {
                seconds = Self.durationSeconds(unit: window.unit, number: number)
            }
            durationSeconds = seconds
        }

        private static func durationSeconds(unit: String?, number: Int) -> Int? {
            switch unit?.uppercased() {
            case "SECOND", "SECONDS": number
            case "MINUTE", "MINUTES": number * 60
            case "HOUR", "HOURS": number * 3600
            case "DAY", "DAYS": number * 86400
            case nil: nil
            default: number
            }
        }
    }
}
