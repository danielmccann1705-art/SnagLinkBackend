import Vapor
import Fluent
import Foundation
import JWT

/// Service for sending Apple Push Notifications via APNs HTTP/2 API.
/// Uses jwt-kit (already a dependency) for ES256 JWT signing and Vapor's Client for HTTP/2.
struct APNsService {

    // MARK: - Configuration

    private static var keyId: String? { Environment.get("APNS_KEY_ID") }
    private static var teamId: String? { Environment.get("APNS_TEAM_ID") }
    private static var privateKeyBase64: String? { Environment.get("APNS_PRIVATE_KEY") }
    private static var bundleId: String? { Environment.get("APNS_BUNDLE_ID") }
    private static var environment: String { Environment.get("APNS_ENVIRONMENT") ?? "sandbox" }

    private static var apnsHost: String {
        environment == "production"
            ? "https://api.push.apple.com"
            : "https://api.sandbox.push.apple.com"
    }

    // MARK: - JWT Token Cache

    private static var cachedToken: String?
    private static var cachedTokenTimestamp: Date?
    private static let tokenLifetime: TimeInterval = 50 * 60 // Refresh after 50 min (APNs allows 60)

    // MARK: - APNs JWT Payload

    private struct APNsJWTPayload: JWTPayload {
        let iss: IssuerClaim
        let iat: IssuedAtClaim

        func verify(using signer: JWTSigner) throws {
            // APNs tokens don't need expiration verification on our side
        }
    }

    // MARK: - APNs Error Response

    private struct APNsErrorResponse: Decodable {
        let reason: String?
    }

    // MARK: - Public Methods

    /// Sends a push notification to a single device token.
    static func sendPush(
        to deviceToken: String,
        title: String,
        body: String,
        completionId: UUID,
        snagId: UUID,
        client: Client,
        logger: Logger
    ) async throws -> Bool {
        logger.info("APNs: Preparing notification for device \(deviceToken.prefix(8))...")

        guard let bundleId = bundleId else {
            logger.warning("APNs: APNS_BUNDLE_ID not configured, skipping push")
            return false
        }

        let jwt = try getOrCreateToken(logger: logger)

        let payload: [String: Any] = [
            "aps": [
                "alert": [
                    "title": title,
                    "body": body
                ],
                "sound": "default"
            ],
            "completionId": completionId.uuidString,
            "snagId": snagId.uuidString
        ]

        let payloadData = try JSONSerialization.data(withJSONObject: payload)

        let url = URI(string: "\(apnsHost)/3/device/\(deviceToken)")

        let response = try await client.post(url) { req in
            req.headers.add(name: .authorization, value: "bearer \(jwt)")
            req.headers.add(name: "apns-topic", value: bundleId)
            req.headers.add(name: "apns-push-type", value: "alert")
            req.headers.add(name: "apns-priority", value: "10")
            req.headers.add(name: .contentType, value: "application/json")
            req.body = .init(data: payloadData)
        }

        logger.info("APNs: Response status: \(response.status)")

        if response.status == .ok {
            logger.info("APNs: Push sent successfully to \(deviceToken.prefix(8))...")
            return true
        }

        // Check for token-related errors that mean the device token is stale
        if let body = response.body,
           let errorResponse = try? JSONDecoder().decode(APNsErrorResponse.self, from: body) {
            let reason = errorResponse.reason ?? ""
            logger.info("APNs: Response reason: \(reason)")
            if reason == "BadDeviceToken" || reason == "Unregistered" {
                logger.warning("APNs: Stale device token \(deviceToken.prefix(8))...: \(reason)")
                return false
            }
            logger.error("APNs: Push failed with reason: \(reason) (HTTP \(response.status.code))")
        } else {
            logger.error("APNs: Push failed with HTTP \(response.status.code)")
        }

        return true // Don't delete token for non-stale errors
    }

    /// Sends a completion notification to all device tokens for a given user.
    /// Cleans up stale device tokens automatically.
    static func sendCompletionNotification(
        toUserId userId: UUID,
        contractorName: String,
        snagTitle: String,
        completionId: UUID,
        snagId: UUID,
        client: Client,
        logger: Logger,
        db: Database
    ) async throws {
        // Check if APNs is configured
        guard keyId != nil, teamId != nil, privateKeyBase64 != nil, bundleId != nil else {
            logger.info("APNs: Not configured, skipping push notification")
            return
        }

        // Look up all device tokens for this user
        let deviceTokens = try await DeviceToken.query(on: db)
            .filter(\.$userId == userId)
            .all()

        logger.info("APNs: Found \(deviceTokens.count) device token(s) for user")

        guard !deviceTokens.isEmpty else {
            logger.info("APNs: No device tokens registered for user")
            return
        }

        let title = "✅ Snag Completed"
        let body = "\(contractorName) completed \(snagTitle)"

        var staleTokenIds: [UUID] = []

        for token in deviceTokens {
            do {
                let isValid = try await sendPush(
                    to: token.deviceToken,
                    title: title,
                    body: body,
                    completionId: completionId,
                    snagId: snagId,
                    client: client,
                    logger: logger
                )
                if !isValid, let tokenId = token.id {
                    staleTokenIds.append(tokenId)
                }
            } catch {
                logger.error("APNs: Failed to send push to device \(token.deviceToken.prefix(8))...: \(error)")
            }
        }

        // Clean up stale tokens
        if !staleTokenIds.isEmpty {
            try? await DeviceToken.query(on: db)
                .filter(\.$id ~~ staleTokenIds)
                .delete()
            logger.info("APNs: Cleaned up \(staleTokenIds.count) stale device token(s)")
        }
    }

    // MARK: - Private Methods

    private static func getOrCreateToken(logger: Logger) throws -> String {
        // Return cached token if still valid
        if let cached = cachedToken,
           let timestamp = cachedTokenTimestamp,
           Date().timeIntervalSince(timestamp) < tokenLifetime {
            return cached
        }

        guard let keyId = keyId,
              let teamId = teamId,
              let privateKeyBase64 = privateKeyBase64 else {
            throw Abort(.internalServerError, reason: "APNs credentials not configured")
        }

        // Decode base64 private key to PEM
        guard let keyData = Data(base64Encoded: privateKeyBase64),
              let pem = String(data: keyData, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Invalid APNs private key encoding")
        }

        let ecKey = try ECDSAKey.private(pem: pem)
        let signer = JWTSigner.es256(key: ecKey)

        let payload = APNsJWTPayload(
            iss: IssuerClaim(value: teamId),
            iat: IssuedAtClaim(value: Date())
        )

        let token = try signer.sign(payload, kid: JWKIdentifier(string: keyId))

        cachedToken = token
        cachedTokenTimestamp = Date()

        logger.info("APNs: Generated new JWT token")
        return token
    }
}
