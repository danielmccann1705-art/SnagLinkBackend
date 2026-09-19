@testable import App
import XCTVapor

final class ProductionImportGateTests: XCTestCase {
    func testProductionRequiresItsOwnSwitchAndExactHost() throws {
        let production = try ImportServerBinding(environment: "production", apiOrigin: "https://api.snaglist.dev")
        XCTAssertFalse(StagedLegacyImportHTTPGate.allows(binding: production, staged: false, production: false))
        XCTAssertFalse(StagedLegacyImportHTTPGate.allows(binding: production, staged: true, production: false))
        XCTAssertFalse(StagedLegacyImportHTTPGate.allows(binding: production, staged: true, production: true))
        XCTAssertTrue(StagedLegacyImportHTTPGate.allows(binding: production, staged: false, production: true))
        for origin in ["https://api.example.test", "https://staging-api.usesnaglist.com", "https://api.snaglist.dev:8443"] {
            let foreign = try ImportServerBinding(environment: "production", apiOrigin: origin)
            XCTAssertFalse(StagedLegacyImportHTTPGate.allows(binding: foreign, staged: false, production: true))
        }
    }
    func testProductionSwitchCannotEnableDevelopmentOrStaging() throws {
        for environment in ["development", "staging"] {
            let binding = try ImportServerBinding(environment: environment, apiOrigin: "https://synthetic.example.test")
            XCTAssertFalse(StagedLegacyImportHTTPGate.allows(binding: binding, staged: false, production: true))
            XCTAssertFalse(StagedLegacyImportHTTPGate.allows(binding: binding, staged: true, production: true))
            XCTAssertTrue(StagedLegacyImportHTTPGate.allows(binding: binding, staged: true, production: false))
        }
    }
    func testApplicationGuardDefaultsClosedAndPreservesBindingIdentity() async throws {
        let app = try await Application.make(.testing)
        app.storage[PlatformConfigurationKey.self] = .init(origin: "https://app.usesnaglist.com", environment: "production")
        app.storage[ImportServerBindingKey.self] = try ImportServerBinding(environment: "production", apiOrigin: "https://api.snaglist.dev")
        app.storage[StagedLegacyImportHTTPEnabledKey.self] = false
        app.storage[ProductionLegacyImportHTTPEnabledKey.self] = false
        XCTAssertThrowsError(try StagedLegacyImportHTTPGate.require(on: app))
        app.storage[ProductionLegacyImportHTTPEnabledKey.self] = true
        XCTAssertEqual(try StagedLegacyImportHTTPGate.require(on: app).apiOrigin, "https://api.snaglist.dev")
        app.storage[StagedLegacyImportHTTPEnabledKey.self] = true
        XCTAssertThrowsError(try StagedLegacyImportHTTPGate.require(on: app))
        try await app.asyncShutdown()
    }
}
