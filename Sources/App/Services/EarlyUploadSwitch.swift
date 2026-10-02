import Vapor

/// U2 (FABLE-U1-U2-DESIGN §2): the product switch for uploading Contractor-link photos as they are added (`earlyUpload` on the
/// Contractor page GET). The Worker reads its own `CONTRACTOR_EARLY_UPLOAD` variable and forwards the decision on every request
/// it proxies as `X-Snaglist-Early-Upload` — `enabled`, or a comma-separated list of workspace ids for a canary — after always
/// removing one a caller sent (`Infrastructure/cloudflare/src/early-upload.mjs`, `proxy.mjs`). Absent, or anything else, is off.
///
/// It replaces the staging coupling to `RUNTIME_DIAGNOSTICS`: early uploads never need Server-Timing, the diagnostics route or the
/// failure record, which keep that switch as their own. A vars-only Worker deploy turns it on or off without an image rollout.
/// The container is reached only through the Worker's Durable Object; where it is reachable directly (local runs), the header
/// grants nothing a contractor could not do from their own browser — it only chooses when the page uploads.
enum EarlyUploadSwitch {
    static let header = "X-Snaglist-Early-Upload"

    static func enabled(_ req: Request, workspaceID: UUID?) -> Bool {
        guard let value = req.headers.first(name: header), value.count <= 4096 else { return false }
        if value == "enabled" { return true }
        guard let workspaceID else { return false }
        let ids = value.split(separator: ",", omittingEmptySubsequences: false).map { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
        guard !ids.isEmpty, ids.allSatisfy({ $0 != nil }) else { return false }
        return ids.contains(workspaceID)
    }
}
