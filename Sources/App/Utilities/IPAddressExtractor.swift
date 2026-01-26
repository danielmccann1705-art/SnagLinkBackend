import Vapor

struct IPAddressExtractor {
    /// Extracts the client IP address from a request
    /// Handles proxied requests (X-Forwarded-For, X-Real-IP headers)
    /// - Parameter request: The incoming request
    /// - Returns: The client IP address string
    static func extract(from request: Request) -> String {
        // Check X-Forwarded-For header first (common for proxied requests)
        if let forwardedFor = request.headers.first(name: "X-Forwarded-For") {
            // X-Forwarded-For can contain multiple IPs: "client, proxy1, proxy2"
            // The first one is the original client
            let ips = forwardedFor.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if let clientIP = ips.first, !clientIP.isEmpty {
                return String(clientIP)
            }
        }

        // Check X-Real-IP header (used by some proxies)
        if let realIP = request.headers.first(name: "X-Real-IP"), !realIP.isEmpty {
            return realIP
        }

        // Check CF-Connecting-IP header (Cloudflare)
        if let cfIP = request.headers.first(name: "CF-Connecting-IP"), !cfIP.isEmpty {
            return cfIP
        }

        // Fall back to the direct connection address
        if let peerAddress = request.peerAddress {
            return peerAddress.ipAddress ?? "unknown"
        }

        return "unknown"
    }

    /// Extracts the User-Agent from a request
    /// - Parameter request: The incoming request
    /// - Returns: The User-Agent string or nil if not present
    static func extractUserAgent(from request: Request) -> String? {
        return request.headers.first(name: .userAgent)
    }
}
