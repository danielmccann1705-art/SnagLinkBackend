import Vapor
import Fluent
import Foundation
import Crypto

struct WebReportController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        let m = routes.grouped("m")
        m.get(":slug", use: renderReport)
        m.post(":slug", "verify", use: verifyPIN)
        m.get(":slug", "photos.zip", use: downloadPhotosZip)

        // Older contractor emails used /link/:token. Redirect through the real
        // viewer so PIN, expiry and revocation checks remain in one place.
        routes.get("link", ":token") { req -> Response in
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            guard let token = req.parameters.get("token"),
                  let segment = token.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw Abort(.badRequest)
            }
            let response = req.redirect(to: "/m/\(segment)", redirectType: .temporary)
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
            return response
        }

        // B2: preview link viewer (unsent link, submissions disabled)
        routes.get("preview", ":token", use: renderPreview)

        // Debug route (JWT-protected)
        let debug = routes.grouped("api", "v1", "debug")
            .grouped(JWTAuthMiddleware())
        debug.get("photos", ":token", use: debugPhotos)
    }

    // MARK: - GET /m/:slug

    @Sendable
    func renderReport(req: Request) async throws -> Response {
        guard let slug = req.parameters.get("slug") else {
            return htmlResponse(WebReportRenderer.renderError(type: .notFound))
        }

        if slug.hasPrefix("c2_"), slug.count <= 100 {
            // Preserve a historical token/slug even if it happens to use this prefix.
            let legacy = try await MagicLink.query(on: req.db).group(.or) { $0.filter(\.$token == slug).filter(\.$slug == slug) }.first()
            if legacy == nil {
                let response = htmlResponse(WebReportRenderer.renderCanonicalContractor())
                response.headers.replaceOrAdd(name: "Content-Security-Policy", value: "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'self'; form-action 'self'")
                response.headers.replaceOrAdd(name: "X-Frame-Options", value: "SAMEORIGIN")
                return response
            }
        }

        // Validate magic link
        let magicLink: MagicLink
        do {
            magicLink = try await TokenValidationService.validateMagicLink(
                token: slug,
                on: req.db
            )
        } catch let error as TokenValidationService.ValidationError {
            let errorType: WebReportRenderer.ErrorType
            switch error {
            case .notFound: errorType = .notFound
            case .expired: errorType = .expired
            case .revoked: errorType = .revoked
            case .locked: errorType = .locked
            }
            return htmlResponse(WebReportRenderer.renderError(type: errorType))
        }

        // PIN check: if PIN required and no valid cookie, show PIN form
        if magicLink.requiresPIN {
            guard isPINVerified(req: req, magicLink: magicLink) else {
                let csrfToken = generateCSRFToken(slug: slug)
                return htmlResponse(WebReportRenderer.renderPINForm(slug: slug, csrfToken: csrfToken))
            }
        }

        // Record access
        try await TokenValidationService.recordAccess(
            magicLink: magicLink,
            request: req,
            pinVerified: magicLink.requiresPIN,
            on: req.db
        )

        return try await renderMagicLinkReport(magicLink: magicLink, slug: slug, req: req, preview: false)
    }

    // MARK: - GET /preview/:token  (B2)

    /// Renders the contractor web viewer for an *unsent preview* link, with a preview banner and
    /// submissions disabled client-side. PIN is bypassed and no access is recorded — this is the
    /// PM previewing their own draft. Server-side, CompletionController rejects any write to a
    /// preview link, so the disabling is defense-in-depth.
    @Sendable
    func renderPreview(req: Request) async throws -> Response {
        guard let token = req.parameters.get("token") else {
            return htmlResponse(WebReportRenderer.renderError(type: .notFound))
        }

        let magicLink: MagicLink
        do {
            magicLink = try await TokenValidationService.validateMagicLink(token: token, on: req.db)
        } catch let error as TokenValidationService.ValidationError {
            let errorType: WebReportRenderer.ErrorType
            switch error {
            case .notFound: errorType = .notFound
            case .expired: errorType = .expired
            case .revoked: errorType = .revoked
            case .locked: errorType = .locked
            }
            return htmlResponse(WebReportRenderer.renderError(type: errorType))
        }

        // Only genuine, unexpired preview links are viewable here.
        guard magicLink.previewMode, !magicLink.isPreviewExpired else {
            return htmlResponse(WebReportRenderer.renderError(type: .notFound))
        }

        return try await renderMagicLinkReport(magicLink: magicLink, slug: token, req: req, preview: true)
    }

    // MARK: - Shared report rendering

    /// Builds and renders the contractor report view for a magic link. When `preview` is true,
    /// a preview banner + submission-blocking script are injected into the rendered HTML.
    private func renderMagicLinkReport(magicLink: MagicLink, slug: String, req: Request, preview: Bool) async throws -> Response {
        // Fetch synced report
        let token = magicLink.token
        guard let syncedReport = try await SyncedReport.query(on: req.db)
            .filter(\.$magicLinkToken == token)
            .first() else {
            return htmlResponse(WebReportRenderer.renderError(type: .notSynced))
        }

        // Parse report JSON
        guard let jsonData = (try await SnagDeletionService.visibleReportJSON(syncedReport.reportJSON, ownerId: magicLink.createdById, projectId: magicLink.projectId, on: req.db)).data(using: .utf8) else {
            return htmlResponse(WebReportRenderer.renderError(type: .notSynced))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let report: SyncedReportJSON
        do {
            report = try decoder.decode(SyncedReportJSON.self, from: jsonData)
        } catch {
            req.logger.error("Failed to parse synced report JSON: \(error)")
            return htmlResponse(WebReportRenderer.renderError(type: .notSynced))
        }

        // Fetch synced photos: prefer snag-based lookup, fall back to token-based
        let reportSnagIds = (report.snags ?? []).compactMap { $0.id }
        let syncedPhotos: [SyncedPhoto]
        if !reportSnagIds.isEmpty {
            syncedPhotos = try await SyncedPhoto.query(on: req.db)
                .filter(\.$snagId ~~ reportSnagIds)
                .sort(\.$sortOrder)
                .all()
        } else {
            // A report with no active snags must not expose stale photo files.
            syncedPhotos = []
        }

        let baseURL = Environment.get("BASE_URL") ?? "https://snaglist.dev"
        let storageBaseURL = StorageService.publicBaseURL

        // Build raw photos by snag ID — URLs point to StorageService backend
        struct RawPhoto {
            let url: String
            let thumbnailUrl: String?
            let label: String
        }
        var rawPhotosBySnagId: [UUID: [RawPhoto]] = [:]
        for photo in syncedPhotos {
            let thumbnailUrl: String? = photo.thumbnailFilePath.map { "\(storageBaseURL)\($0)" }
            rawPhotosBySnagId[photo.snagId, default: []].append(
                RawPhoto(url: "\(storageBaseURL)\(photo.filePath)", thumbnailUrl: thumbnailUrl, label: photo.label)
            )
        }

        // Fetch synced drawings indexed by drawingId
        let syncedDrawings = try await SyncedDrawing.query(on: req.db)
            .filter(\.$magicLinkToken == token)
            .all()

        var drawingURLByDrawingId: [UUID: String] = [:]
        for drawing in syncedDrawings {
            drawingURLByDrawingId[drawing.drawingId] = "\(storageBaseURL)\(drawing.filePath)"
        }

        // Build snag data
        let projectName = report.resolvedProjectName ?? "Project"
        let contractorName = report.resolvedContractorName ?? "Contractor"
        let projectAddress = report.resolvedProjectAddress

        let snagDataItems: [WebReportRenderer.SnagData] = (report.snags ?? []).enumerated().map { index, snag in
            let snagIndex = index + 1
            let snagTitle = snag.title ?? "Untitled"

            // Look up synced photos by snag ID; only attempt if snag has a real ID
            let photos: [WebReportRenderer.PhotoData]
            if let snagId = snag.id, let rawPhotos = rawPhotosBySnagId[snagId] {
                photos = rawPhotos.map { raw in
                    WebReportRenderer.PhotoData(
                        url: raw.url,
                        thumbnailUrl: raw.thumbnailUrl,
                        label: raw.label,
                        snagIndex: snagIndex,
                        snagTitle: snagTitle
                    )
                }
            } else if let embeddedPhotos = snag.photos, !embeddedPhotos.isEmpty {
                photos = embeddedPhotos.compactMap { p in
                    guard let url = p.url, !url.isEmpty else { return nil }
                    return WebReportRenderer.PhotoData(
                        url: url,
                        thumbnailUrl: nil,
                        label: "before",
                        snagIndex: snagIndex,
                        snagTitle: snagTitle
                    )
                }
            } else {
                photos = []
            }

            // Resolve floor plan URL: prefer synced drawing, fall back to embedded URL
            let floorPlanURL: String?
            if let fpId = snag.floorPlanId, let drawingURL = drawingURLByDrawingId[fpId] {
                floorPlanURL = drawingURL
            } else {
                floorPlanURL = snag.floorPlanImageURL
            }

            return WebReportRenderer.SnagData(
                id: snag.id?.uuidString,
                index: snagIndex,
                title: snagTitle,
                description: snag.description,
                status: snag.status ?? "open",
                priority: snag.priority ?? "medium",
                location: snag.location,
                dueDate: snag.dueDate,
                assignedTo: snag.assignedTo ?? contractorName,
                photos: photos,
                floorPlanURL: floorPlanURL,
                pinX: snag.pinX,
                pinY: snag.pinY
            )
        }

        // Calculate status counts
        let openCount = snagDataItems.filter { SnagStatus.needsWork($0.status) }.count
        let inProgressCount = snagDataItems.filter { SnagStatus.isInProgressOrReview($0.status) }.count
        let completedCount = snagDataItems.filter {
            SnagStatus.isApproved($0.status)
        }.count

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        let generatedDate = dateFormatter.string(from: Date())

        let reportData = WebReportRenderer.ReportData(
            slug: slug,
            baseURL: baseURL,
            projectName: projectName,
            projectAddress: projectAddress,
            contractorName: contractorName,
            generatedDate: generatedDate,
            openCount: openCount,
            inProgressCount: inProgressCount,
            completedCount: completedCount,
            snags: snagDataItems,
            token: magicLink.token,
            accessLevel: magicLink.accessLevel
        )

        let html = WebReportRenderer.renderReport(data: reportData)
        return htmlResponse(preview ? Self.injectPreviewOverlay(into: html) : html)
    }

    /// Injects a fixed "PREVIEW" banner and a submission-blocking script into rendered report
    /// HTML. Markup-agnostic: only anchors on the single `</body>` in the report document, so it
    /// stays decoupled from the report renderer's internals. The banner + fetch/submit blocking
    /// are UX only — the authoritative guard is server-side in CompletionController.
    static func injectPreviewOverlay(into html: String) -> String {
        let overlay = """
        <div id="__snaglist_preview_banner">PREVIEW — this is what your contractor will see. Submissions are disabled.</div>
        <style>
            #__snaglist_preview_banner{position:fixed;top:0;left:0;right:0;z-index:2147483647;background:#168AAD;color:#fff;text-align:center;padding:10px 14px;font:600 13px/1.3 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;letter-spacing:0.02em;box-shadow:0 2px 6px rgba(0,0,0,0.15);}
            body{padding-top:42px !important;}
        </style>
        <script>
        (function(){
            var msg = "This is a preview — the contractor's submission is disabled here.";
            // Block any submission network calls (complete / status) in preview mode.
            if (window.fetch) {
                var origFetch = window.fetch;
                window.fetch = function(input, init){
                    var url = (typeof input === 'string') ? input : (input && input.url) || '';
                    var method = ((init && init.method) || (typeof input === 'object' && input && input.method) || 'GET').toUpperCase();
                    if ((method === 'POST' || method === 'PATCH') && /\\/snags\\/[^/]+\\/(complete|status)/.test(url)) {
                        alert(msg);
                        return Promise.reject(new Error('preview mode: submissions disabled'));
                    }
                    return origFetch.apply(this, arguments);
                };
            }
            // Neutralize any form submissions.
            document.addEventListener('submit', function(e){
                e.preventDefault(); e.stopPropagation(); alert(msg);
            }, true);
        })();
        </script>
        """
        // Anchor on the report document's single closing body tag.
        if let range = html.range(of: "</body>", options: .backwards) {
            return html.replacingCharacters(in: range, with: overlay + "</body>")
        }
        // Fallback: append (still renders; banner is position:fixed so placement is unaffected).
        return html + overlay
    }

    // MARK: - GET /m/:slug/photos.zip

    @Sendable
    func downloadPhotosZip(req: Request) async throws -> Response {
        guard let slug = req.parameters.get("slug") else {
            throw Abort(.notFound)
        }

        // Validate magic link
        let magicLink: MagicLink
        do {
            magicLink = try await TokenValidationService.validateMagicLink(
                token: slug,
                on: req.db
            )
        } catch {
            throw Abort(.notFound)
        }

        // PIN check
        if magicLink.requiresPIN {
            guard isPINVerified(req: req, magicLink: magicLink) else {
                throw Abort(.unauthorized, reason: "PIN verification required")
            }
        }

        let token = magicLink.token

        // Fetch synced report for snag metadata
        guard let syncedReport = try await SyncedReport.query(on: req.db)
            .filter(\.$magicLinkToken == token)
            .first(),
            let jsonData = (try await SnagDeletionService.visibleReportJSON(syncedReport.reportJSON, ownerId: magicLink.createdById, projectId: magicLink.projectId, on: req.db)).data(using: .utf8) else {
            throw Abort(.notFound, reason: "Report not found")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(SyncedReportJSON.self, from: jsonData)

        // Build snag metadata lookup: snagId -> (index, reference, title)
        struct SnagMeta {
            let index: Int
            let reference: String?
            let title: String
        }
        var snagMetaById: [UUID: SnagMeta] = [:]
        for (i, snag) in (report.snags ?? []).enumerated() {
            guard let id = snag.id else { continue }
            snagMetaById[id] = SnagMeta(
                index: i + 1,
                reference: snag.reference,
                title: snag.title ?? "Untitled"
            )
        }

        // Fetch synced photos: prefer snag-based lookup, fall back to token-based
        let reportSnagIds = (report.snags ?? []).compactMap { $0.id }
        let syncedPhotos: [SyncedPhoto]
        if !reportSnagIds.isEmpty {
            syncedPhotos = try await SyncedPhoto.query(on: req.db)
                .filter(\.$snagId ~~ reportSnagIds)
                .sort(\.$sortOrder)
                .all()
        } else {
            // A report with no active snags must not expose stale photo files.
            syncedPhotos = []
        }

        guard !syncedPhotos.isEmpty else {
            throw Abort(.notFound, reason: "No photos found")
        }

        // Build ZIP entries
        var entries: [ZIPBuilder.Entry] = []

        for photo in syncedPhotos {
            // Storage key: strip leading "/" from filePath
            let storageKey = photo.filePath.hasPrefix("/") ? String(photo.filePath.dropFirst()) : photo.filePath

            guard let fileData = try await StorageService.download(key: storageKey, app: req.application) else {
                // The key is deliberately not in this line. It addresses an
                // object in the public upload bucket, and a bucket that serves
                // without a signature is one where knowing the address is the
                // whole of the access — so the line would put a capability into a
                // log that is kept for seven days. It was harmless only for as
                // long as nothing could read that log, which is the thing this
                // change is undoing. The line itself is kept, not deleted: that a
                // report's ZIP shipped without one of its photographs is the one
                // fact an operator needs from here, and it is still countable per
                // request. Which file it was is a question for the database.
                req.logger.warning("ZIP: a report photo was missing from storage and was skipped")
                continue
            }

            // Determine folder name from snag metadata
            let meta = snagMetaById[photo.snagId]
            let folderRef = meta?.reference ?? "Snag_\(meta?.index ?? 0)"
            let folderTitle = meta?.title ?? "Unknown"
            let folderName = "\(folderRef)_\(folderTitle)"

            // Determine file extension from path
            let ext = (photo.filePath as NSString).pathExtension
            let fileName = "\(photo.label)_\(photo.sortOrder).\(ext.isEmpty ? "jpg" : ext)"

            let entryPath = ZIPBuilder.sanitizeFilename("\(folderName)/\(fileName)")
            entries.append(ZIPBuilder.Entry(path: entryPath, data: fileData))
        }

        guard !entries.isEmpty else {
            throw Abort(.notFound, reason: "No photo files available")
        }

        let zipData = ZIPBuilder.build(entries: entries)
        let projectName = report.resolvedProjectName ?? "Report"
        let safeProjectName = projectName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/zip")
        headers.add(name: .contentDisposition, value: "attachment; filename=\"\(safeProjectName)_Photos.zip\"")

        return Response(
            status: .ok,
            headers: headers,
            body: .init(data: zipData)
        )
    }

    // MARK: - POST /m/:slug/verify

    @Sendable
    func verifyPIN(req: Request) async throws -> Response {
        guard let slug = req.parameters.get("slug") else {
            return htmlResponse(WebReportRenderer.renderError(type: .notFound))
        }

        // Validate magic link
        let magicLink: MagicLink
        do {
            magicLink = try await TokenValidationService.validateMagicLink(
                token: slug,
                on: req.db
            )
        } catch let error as TokenValidationService.ValidationError {
            let errorType: WebReportRenderer.ErrorType
            switch error {
            case .notFound: errorType = .notFound
            case .expired: errorType = .expired
            case .revoked: errorType = .revoked
            case .locked: errorType = .locked
            }
            return htmlResponse(WebReportRenderer.renderError(type: errorType))
        }

        // Decode PIN from form body
        struct PINForm: Content {
            let pin: String
            let csrf_token: String?
        }

        let form: PINForm
        do {
            form = try req.content.decode(PINForm.self)
        } catch {
            let csrfToken = generateCSRFToken(slug: slug)
            return htmlResponse(WebReportRenderer.renderPINForm(
                slug: slug,
                csrfToken: csrfToken,
                error: "Please enter a PIN."
            ))
        }

        // Verify CSRF token
        guard let csrfToken = form.csrf_token,
              verifyCSRFToken(csrfToken, slug: slug) else {
            let newToken = generateCSRFToken(slug: slug)
            return htmlResponse(WebReportRenderer.renderPINForm(
                slug: slug,
                csrfToken: newToken,
                error: "Session expired. Please try again."
            ))
        }

        // Verify PIN
        do {
            let verified = try await PINVerificationService.verify(
                pin: form.pin,
                magicLink: magicLink,
                on: req.db
            )

            if verified {
                // Set signed cookie and redirect to report
                var response = Response(status: .seeOther)
                response.headers.replaceOrAdd(name: .location, value: "/m/\(slug)")
                setPINVerifiedCookie(on: &response, magicLink: magicLink, req: req)
                return response
            } else {
                let remaining = PINVerificationService.maxAttempts - magicLink.failedPinAttempts
                let newToken = generateCSRFToken(slug: slug)
                return htmlResponse(WebReportRenderer.renderPINForm(
                    slug: slug,
                    csrfToken: newToken,
                    error: "Invalid PIN.",
                    attemptsRemaining: remaining > 0 ? remaining : nil
                ))
            }
        } catch let error as AbortError {
            if error.status == .tooManyRequests {
                return htmlResponse(WebReportRenderer.renderError(type: .locked))
            }
            let remaining = PINVerificationService.maxAttempts - magicLink.failedPinAttempts
            let newToken = generateCSRFToken(slug: slug)
            return htmlResponse(WebReportRenderer.renderPINForm(
                slug: slug,
                csrfToken: newToken,
                error: error.reason,
                attemptsRemaining: remaining > 0 ? remaining : nil
            ))
        }
    }

    // MARK: - Cookie-based PIN Session

    private func isPINVerified(req: Request, magicLink: MagicLink) -> Bool {
        PINSessionService.isVerified(req, link: magicLink)
    }

    private func setPINVerifiedCookie(on response: inout Response, magicLink: MagicLink, req: Request) {
        PINSessionService.attach(to: &response, link: magicLink)
    }

    // MARK: - CSRF Token

    private static let csrfTTL: TimeInterval = 15 * 60 // 15 minutes

    /// Generates a signed CSRF token embedding the current timestamp.
    private func generateCSRFToken(slug: String) -> String {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let secret = Environment.get("JWT_SECRET") ?? ""
        let message = "csrf:\(timestamp):\(slug)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let sig = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        let sigString = Data(sig).base64EncodedString()
        return "\(timestamp):\(sigString)"
    }

    /// Verifies a CSRF token is valid and not expired.
    private func verifyCSRFToken(_ token: String, slug: String) -> Bool {
        let parts = token.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let timestamp = TimeInterval(parts[0]) else {
            return false
        }

        // Check TTL
        let age = Date().timeIntervalSince1970 - timestamp
        guard age >= 0 && age < Self.csrfTTL else { return false }

        // Verify signature
        let secret = Environment.get("JWT_SECRET") ?? ""
        let message = "csrf:\(parts[0]):\(slug)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let expectedSig = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        let expectedString = Data(expectedSig).base64EncodedString()
        return String(parts[1]) == expectedString
    }

    // MARK: - Debug

    /// GET /api/v1/debug/photos/:token — diagnose photo file existence (JWT-protected)
    @Sendable
    func debugPhotos(req: Request) async throws -> Response {
        guard let token = req.parameters.get("token") else {
            throw Abort(.badRequest, reason: "Token is required")
        }

        let storageBaseURL = StorageService.publicBaseURL

        let photos = try await SyncedPhoto.query(on: req.db)
            .filter(\.$magicLinkToken == token)
            .sort(\.$sortOrder)
            .all()

        let drawings = try await SyncedDrawing.query(on: req.db)
            .filter(\.$magicLinkToken == token)
            .all()

        struct FileInfo: Content {
            let id: UUID
            let snagId: UUID?
            let filePath: String
            let storageKey: String
            let existsInStorage: Bool
        }

        var photoInfos: [FileInfo] = []
        for photo in photos {
            let key = photo.filePath.hasPrefix("/") ? String(photo.filePath.dropFirst()) : photo.filePath
            let exists = try await StorageService.exists(key: key, app: req.application)
            photoInfos.append(FileInfo(
                id: photo.id!,
                snagId: photo.snagId,
                filePath: photo.filePath,
                storageKey: key,
                existsInStorage: exists
            ))
        }

        var drawingInfos: [FileInfo] = []
        for drawing in drawings {
            let key = drawing.filePath.hasPrefix("/") ? String(drawing.filePath.dropFirst()) : drawing.filePath
            let exists = try await StorageService.exists(key: key, app: req.application)
            drawingInfos.append(FileInfo(
                id: drawing.id!,
                snagId: nil,
                filePath: drawing.filePath,
                storageKey: key,
                existsInStorage: exists
            ))
        }

        struct DebugResponse: Content {
            let token: String
            let storageBackend: String
            let storageBaseURL: String
            let photoCount: Int
            let photos: [FileInfo]
            let drawingCount: Int
            let drawings: [FileInfo]
        }

        let result = DebugResponse(
            token: token,
            storageBackend: StorageService.backend == .r2 ? "r2" : "local",
            storageBaseURL: storageBaseURL,
            photoCount: photoInfos.count,
            photos: photoInfos,
            drawingCount: drawingInfos.count,
            drawings: drawingInfos
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(result)

        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: data)
        )
    }

    // MARK: - Helpers

    private func htmlResponse(_ html: String, status: HTTPResponseStatus = .ok) -> Response {
        return Response(
            status: status,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: .init(string: html)
        )
    }
}
