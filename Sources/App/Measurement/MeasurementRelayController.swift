import Vapor

struct MeasurementRelayController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let measurement = routes.grouped("api", "v2", "measurement").grouped(PlatformAuthMiddleware())
        measurement.put("devices", "att", use: observeATT)
        measurement.post("devices", use: bindDevice)
        measurement.post("events", use: acceptEvent)
        measurement.on(.POST, "apple", body: .collect(maxSize: "4kb"), use: acceptApple)
        measurement.on(.POST, "purchase-intents", body: .collect(maxSize: "4kb"), use: preparePurchaseIntent)
        measurement.on(.POST, "purchase-intents", ":intentId", "witness",
                       body: .collect(maxSize: "4kb"), use: acceptPurchaseWitness)
        measurement.on(.POST, "apple", "purchase-intents", body: .collect(maxSize: "4kb"),
                       use: prepareApplePurchaseIntent)
        measurement.on(.POST, "apple", "purchase-intents", ":intentId", "witness",
                       body: .collect(maxSize: "4kb"), use: acceptApplePurchaseWitness)
    }

    @Sendable func observeATT(req: Request) async throws -> MeasurementPermissionsEnvelope {
        try await MeasurementRelayService.observeATT(accountID: req.requireAuthenticatedUserId(),
            input: try decode(MeasurementATTObservation.self, req), on: req.db)
    }

    @Sendable func bindDevice(req: Request) async throws -> Response {
        try await MeasurementRelayService.bindDevice(accountID: req.requireAuthenticatedUserId(),
            input: try decode(MeasurementDeviceBinding.self, req), app: req.application, on: req.db)
        return Response(status: .noContent)
    }

    @Sendable func acceptEvent(req: Request) async throws -> Response {
        try await MeasurementRelayService.acceptProductEvent(accountID: req.requireAuthenticatedUserId(),
            input: try decode(MeasurementProductEventUpload.self, req), on: req.db)
        return Response(status: .accepted)
    }

    @Sendable func acceptApple(req: Request) async throws -> Response {
        let reference = try await MeasurementRelayService.acceptApple(accountID: req.requireAuthenticatedUserId(),
            input: try decode(MeasurementAppleUpload.self, req), app: req.application, on: req.db)
        let response = Response(status: .created)
        try response.content.encode(AdMeasurementReceipt(reference: reference))
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    @Sendable func preparePurchaseIntent(req: Request) async throws -> Response {
        let result = try await PurchaseOriginService.prepare(
            accountID: req.requireAuthenticatedUserId(),
            input: try decode(MeasurementPurchaseIntentRequest.self, req),
            app: req.application,
            on: req.db
        )
        let response = Response(status: .created)
        try response.content.encode(result)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    @Sendable func acceptPurchaseWitness(req: Request) async throws -> Response {
        guard let text = req.parameters.get("intentId"), let intentID = UUID(uuidString: text) else {
            throw Abort(.notFound)
        }
        let result = try await PurchaseOriginService.complete(
            accountID: req.requireAuthenticatedUserId(),
            intentID: intentID,
            input: try decode(MeasurementPurchaseWitnessRequest.self, req),
            app: req.application,
            on: req.db
        )
        guard result == .accepted else {
            throw Abort(.conflict, reason: "Purchase measurement evidence conflicts",
                        identifier: "measurement_purchase_conflict")
        }
        return Response(status: .accepted)
    }

    @Sendable func prepareApplePurchaseIntent(req: Request) async throws -> Response {
        let result = try await ApplePurchaseOriginService.prepare(
            accountID: req.requireAuthenticatedUserId(),
            input: try decode(MeasurementPurchaseIntentRequest.self, req),
            app: req.application, on: req.db)
        let response = Response(status: .created)
        try response.content.encode(result)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    @Sendable func acceptApplePurchaseWitness(req: Request) async throws -> Response {
        guard let text = req.parameters.get("intentId"), let intentID = UUID(uuidString: text) else {
            throw Abort(.notFound)
        }
        let result = try await ApplePurchaseOriginService.complete(
            accountID: req.requireAuthenticatedUserId(), intentID: intentID,
            input: try decode(MeasurementPurchaseWitnessRequest.self, req),
            app: req.application, on: req.db)
        guard result == .accepted else {
            throw Abort(.conflict, reason: "Apple purchase measurement evidence conflicts",
                        identifier: "apple_purchase_measurement_conflict")
        }
        return Response(status: .accepted)
    }

    private func decode<T: Content>(_ type: T.Type, _ req: Request) throws -> T {
        do { return try req.content.decode(type) }
        catch { throw Abort(.badRequest, reason: "Use a valid measurement request", identifier: "measurement_request_invalid") }
    }
}
