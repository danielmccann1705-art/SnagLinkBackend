import Vapor
import Fluent

/// 2.0.2 Apple ads measurement routes (IOS-2.0.2-SLICE1.md item 13; MEASUREMENT-DECISION.md §3.4; EVENT-CONTRACT.md
/// row 1). Both unauthenticated, as the app calls them (`APIClient+AdMeasurement.swift`, `authenticated: false`):
///
///   POST   /api/v1/ad-measurement/apple              {token, rcAppUserID, appVersion} → 201 {"reference"}
///                                                    503 while `adMeasurementEnabled` does not resolve to true;
///                                                    400 for a body it cannot accept; 413 over 4 KB
///   DELETE /api/v1/ad-measurement/apple/:reference   200 {"deleted": true}, or 404 when there is no such record
///
/// No account is consulted and none is linked: the record is keyed by the RevenueCat app user ID the app sends
/// (D7: consent and the record belong to the installation). The withdrawal's only credential is the 128-bit
/// reference, and it is accepted whatever the switch says. Both are rate limited per client like the other
/// anonymous lookups (`.tokenLookup`, keyed by a hash of the address, so no address is stored for this feature).
///
/// Nothing here logs. The request logger records the route pattern and status only, so neither the token, the
/// reference nor the app user ID reaches a log line; error answers never echo a value.
struct AdMeasurementController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let apple = routes.grouped("api", "v1", "ad-measurement", "apple")
        apple.on(.POST, body: .collect(maxSize: "4kb"), use: create)
        apple.delete(":reference", use: withdraw)
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        try await limit(req)
        // The server-side mirror of the app's fail-closed rule: refused before the body is read.
        guard await AdMeasurementPolicy.isEnabled(on: req.db) else {
            throw Abort(.serviceUnavailable, reason: "Advert measurement is switched off", identifier: "ad_measurement_off")
        }
        guard let body = req.body.data, let upload = AdAttributionStore.Upload.validated(Data(body.readableBytesView)) else {
            throw Abort(.badRequest, reason: "This measurement request could not be accepted", identifier: "ad_measurement_invalid")
        }
        let reference = try await AdAttributionStore.insert(upload, now: Date(), on: req.db)
        let response = Response(status: .created)
        try response.content.encode(AdMeasurementReceipt(reference: reference))
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    @Sendable
    func withdraw(req: Request) async throws -> Response {
        try await limit(req)
        guard let reference = AdAttributionStore.normalisedReference(req.parameters.get("reference") ?? ""),
              try await AdAttributionStore.delete(reference: reference, on: req.db) else {
            throw Abort(.notFound, reason: "There is no measurement record with this reference", identifier: "ad_measurement_not_found")
        }
        let response = Response(status: .ok)
        try response.content.encode(AdMeasurementDeletion(deleted: true))
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    private func limit(_ req: Request) async throws {
        let key = "ad-measurement:" + SHA256Hasher.hash(token: "ad-measurement:" + IPAddressExtractor.extract(from: req))
        try await RateLimitService.enforce(key: key, action: .tokenLookup, on: req.db)
    }
}

struct AdMeasurementReceipt: Content, Equatable {
    let reference: String
}

struct AdMeasurementDeletion: Content, Equatable {
    let deleted: Bool
}
