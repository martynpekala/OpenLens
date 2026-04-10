import Foundation
import os

/// Pure service for loading AI providers and model configuration.
/// No SwiftUI imports, no direct UI mutations.
final class ProvidersService {

    private let connection: ConnectionManager

    init(connection: ConnectionManager) {
        self.connection = connection
    }

    // MARK: - Result Type

    /// The result of loading providers from the server.
    struct ProvidersResult {
        let providers: [OCProvider]
        let connectedProviderIDs: [String]
        let defaultProviderID: String?
        let defaultModelID: String?
    }

    // MARK: - Load Providers

    /// Fetch providers and connected/default model info.
    func loadProviders() async throws -> ProvidersResult {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.providersResult
        }

        guard let client = connection.client else {
            throw OpenCodeError.notConnected
        }

        let response = try await client.listProviders()

        var defaultProviderID: String?
        var defaultModelID: String?

        if let def = response.default {
            defaultProviderID = def["id"]
            defaultModelID = def["model"]
        }

        Logger.providers.info("Loaded \(response.all.count) providers, connected: \(response.connected ?? [], privacy: .public)")
        for p in response.all {
            Logger.providers.debug("  \(p.id, privacy: .public): \(p.models.count) models")
        }

        return ProvidersResult(
            providers: response.all,
            connectedProviderIDs: response.connected ?? [],
            defaultProviderID: defaultProviderID,
            defaultModelID: defaultModelID
        )
    }

    // MARK: - Config Result

    /// Everything we extract from `GET /config`.
    struct ConfigResult {
        /// Default model parsed from config's `model` field (e.g. "anthropic/claude-sonnet").
        let defaultProviderID: String?
        let defaultModelID: String?
        /// When non-nil, ONLY these providers should be shown.
        let enabledProviders: [String]?
        /// These providers should be hidden even if connected.
        let disabledProviders: [String]?
    }

    // MARK: - Load Config

    /// Fetch server config — used for default model fallback AND provider filtering.
    func loadConfig() async -> ConfigResult {
        if ScreenshotFixtures.isEnabled {
            return ScreenshotFixtures.configResult
        }

        guard let client = connection.client else {
            return ConfigResult(defaultProviderID: nil, defaultModelID: nil,
                                enabledProviders: nil, disabledProviders: nil)
        }

        do {
            let config = try await client.getConfig()

            var providerID: String?
            var modelID: String?
            if let modelStr = config.model, !modelStr.isEmpty {
                let parts = modelStr.split(separator: "/", maxSplits: 1)
                if parts.count == 2 {
                    providerID = String(parts[0])
                    modelID = String(parts[1])
                }
            }

            return ConfigResult(
                defaultProviderID: providerID,
                defaultModelID: modelID,
                enabledProviders: config.enabledProviders,
                disabledProviders: config.disabledProviders
            )
        } catch {
            Logger.providers.warning("Failed to load config: \(error, privacy: .public)")
            return ConfigResult(defaultProviderID: nil, defaultModelID: nil,
                                enabledProviders: nil, disabledProviders: nil)
        }
    }

}
