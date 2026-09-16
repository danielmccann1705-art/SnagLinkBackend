import Vapor

/// Authorises the internal maintenance route.
///
/// Fails closed in the strongest sense available: with no secret configured the route
/// does not exist at all, and a wrong secret gets the same 404. A 401 would tell an
/// unauthenticated caller there is something here worth guessing at.
enum MaintenanceAuthority {
    static func secret(_ app: Application) -> String? {
        if app.environment == .testing, let configured = app.storage[MaintenanceSecretKey.self] { return configured }
        guard let value = Environment.get("MAINTENANCE_SECRET"), value.count >= 32 else { return nil }
        return value
    }

    static func authorise(_ req: Request) throws {
        guard let expected = secret(req.application),
              let presented = req.headers.bearerAuthorization?.token,
              constantTimeEqual(presented, expected) else {
            throw Abort(.notFound)
        }
    }

    /// A short-circuiting comparison on a shared secret leaks its prefix through timing.
    /// Cheap to avoid, so avoid it.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

struct MaintenanceSecretKey: StorageKey { typealias Value = String }
