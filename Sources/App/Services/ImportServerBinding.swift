import Vapor

/// Separate from PORTAL_ORIGIN, BASE_URL and untrusted request Host. An origin
/// change creates a different binding; this service does not migrate aliases.
struct ImportServerBinding: Sendable {
    let environment: String
    let apiOrigin: String
    var destination: LegacyImportPreviewCommand.Destination { .init(environment: environment, apiOrigin: apiOrigin) }

    init(environment: String, apiOrigin: String) throws {
        guard ["development", "staging", "production"].contains(environment), apiOrigin.utf8.count <= 512,
              var parts = URLComponents(string: apiOrigin),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(),
              !host.isEmpty, !host.hasSuffix("."), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw Self.unconfigured() }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (environment == "development" && scheme == "http" && loopback) else { throw Self.unconfigured() }
        parts.scheme = scheme; parts.host = host; parts.path = ""
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        guard let canonical = parts.url?.absoluteString else { throw Self.unconfigured() }
        self.environment = environment; self.apiOrigin = canonical
    }

    static func load(on app: Application) throws -> Self {
        let platform = try PlatformConfiguration.load(on: app)
        // The existing backend uses "local"; native explicitly calls it "development".
        let expected = platform.environment == "local" ? "development" : platform.environment
        let value: Self
        if let injected = app.storage[ImportServerBindingKey.self] { value = injected }
        else {
            guard let origin = Environment.get("IMPORT_PREVIEW_API_ORIGIN") else { throw unconfigured() }
            value = try Self(environment: expected, apiOrigin: origin)
        }
        guard value.environment == expected, !(app.environment == .production && expected == "development") else { throw unconfigured() }
        return value
    }
    static func unconfigured() -> Abort { Abort(.serviceUnavailable, reason: "Import preview's API identity is not configured", identifier: "import_preview_unconfigured") }
}
struct ImportServerBindingKey: StorageKey { typealias Value = ImportServerBinding }
