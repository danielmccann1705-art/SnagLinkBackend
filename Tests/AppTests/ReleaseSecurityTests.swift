@testable import App
import XCTVapor
import Fluent
import JWT

/// Run with an explicitly configured disposable PostgreSQL database.
final class ReleaseSecurityTests: XCTestCase {
    private var app: Application!
    private var createdUserIDs: [UUID] = []

    override func setUp() async throws {
        try XCTSkipUnless(Environment.get("DATABASE_URL") != nil, "Requires isolated PostgreSQL DATABASE_URL")
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        if let app {
            do {
                // Device-token rows cascade; never remove another test's fixtures.
                if !createdUserIDs.isEmpty {
                    try await User.query(on: app.db).filter(\.$id ~~ createdUserIDs).delete()
                }
            } catch {
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
        app = nil
        createdUserIDs = []
    }

    private func makeUser() async throws -> User {
        let user = User(appleUserId: nil,
                        email: "release-\(UUID().uuidString.lowercased())@example.test",
                        name: "Release test", authProvider: .magicLink)
        try await user.save(on: app.db)
        createdUserIDs.append(try user.requireID())
        return user
    }

    private func jwt(for userID: UUID) throws -> String {
        try app.jwt.signers.sign(UserJWTPayload(
            subject: .init(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(600)),
            userId: userID
        ))
    }

    private func makeDevice(for userID: UUID) async throws -> DeviceToken {
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        let device = DeviceToken(userId: userID, deviceToken: token, platform: "ios")
        try await device.save(on: app.db)
        return device
    }

    private func expectProjects(jwt: String, status: HTTPResponseStatus) async throws {
        try await app.test(.GET, "api/v1/projects", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: jwt)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, status)
        })
    }

    private func unregister(_ deviceToken: String, jwt: String, status: HTTPResponseStatus) async throws {
        try await app.test(.DELETE, "api/v1/devices/unregister", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: jwt)
            try req.content.encode(["deviceToken": deviceToken])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, status)
        })
    }

    func testMissingAccountJWTIsRejectedOnAuthenticatedReadAndWriteRoutes() async throws {
        let token = try jwt(for: UUID())
        try await expectProjects(jwt: token, status: .unauthorized)
        try await unregister(String(repeating: "a", count: 64), jwt: token, status: .unauthorized)
    }

    func testDeletedAccountJWTStopsWorkingImmediately() async throws {
        let user = try await makeUser()
        let userID = try user.requireID()
        let token = try jwt(for: userID)
        try await expectProjects(jwt: token, status: .ok)

        try await user.delete(on: app.db)
        let deletedUser = try await User.find(userID, on: app.db)
        XCTAssertNil(deletedUser)

        try await expectProjects(jwt: token, status: .unauthorized)
        try await unregister(String(repeating: "b", count: 64), jwt: token, status: .unauthorized)
    }

    func testDirectUploadJWTRequiresExistingAccountBeforeFileValidation() async throws {
        let missingToken = try jwt(for: UUID())
        let user = try await makeUser()
        let liveToken = try jwt(for: user.requireID())
        for (token, expectedStatus) in [(missingToken, HTTPResponseStatus.unauthorized),
                                        (liveToken, HTTPResponseStatus.badRequest)] {
            // Deliberately omit the file so this test cannot persist an upload.
            try await app.test(.POST, "api/v1/uploads/photo", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async in XCTAssertEqual(res.status, expectedStatus) })
        }
        try await user.delete(on: app.db)
        try await app.test(.POST, "api/v1/uploads/photo", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: liveToken)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .unauthorized) })
    }

    func testUnregisterCannotRemoveAnotherUsersDevice() async throws {
        let owner = try await makeUser()
        let other = try await makeUser()
        let ownDevice = try await makeDevice(for: owner.requireID())
        let otherDevice = try await makeDevice(for: other.requireID())
        let token = try jwt(for: owner.requireID())

        // Idempotent 204 avoids revealing whether another account owns the token.
        try await unregister(otherDevice.deviceToken, jwt: token, status: .noContent)

        let retainedOwn = try await DeviceToken.find(ownDevice.id, on: app.db)
        let retainedOther = try await DeviceToken.find(otherDevice.id, on: app.db)
        XCTAssertEqual(retainedOwn?.userId, owner.id)
        XCTAssertEqual(retainedOwn?.deviceToken, ownDevice.deviceToken)
        XCTAssertEqual(retainedOther?.userId, other.id)
        XCTAssertEqual(retainedOther?.deviceToken, otherDevice.deviceToken)
    }

    func testOwnDeviceUnregisterSucceedsAndIsIdempotent() async throws {
        let owner = try await makeUser()
        let other = try await makeUser()
        let ownDevice = try await makeDevice(for: owner.requireID())
        let otherDevice = try await makeDevice(for: other.requireID())
        let token = try jwt(for: owner.requireID())

        try await unregister(ownDevice.deviceToken, jwt: token, status: .noContent)
        let removedOwn = try await DeviceToken.find(ownDevice.id, on: app.db)
        let retainedOther = try await DeviceToken.find(otherDevice.id, on: app.db)
        XCTAssertNil(removedOwn)
        XCTAssertEqual(retainedOther?.userId, other.id)

        try await unregister(ownDevice.deviceToken, jwt: token, status: .noContent)
        let stillRetainedOther = try await DeviceToken.find(otherDevice.id, on: app.db)
        XCTAssertEqual(stillRetainedOther?.deviceToken, otherDevice.deviceToken)
    }
}
