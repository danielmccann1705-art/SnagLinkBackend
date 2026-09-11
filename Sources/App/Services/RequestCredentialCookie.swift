import Vapor

/// Read our opaque credential cookies without treating Cookie as an HTTP list
/// header. Google's g_state cookie contains JSON commas/quotes; the generic
/// directives parser can otherwise hide the cookies that follow it. Unrelated
/// cookie values are ignored, while our selected credential is strict and unique.
enum RequestCredentialCookie {
    static func value(_ name: String, on req: Request) -> String? {
        value(name, in: req.headers["Cookie"])
    }

    static func value(_ name: String, in headers: [String]) -> String? {
        guard headers.reduce(0, { $0 + $1.utf8.count }) <= 32_768 else { return nil }
        var found: String?
        for header in headers {
            for pair in header.split(separator: ";", omittingEmptySubsequences: true) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                guard key == name else { continue }
                // Refuse duplicates even when equal, quoted/encoded guesses or
                // malformed values. Session/PIN services still verify the proof.
                guard found == nil, parts.count == 2 else { return nil }
                let value = String(parts[1])
                guard !value.isEmpty, value.utf8.count <= 128,
                      value.utf8.allSatisfy({ byte in
                          byte == 0x21 || (0x23...0x2B).contains(byte) || (0x2D...0x3A).contains(byte)
                            || (0x3C...0x5B).contains(byte) || (0x5D...0x7E).contains(byte)
                      }) else { return nil }
                found = value
            }
        }
        return found
    }
}
