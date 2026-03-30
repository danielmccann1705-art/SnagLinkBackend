import Vapor

/// Generates self-contained HTML pages for web report viewing.
/// All CSS is embedded inline — no external dependencies.
struct WebReportRenderer {

    // MARK: - Error Pages

    enum ErrorType {
        case expired
        case revoked
        case notFound
        case notSynced
        case locked

        var title: String {
            switch self {
            case .expired: return "Link Expired"
            case .revoked: return "Link Revoked"
            case .notFound: return "Not Found"
            case .notSynced: return "Report Not Ready"
            case .locked: return "Temporarily Locked"
            }
        }

        var message: String {
            switch self {
            case .expired:
                return "This magic link has expired. Please ask the project manager to send a new one."
            case .revoked:
                return "This link has been revoked by the project manager."
            case .notFound:
                return "We couldn't find a report at this address. Please check the link and try again."
            case .notSynced:
                return "The report data hasn't been synced yet. Please ask the project manager to share the report from the Snaglist app."
            case .locked:
                return "This link is temporarily locked due to too many failed PIN attempts. Please try again later."
            }
        }

        var emoji: String {
            switch self {
            case .expired: return "&#9203;"
            case .revoked: return "&#128683;"
            case .notFound: return "&#128269;"
            case .notSynced: return "&#128230;"
            case .locked: return "&#128274;"
            }
        }
    }

    static func renderError(type: ErrorType) -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Snaglist - \(type.title.htmlEscaped)</title>
            <meta name="apple-itunes-app" content="app-clip-bundle-id=com.snaglist.app.Clip, app-id=6758858102">
            \(sharedStyles)
            <style>
                .error-container {
                    min-height: 100vh;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    padding: 24px;
                }
                .error-card {
                    text-align: center;
                    max-width: 420px;
                    background: #fff;
                    border-radius: 16px;
                    padding: 48px 32px;
                    box-shadow: 0 1px 3px rgba(0,0,0,0.1);
                }
                .error-emoji { font-size: 48px; margin-bottom: 16px; }
                .error-title { font-size: 22px; font-weight: 700; color: #1F2937; margin-bottom: 8px; }
                .error-message { color: #6B7280; font-size: 15px; line-height: 1.6; margin-bottom: 24px; }
                .error-cta {
                    display: inline-block; background: #F97316; color: #fff;
                    text-decoration: none; padding: 12px 28px; border-radius: 10px;
                    font-size: 15px; font-weight: 600;
                }
                .error-cta:hover { background: #EA580C; }
            </style>
        </head>
        <body style="background: linear-gradient(135deg, #FFF7ED 0%, #F9FAFB 100%);">
            <div class="error-container">
                <div class="error-card">
                    <div class="error-emoji">\(type.emoji)</div>
                    <div class="error-title">\(type.title.htmlEscaped)</div>
                    <p class="error-message">\(type.message.htmlEscaped)</p>
                    <a href="https://apps.apple.com/app/id6758858102" class="error-cta">Get Snaglist</a>
                </div>
            </div>
        </body>
        </html>
        """
    }

    // MARK: - PIN Form

    static func renderPINForm(slug: String, csrfToken: String, error: String? = nil, attemptsRemaining: Int? = nil) -> String {
        let errorHTML: String
        if let error = error {
            let attemptsText = attemptsRemaining.map { " (\($0) attempt\($0 == 1 ? "" : "s") remaining)" } ?? ""
            errorHTML = """
            <div class="pin-error">\(error.htmlEscaped)\(attemptsText.htmlEscaped)</div>
            """
        } else {
            errorHTML = ""
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Snaglist - Enter PIN</title>
            <meta name="apple-itunes-app" content="app-clip-bundle-id=com.snaglist.app.Clip, app-id=6758858102">
            \(sharedStyles)
            <style>
                .pin-container {
                    min-height: 100vh;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    padding: 24px;
                }
                .pin-card {
                    text-align: center;
                    max-width: 400px;
                    width: 100%;
                    background: #fff;
                    border-radius: 16px;
                    padding: 48px 32px;
                    box-shadow: 0 1px 3px rgba(0,0,0,0.1);
                }
                .pin-icon { font-size: 40px; margin-bottom: 12px; }
                .pin-title { font-size: 22px; font-weight: 700; color: #1F2937; margin-bottom: 6px; }
                .pin-subtitle { color: #6B7280; font-size: 14px; margin-bottom: 24px; }
                .pin-input {
                    width: 100%; padding: 14px 16px; font-size: 24px;
                    text-align: center; letter-spacing: 8px;
                    border: 2px solid #E5E7EB; border-radius: 12px;
                    outline: none; font-family: inherit;
                    -webkit-appearance: none; appearance: none;
                }
                .pin-input:focus { border-color: #F97316; box-shadow: 0 0 0 3px rgba(249,115,22,0.15); }
                .pin-submit {
                    width: 100%; margin-top: 16px; padding: 14px;
                    background: #F97316; color: #fff; border: none;
                    border-radius: 12px; font-size: 16px; font-weight: 600;
                    cursor: pointer; font-family: inherit;
                }
                .pin-submit:hover { background: #EA580C; }
                .pin-error {
                    background: #FEE2E2; color: #DC2626; padding: 10px 16px;
                    border-radius: 8px; font-size: 13px; margin-bottom: 16px;
                }
            </style>
        </head>
        <body style="background: linear-gradient(135deg, #FFF7ED 0%, #F9FAFB 100%);">
            <div class="pin-container">
                <div class="pin-card">
                    <div class="pin-icon">&#128274;</div>
                    <div class="pin-title">PIN Required</div>
                    <p class="pin-subtitle">Enter the PIN provided by the project manager to view this report.</p>
                    \(errorHTML)
                    <form method="POST" action="/m/\(slug.htmlEscaped)/verify">
                        <input type="hidden" name="csrf_token" value="\(csrfToken.htmlEscaped)">
                        <input
                            type="text"
                            name="pin"
                            class="pin-input"
                            inputmode="numeric"
                            pattern="[0-9]*"
                            maxlength="8"
                            autocomplete="one-time-code"
                            placeholder="&#8226;&#8226;&#8226;&#8226;"
                            required
                            autofocus
                        >
                        <button type="submit" class="pin-submit">Verify PIN</button>
                    </form>
                </div>
            </div>
        </body>
        </html>
        """
    }

    // MARK: - Full Report

    struct ReportData {
        let slug: String
        let baseURL: String
        let projectName: String
        let projectAddress: String?
        let contractorName: String
        let generatedDate: String
        let openCount: Int
        let inProgressCount: Int
        let completedCount: Int
        let snags: [SnagData]
        let token: String      // Full magic link token for API calls
        let accessLevel: String // "view", "update", or "full"
    }

    struct SnagData {
        let id: String?        // Snag UUID for API calls
        let index: Int
        let title: String
        let description: String?
        let status: String
        let priority: String
        let location: String?
        let dueDate: String?
        let assignedTo: String?
        let photos: [PhotoData]
        let floorPlanURL: String?
        let pinX: Double?
        let pinY: Double?
    }

    struct PhotoData {
        let url: String
        let thumbnailUrl: String?
        let label: String
        let snagIndex: Int
        let snagTitle: String
    }

    static func renderReport(data: ReportData) -> String {
        let totalCount = data.openCount + data.inProgressCount + data.completedCount
        let completionPercent = totalCount > 0 ? Int(Double(data.completedCount) / Double(totalCount) * 100) : 0
        let canInteract = data.accessLevel != "view"

        // Collect all photos across snags for the lightbox
        let allPhotos = data.snags.flatMap(\.photos)

        // Build snag cards, tracking global photo index for lightbox
        var snagCards = ""
        var globalPhotoIndex = 0
        for snag in data.snags {
            snagCards += renderSnagCard(snag, globalPhotoIndexStart: globalPhotoIndex, canInteract: canInteract)
            globalPhotoIndex += snag.photos.count
        }

        let ogMeta = renderOGMeta(data: data, firstPhotoURL: allPhotos.first?.url)
        let interactiveJS = canInteract ? renderInteractiveScript(data: data, totalCount: totalCount) : ""

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Snaglist Report - \(data.projectName.htmlEscaped)</title>
            \(ogMeta)
            <meta name="apple-itunes-app" content="app-clip-bundle-id=com.snaglist.app.Clip, app-id=6758858102, app-argument=https://snaglist.dev/m/\(data.slug.htmlEscaped)">
            \(sharedStyles)
            \(reportStyles)
            \(canInteract ? interactiveStyles : "")
        </head>
        <body style="background: #F9FAFB; color: #1F2937;">
            <div class="report">
                \(renderReportHeader(data: data, completionPercent: completionPercent))
                \(renderStatsBar(data: data))
                \(renderDownloadAllButton(slug: data.slug, photoCount: allPhotos.count))
                <div class="snag-list">
                    \(snagCards.isEmpty ? renderEmptyState() : snagCards)
                </div>
                \(renderFooter())
            </div>
            \(renderLightbox(allPhotos: allPhotos))
            \(interactiveJS)
        </body>
        </html>
        """
    }

    // MARK: - Report Sections

    private static func renderReportHeader(data: ReportData, completionPercent: Int) -> String {
        let addressHTML = data.projectAddress.map {
            "<p class=\"header-address\">\($0.htmlEscaped)</p>"
        } ?? ""

        return """
        <header class="report-header">
            <div class="header-brand">
                <div class="brand-mark">S</div>
                <span class="brand-name">Snaglist</span>
            </div>
            <h1 class="header-title">\(data.projectName.htmlEscaped)</h1>
            \(addressHTML)
            <div class="header-meta">
                <span class="meta-item">Contractor: <strong>\(data.contractorName.htmlEscaped)</strong></span>
                <span class="meta-sep">&middot;</span>
                <span class="meta-item">\(data.generatedDate.htmlEscaped)</span>
            </div>
            <div class="progress-bar-wrap">
                <div class="progress-bar" style="width: \(completionPercent)%"></div>
            </div>
            <p class="progress-label" id="progressLabel">\(data.completedCount) of \(data.openCount + data.inProgressCount + data.completedCount) snags completed &mdash; \(completionPercent)%</p>
        </header>
        """
    }

    private static func renderStatsBar(data: ReportData) -> String {
        return """
        <div class="stats-bar">
            <div class="stat stat-open">
                <div class="stat-value" id="statOpen">\(data.openCount)</div>
                <div class="stat-label">Open</div>
            </div>
            <div class="stat stat-progress">
                <div class="stat-value" id="statProgress">\(data.inProgressCount)</div>
                <div class="stat-label">In Progress</div>
            </div>
            <div class="stat stat-complete">
                <div class="stat-value" id="statComplete">\(data.completedCount)</div>
                <div class="stat-label">Completed</div>
            </div>
        </div>
        """
    }

    private static func renderDownloadAllButton(slug: String, photoCount: Int) -> String {
        guard photoCount > 0 else { return "" }
        return """
        <div class="download-all-wrap">
            <a href="/m/\(slug.htmlEscaped)/photos.zip" class="download-all-btn">
                <svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
                    <path d="M8 1v10M8 11L4.5 7.5M8 11l3.5-3.5M2 13h12" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
                </svg>
                Download All Photos (\(photoCount))
            </a>
        </div>
        """
    }

    private static func renderSnagCard(_ snag: SnagData, globalPhotoIndexStart: Int, canInteract: Bool = false) -> String {
        let statusColor = statusColorCSS(snag.status)
        let statusLabel = snag.status.replacingOccurrences(of: "_", with: " ").capitalized
        let priorityColor = priorityColorCSS(snag.priority)
        let priorityLabel = snag.priority.capitalized
        let snagIdAttr = snag.id.map { " data-snag-id=\"\($0.htmlEscaped)\"" } ?? ""
        let isActionable = snag.status == "open" || snag.status == "in_progress"

        var metaItems = ""
        if let location = snag.location, !location.isEmpty {
            metaItems += "<span class=\"snag-meta-item\"><span class=\"meta-icon\">&#128205;</span> \(location.htmlEscaped)</span>"
        }
        if let dueDate = snag.dueDate, !dueDate.isEmpty {
            let formatted = formatDateString(dueDate)
            metaItems += "<span class=\"snag-meta-item\"><span class=\"meta-icon\">&#128197;</span> \(formatted.htmlEscaped)</span>"
        }
        if let assignedTo = snag.assignedTo, !assignedTo.isEmpty {
            metaItems += "<span class=\"snag-meta-item\"><span class=\"meta-icon\">&#128100;</span> \(assignedTo.htmlEscaped)</span>"
        }

        let metaHTML = metaItems.isEmpty ? "" : "<div class=\"snag-meta\">\(metaItems)</div>"

        let descHTML = snag.description.map {
            "<p class=\"snag-desc\">\($0.htmlEscaped)</p>"
        } ?? ""

        let photosHTML = renderPhotoGallery(snag.photos, globalPhotoIndexStart: globalPhotoIndexStart)
        let floorPlanHTML = renderFloorPlanOverlay(url: snag.floorPlanURL, pinX: snag.pinX, pinY: snag.pinY)

        // Action buttons for interactive mode
        var actionsHTML = ""
        if canInteract, let snagId = snag.id, isActionable {
            if snag.status == "open" {
                actionsHTML = """
                <div class="snag-actions">
                    <button class="action-btn action-start" onclick="snagAction('start','\(snagId.htmlEscaped)',this)">Start Work</button>
                    <button class="action-btn action-complete" onclick="snagAction('complete','\(snagId.htmlEscaped)',this)">Mark Complete</button>
                </div>
                """
            } else if snag.status == "in_progress" {
                actionsHTML = """
                <div class="snag-actions">
                    <button class="action-btn action-complete" onclick="snagAction('complete','\(snagId.htmlEscaped)',this)">Mark Complete</button>
                </div>
                """
            }
        }

        // Completion form (hidden by default, shown when "Mark Complete" is tapped)
        var completionFormHTML = ""
        if canInteract, let snagId = snag.id, isActionable {
            completionFormHTML = """
            <div class="completion-form" id="cf-\(snagId.htmlEscaped)" style="display:none">
                <div class="cf-header">Submit Completion Evidence</div>
                <input type="text" class="cf-input" id="cf-name-\(snagId.htmlEscaped)" placeholder="Your name" required>
                <textarea class="cf-textarea" id="cf-notes-\(snagId.htmlEscaped)" placeholder="Notes (optional)" maxlength="500" rows="2"></textarea>
                <div class="cf-photo-section">
                    <label class="cf-photo-btn">
                        <input type="file" accept="image/*" capture="environment" multiple onchange="previewPhotos(this,'\(snagId.htmlEscaped)')" style="display:none">
                        &#128247; Add Photos
                    </label>
                    <div class="cf-previews" id="cf-prev-\(snagId.htmlEscaped)"></div>
                </div>
                <div class="cf-progress" id="cf-progress-\(snagId.htmlEscaped)" style="display:none">
                    <div class="cf-progress-bar"><div class="cf-progress-fill" id="cf-fill-\(snagId.htmlEscaped)"></div></div>
                    <span class="cf-progress-text" id="cf-ptext-\(snagId.htmlEscaped)">Uploading...</span>
                </div>
                <div class="cf-buttons">
                    <button class="action-btn action-complete" id="cf-submit-\(snagId.htmlEscaped)" onclick="submitCompletion('\(snagId.htmlEscaped)')">Submit</button>
                    <button class="action-btn action-cancel" onclick="hideForm('\(snagId.htmlEscaped)')">Cancel</button>
                </div>
                <div class="cf-error" id="cf-error-\(snagId.htmlEscaped)" style="display:none"></div>
            </div>
            """
        }

        return """
        <div class="snag-card"\(snagIdAttr) data-status="\(snag.status.htmlEscaped)">
            <div class="snag-header">
                <span class="snag-number">#\(snag.index)</span>
                <h3 class="snag-title">\(snag.title.htmlEscaped)</h3>
                <div class="snag-badges">
                    <span class="badge status-badge" style="background:\(statusColor)18;color:\(statusColor)">\(statusLabel.htmlEscaped)</span>
                    <span class="badge" style="background:\(priorityColor)18;color:\(priorityColor)">\(priorityLabel.htmlEscaped)</span>
                </div>
            </div>
            \(descHTML)
            \(metaHTML)
            \(photosHTML)
            \(floorPlanHTML)
            \(actionsHTML)
            \(completionFormHTML)
        </div>
        """
    }

    private static func renderPhotoGallery(_ photos: [PhotoData], globalPhotoIndexStart: Int) -> String {
        guard !photos.isEmpty else { return "" }

        var items = ""
        for (i, photo) in photos.enumerated() {
            let globalIdx = globalPhotoIndexStart + i
            let displayLabel = photo.label.capitalized
            items += """
            <div class="photo-item" onclick="openLightbox(\(globalIdx))">
                <img src="\((photo.thumbnailUrl ?? photo.url).htmlEscaped)" alt="Snag photo" loading="lazy">
                <span class="photo-label">\(displayLabel.htmlEscaped)</span>
                <a href="\(photo.url.htmlEscaped)" download class="photo-download" onclick="event.stopPropagation()" title="Download photo">
                    <svg width="14" height="14" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
                        <path d="M8 1v10M8 11L4.5 7.5M8 11l3.5-3.5M2 13h12" stroke="#fff" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
                    </svg>
                </a>
            </div>
            """
        }

        return """
        <div class="photo-gallery">
            \(items)
        </div>
        """
    }

    private static func renderFloorPlanOverlay(url: String?, pinX: Double?, pinY: Double?) -> String {
        guard let url = url, !url.isEmpty else { return "" }

        let pinHTML: String
        if let x = pinX, let y = pinY {
            let leftPct = Int(x * 100)
            let topPct = Int(y * 100)
            pinHTML = """
            <div class="floor-pin" style="left:\(leftPct)%;top:\(topPct)%">
                <div class="pin-dot"></div>
                <div class="pin-pulse"></div>
            </div>
            """
        } else {
            pinHTML = ""
        }

        return """
        <div class="floor-plan-wrap">
            <div class="floor-plan-container">
                <img src="\(url.htmlEscaped)" alt="Floor plan" loading="lazy" class="floor-plan-img">
                \(pinHTML)
            </div>
        </div>
        """
    }

    private static func renderEmptyState() -> String {
        return """
        <div class="empty-state">
            <div style="font-size:40px;margin-bottom:12px">&#128203;</div>
            <p style="color:#6B7280;font-size:15px">No snags have been added to this report yet.</p>
        </div>
        """
    }

    private static func renderFooter() -> String {
        return """
        <footer class="report-footer">
            <p>Report generated by <strong>Snaglist</strong></p>
            <a href="https://apps.apple.com/app/id6758858102" class="footer-cta">Try Snaglist Free</a>
        </footer>
        """
    }

    // MARK: - Open Graph Meta Tags

    private static func renderOGMeta(data: ReportData, firstPhotoURL: String?) -> String {
        let totalCount = data.openCount + data.inProgressCount + data.completedCount
        let ogTitle = "\(data.projectName) - Snaglist Report"
        let ogDescription = "\(totalCount) snags - \(data.completedCount) completed, \(data.openCount) open"
        let ogURL = "\(data.baseURL)/m/\(data.slug)"

        var meta = """
        <meta property="og:type" content="website">
        <meta property="og:title" content="\(ogTitle.htmlEscaped)">
        <meta property="og:description" content="\(ogDescription.htmlEscaped)">
        <meta property="og:url" content="\(ogURL.htmlEscaped)">
        <meta property="og:site_name" content="Snaglist">
        """

        if let imageURL = firstPhotoURL {
            let absoluteURL = imageURL.hasPrefix("http") ? imageURL : "\(data.baseURL)\(imageURL)"
            meta += "\n        <meta property=\"og:image\" content=\"\(absoluteURL.htmlEscaped)\">"
        }

        return meta
    }

    // MARK: - Lightbox

    private static func renderLightbox(allPhotos: [PhotoData]) -> String {
        guard !allPhotos.isEmpty else { return "" }

        // Build JS array of photo data
        var jsArray = "["
        for (i, photo) in allPhotos.enumerated() {
            if i > 0 { jsArray += "," }
            let escapedURL = photo.url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let escapedLabel = photo.label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let escapedTitle = photo.snagTitle.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            jsArray += "{'url':'\(escapedURL)','label':'\(escapedLabel)','snagIndex':\(photo.snagIndex),'snagTitle':'\(escapedTitle)'}"
        }
        jsArray += "]"

        return """
        <div class="lb-overlay" id="lbOverlay">
            <div class="lb-top-bar">
                <span class="lb-info" id="lbInfo"></span>
                <button class="lb-close" onclick="closeLightbox()" aria-label="Close">&times;</button>
            </div>
            <div class="lb-content">
                <button class="lb-arrow lb-prev" onclick="lbNav(-1)" aria-label="Previous">&#8249;</button>
                <div class="lb-img-wrap">
                    <img id="lbImg" src="" alt="Photo">
                    <div class="lb-caption">
                        <span class="lb-label" id="lbLabel"></span>
                        <span class="lb-snag" id="lbSnag"></span>
                    </div>
                </div>
                <button class="lb-arrow lb-next" onclick="lbNav(1)" aria-label="Next">&#8250;</button>
            </div>
            <div class="lb-bottom-bar">
                <span class="lb-counter" id="lbCounter"></span>
                <a class="lb-dl" id="lbDl" href="" download>
                    <svg width="14" height="14" viewBox="0 0 16 16" fill="none"><path d="M8 1v10M8 11L4.5 7.5M8 11l3.5-3.5M2 13h12" stroke="#fff" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>
                    Download
                </a>
            </div>
        </div>
        <script>
        (function(){
            var photos=\(jsArray);
            var cur=0;
            var overlay=document.getElementById('lbOverlay');
            var img=document.getElementById('lbImg');
            var info=document.getElementById('lbInfo');
            var label=document.getElementById('lbLabel');
            var snag=document.getElementById('lbSnag');
            var counter=document.getElementById('lbCounter');
            var dl=document.getElementById('lbDl');
            var tx=0,ty=0;

            window.openLightbox=function(i){
                cur=i;
                show();
                overlay.classList.add('active');
                document.body.style.overflow='hidden';
            };
            window.closeLightbox=function(){
                overlay.classList.remove('active');
                document.body.style.overflow='';
            };
            window.lbNav=function(d){
                cur=(cur+d+photos.length)%photos.length;
                show();
            };

            function show(){
                var p=photos[cur];
                img.src=p.url;
                label.textContent=p.label.charAt(0).toUpperCase()+p.label.slice(1);
                snag.textContent='Snag #'+p.snagIndex+' \\u2014 '+p.snagTitle;
                counter.textContent=(cur+1)+' / '+photos.length;
                dl.href=p.url;
            }

            document.addEventListener('keydown',function(e){
                if(!overlay.classList.contains('active'))return;
                if(e.key==='Escape')closeLightbox();
                if(e.key==='ArrowLeft')lbNav(-1);
                if(e.key==='ArrowRight')lbNav(1);
            });

            overlay.addEventListener('touchstart',function(e){tx=e.touches[0].clientX;ty=e.touches[0].clientY;},{passive:true});
            overlay.addEventListener('touchend',function(e){
                var dx=e.changedTouches[0].clientX-tx;
                var dy=e.changedTouches[0].clientY-ty;
                if(Math.abs(dx)>50&&Math.abs(dx)>Math.abs(dy)){
                    if(dx<0)lbNav(1);else lbNav(-1);
                }
            },{passive:true});

            overlay.addEventListener('click',function(e){
                if(e.target===overlay)closeLightbox();
            });
        })();
        </script>
        """
    }

    // MARK: - Helpers

    private static func statusColorCSS(_ status: String) -> String {
        switch status {
        case "open": return "#6B7280"
        case "in_progress": return "#CA8A04"
        case "resolved", "verified", "closed": return "#16A34A"
        case "rejected": return "#DC2626"
        default: return "#6B7280"
        }
    }

    private static func priorityColorCSS(_ priority: String) -> String {
        switch priority {
        case "critical": return "#DC2626"
        case "high": return "#EA580C"
        case "medium": return "#2563EB"
        case "low": return "#9CA3AF"
        default: return "#6B7280"
        }
    }

    private static func formatDateString(_ isoString: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = isoFormatter.date(from: isoString)
        if date == nil {
            isoFormatter.formatOptions = [.withInternetDateTime]
            date = isoFormatter.date(from: isoString)
        }
        guard let d = date else { return isoString }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: d)
    }

    // MARK: - Shared Styles

    private static var sharedStyles: String {
        return """
        <style>
            *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                color: #1F2937;
                background: #F9FAFB;
                -webkit-font-smoothing: antialiased;
            }
        </style>
        """
    }

    private static var reportStyles: String {
        return """
        <style>
            .report { max-width: 800px; margin: 0 auto; padding: 24px 16px 48px; }

            /* Header */
            .report-header {
                background: #fff; border-radius: 16px; padding: 32px 24px;
                box-shadow: 0 1px 3px rgba(0,0,0,0.06); margin-bottom: 20px;
            }
            .header-brand { display: flex; align-items: center; gap: 8px; margin-bottom: 16px; }
            .brand-mark {
                width: 32px; height: 32px; background: #F97316; color: #fff;
                border-radius: 8px; display: flex; align-items: center; justify-content: center;
                font-weight: 800; font-size: 18px;
            }
            .brand-name { font-size: 15px; font-weight: 700; color: #F97316; }
            .header-title { font-size: 24px; font-weight: 800; color: #111827; margin-bottom: 4px; }
            .header-address { font-size: 14px; color: #6B7280; margin-bottom: 12px; }
            .header-meta { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; font-size: 13px; color: #6B7280; margin-bottom: 16px; }
            .meta-sep { color: #D1D5DB; }
            .progress-bar-wrap {
                height: 6px; background: #E5E7EB; border-radius: 3px; overflow: hidden;
            }
            .progress-bar { height: 100%; background: #F97316; border-radius: 3px; transition: width 0.3s; }
            .progress-label { font-size: 12px; color: #9CA3AF; margin-top: 6px; }

            /* Stats */
            .stats-bar {
                display: flex; gap: 12px; margin-bottom: 20px;
            }
            .stat {
                flex: 1; text-align: center; padding: 16px 8px;
                border-radius: 12px; background: #fff;
                box-shadow: 0 1px 3px rgba(0,0,0,0.06);
            }
            .stat-value { font-size: 28px; font-weight: 800; }
            .stat-label { font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; margin-top: 2px; }
            .stat-open .stat-value { color: #DC2626; }
            .stat-open .stat-label { color: #9CA3AF; }
            .stat-progress .stat-value { color: #CA8A04; }
            .stat-progress .stat-label { color: #CA8A04; }
            .stat-complete .stat-value { color: #16A34A; }
            .stat-complete .stat-label { color: #16A34A; }

            /* Download All */
            .download-all-wrap {
                text-align: center; margin-bottom: 20px;
            }
            .download-all-btn {
                display: inline-flex; align-items: center; gap: 8px;
                background: #fff; color: #374151; text-decoration: none;
                padding: 10px 20px; border-radius: 10px; font-size: 14px; font-weight: 600;
                border: 1px solid #E5E7EB; box-shadow: 0 1px 2px rgba(0,0,0,0.04);
                transition: border-color 0.15s, box-shadow 0.15s;
            }
            .download-all-btn:hover {
                border-color: #F97316; box-shadow: 0 1px 4px rgba(249,115,22,0.15);
                color: #F97316;
            }

            /* Snag Cards */
            .snag-list { display: flex; flex-direction: column; gap: 16px; }
            .snag-card {
                background: #fff; border-radius: 14px; padding: 20px;
                box-shadow: 0 1px 3px rgba(0,0,0,0.06);
            }
            .snag-header { margin-bottom: 8px; }
            .snag-number { font-size: 12px; font-weight: 700; color: #F97316; }
            .snag-title { font-size: 17px; font-weight: 700; color: #111827; margin: 2px 0 8px; }
            .snag-badges { display: flex; flex-wrap: wrap; gap: 6px; }
            .badge {
                display: inline-block; padding: 3px 10px; border-radius: 20px;
                font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.3px;
            }
            .snag-desc { font-size: 14px; color: #4B5563; line-height: 1.6; margin-bottom: 10px; }
            .snag-meta { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 10px; }
            .snag-meta-item { display: flex; align-items: center; gap: 4px; font-size: 13px; color: #6B7280; }
            .meta-icon { font-size: 14px; }

            /* Photos — Grid Layout */
            .photo-gallery {
                display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px;
                padding: 4px 0;
            }
            .photo-item {
                position: relative; border-radius: 10px; overflow: hidden; cursor: pointer;
            }
            .photo-item img {
                width: 100%; aspect-ratio: 4/3; object-fit: cover; display: block;
                background: #F3F4F6;
            }
            .photo-label {
                position: absolute; bottom: 6px; left: 6px;
                background: rgba(0,0,0,0.6); color: #fff; font-size: 10px;
                font-weight: 600; padding: 2px 8px; border-radius: 4px;
            }
            .photo-download {
                position: absolute; top: 6px; right: 6px;
                width: 28px; height: 28px; border-radius: 6px;
                background: rgba(0,0,0,0.5); display: flex;
                align-items: center; justify-content: center;
                opacity: 0; transition: opacity 0.15s;
                text-decoration: none;
            }
            .photo-item:hover .photo-download { opacity: 1; }

            /* Floor Plan */
            .floor-plan-wrap { margin-top: 10px; }
            .floor-plan-container {
                position: relative; border-radius: 10px; overflow: hidden;
                border: 1px solid #E5E7EB;
            }
            .floor-plan-img { width: 100%; display: block; }
            .floor-pin {
                position: absolute; transform: translate(-50%, -50%);
            }
            .pin-dot {
                width: 14px; height: 14px; background: #F97316;
                border: 2px solid #fff; border-radius: 50%;
                box-shadow: 0 1px 4px rgba(0,0,0,0.3);
                position: relative; z-index: 2;
            }
            .pin-pulse {
                position: absolute; top: 50%; left: 50%;
                transform: translate(-50%, -50%);
                width: 30px; height: 30px; border-radius: 50%;
                background: rgba(249,115,22,0.25);
                animation: pulse 2s ease-out infinite;
            }
            @keyframes pulse {
                0% { transform: translate(-50%,-50%) scale(0.8); opacity: 1; }
                100% { transform: translate(-50%,-50%) scale(1.6); opacity: 0; }
            }

            /* Empty State */
            .empty-state {
                text-align: center; padding: 60px 20px;
                background: #fff; border-radius: 14px;
                box-shadow: 0 1px 3px rgba(0,0,0,0.06);
            }

            /* Footer */
            .report-footer {
                text-align: center; padding: 32px 16px 16px;
                font-size: 13px; color: #9CA3AF;
            }
            .footer-cta {
                display: inline-block; margin-top: 12px;
                color: #F97316; text-decoration: none; font-weight: 600;
                font-size: 14px;
            }
            .footer-cta:hover { text-decoration: underline; }

            /* Lightbox */
            .lb-overlay {
                display: none; position: fixed; inset: 0; z-index: 9999;
                background: rgba(0,0,0,0.92); flex-direction: column;
            }
            .lb-overlay.active { display: flex; }
            .lb-top-bar {
                display: flex; justify-content: space-between; align-items: center;
                padding: 12px 16px; flex-shrink: 0;
            }
            .lb-info { color: #ccc; font-size: 13px; }
            .lb-close {
                background: none; border: none; color: #fff; font-size: 32px;
                cursor: pointer; padding: 0 4px; line-height: 1;
            }
            .lb-content {
                flex: 1; display: flex; align-items: center; justify-content: center;
                position: relative; min-height: 0; padding: 0 8px;
            }
            .lb-arrow {
                position: absolute; top: 50%; transform: translateY(-50%);
                background: rgba(255,255,255,0.12); border: none; color: #fff;
                font-size: 36px; width: 44px; height: 44px; border-radius: 50%;
                cursor: pointer; display: flex; align-items: center; justify-content: center;
                z-index: 2; transition: background 0.15s;
            }
            .lb-arrow:hover { background: rgba(255,255,255,0.25); }
            .lb-prev { left: 12px; }
            .lb-next { right: 12px; }
            .lb-img-wrap {
                max-width: 90vw; max-height: 75vh; position: relative;
                display: flex; flex-direction: column; align-items: center;
            }
            .lb-img-wrap img {
                max-width: 100%; max-height: 70vh; object-fit: contain; border-radius: 8px;
            }
            .lb-caption {
                display: flex; gap: 10px; align-items: center; margin-top: 10px;
                flex-wrap: wrap; justify-content: center;
            }
            .lb-label {
                background: rgba(249,115,22,0.85); color: #fff; font-size: 11px;
                font-weight: 700; padding: 3px 10px; border-radius: 4px; text-transform: uppercase;
            }
            .lb-snag { color: #ccc; font-size: 13px; }
            .lb-bottom-bar {
                display: flex; justify-content: center; align-items: center; gap: 16px;
                padding: 12px 16px; flex-shrink: 0;
            }
            .lb-counter { color: #999; font-size: 13px; }
            .lb-dl {
                display: inline-flex; align-items: center; gap: 6px;
                color: #fff; text-decoration: none; font-size: 13px; font-weight: 600;
                background: rgba(255,255,255,0.12); padding: 6px 14px; border-radius: 6px;
                transition: background 0.15s;
            }
            .lb-dl:hover { background: rgba(255,255,255,0.25); }

            /* Responsive */
            @media (max-width: 480px) {
                .report { padding: 12px 10px 40px; }
                .report-header { padding: 24px 16px; }
                .header-title { font-size: 20px; }
                .stats-bar { gap: 8px; }
                .stat { padding: 12px 4px; }
                .stat-value { font-size: 22px; }
                .snag-card { padding: 16px; }
                .photo-gallery { grid-template-columns: repeat(2, 1fr); }
                .photo-download { opacity: 1; }
                .lb-arrow { width: 36px; height: 36px; font-size: 28px; }
                .lb-prev { left: 4px; }
                .lb-next { right: 4px; }
            }

            /* Print */
            @media print {
                .download-all-wrap, .photo-download, .lb-overlay, .footer-cta, .snag-actions, .completion-form { display: none !important; }
                .report { max-width: 100%; padding: 0; }
                .snag-card { break-inside: avoid; }
            }
        </style>
        """
    }

    // MARK: - Interactive Styles (only included when accessLevel != "view")

    private static var interactiveStyles: String {
        return """
        <style>
            .snag-actions { display: flex; gap: 8px; margin-top: 12px; }
            .action-btn {
                padding: 10px 20px; border: none; border-radius: 10px; font-size: 14px;
                font-weight: 600; cursor: pointer; font-family: inherit; transition: opacity 0.15s;
            }
            .action-btn:disabled { opacity: 0.5; cursor: not-allowed; }
            .action-start { background: #DBEAFE; color: #2563EB; }
            .action-start:hover:not(:disabled) { background: #BFDBFE; }
            .action-complete { background: #F97316; color: #fff; }
            .action-complete:hover:not(:disabled) { background: #EA580C; }
            .action-cancel { background: #F3F4F6; color: #6B7280; }
            .action-cancel:hover:not(:disabled) { background: #E5E7EB; }

            .completion-form {
                margin-top: 12px; padding: 16px; background: #F9FAFB;
                border: 1px solid #E5E7EB; border-radius: 12px;
            }
            .cf-header { font-size: 14px; font-weight: 700; color: #374151; margin-bottom: 12px; }
            .cf-input, .cf-textarea {
                width: 100%; padding: 10px 12px; border: 1px solid #D1D5DB; border-radius: 8px;
                font-size: 14px; font-family: inherit; margin-bottom: 8px;
                -webkit-appearance: none; appearance: none;
            }
            .cf-input:focus, .cf-textarea:focus { border-color: #F97316; outline: none; box-shadow: 0 0 0 2px rgba(249,115,22,0.15); }
            .cf-photo-section { margin-bottom: 10px; }
            .cf-photo-btn {
                display: inline-flex; align-items: center; gap: 6px; padding: 8px 16px;
                background: #fff; border: 1px solid #D1D5DB; border-radius: 8px;
                font-size: 13px; color: #374151; cursor: pointer;
            }
            .cf-photo-btn:hover { border-color: #F97316; }
            .cf-previews { display: flex; gap: 6px; flex-wrap: wrap; margin-top: 8px; }
            .cf-previews img { width: 60px; height: 60px; object-fit: cover; border-radius: 6px; }
            .cf-progress { margin-bottom: 10px; }
            .cf-progress-bar { height: 4px; background: #E5E7EB; border-radius: 2px; overflow: hidden; }
            .cf-progress-fill { height: 100%; background: #F97316; width: 0%; transition: width 0.2s; }
            .cf-progress-text { font-size: 12px; color: #6B7280; }
            .cf-buttons { display: flex; gap: 8px; }
            .cf-error { color: #DC2626; font-size: 13px; margin-top: 8px; padding: 8px 12px; background: #FEE2E2; border-radius: 6px; }

            .snag-card.completed { opacity: 0.7; }
            .snag-success { margin-top: 10px; padding: 10px 14px; background: #DCFCE7; color: #166534; border-radius: 8px; font-size: 13px; font-weight: 600; }
        </style>
        """
    }

    // MARK: - Interactive JavaScript

    private static func renderInteractiveScript(data: ReportData, totalCount: Int) -> String {
        let escapedToken = data.token
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "</", with: "<\\/")  // Prevent </script> injection
        let escapedBaseURL = data.baseURL
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "</", with: "<\\/")

        return """
        <script>
        (function(){
            var TOKEN='\(escapedToken)';
            var BASE='\(escapedBaseURL)';

            // --- Status update (Start Work) ---
            window.snagAction=function(action,snagId,btn){
                if(action==='complete'){
                    showForm(snagId);
                    return;
                }
                // "start" action
                btn.disabled=true;
                btn.textContent='Starting...';
                fetch(BASE+'/api/v1/magic-links/'+TOKEN+'/snags/'+snagId+'/status',{
                    method:'PATCH',
                    headers:{'Content-Type':'application/json'},
                    body:JSON.stringify({status:'in_progress'})
                }).then(function(r){return r.json()}).then(function(d){
                    if(d.success){
                        updateCardStatus(snagId,'in_progress');
                        updateStats();
                    } else {
                        btn.disabled=false;
                        btn.textContent='Start Work';
                        showError(snagId,d.reason||d.message||'Failed to update');
                    }
                }).catch(function(){
                    btn.disabled=false;
                    btn.textContent='Start Work';
                    showError(snagId,'Network error. Please try again.');
                });
            };

            // --- Show/hide completion form ---
            function showForm(snagId){
                var el=document.getElementById('cf-'+snagId);
                if(el) el.style.display='block';
                var card=el?el.closest('.snag-card'):null;
                var actions=card?card.querySelector('.snag-actions'):null;
                if(actions) actions.style.display='none';
            }
            window.hideForm=function(snagId){
                var el=document.getElementById('cf-'+snagId);
                if(el) el.style.display='none';
                var card=el?el.closest('.snag-card'):null;
                var actions=card?card.querySelector('.snag-actions'):null;
                if(actions) actions.style.display='flex';
                hideError(snagId);
            };

            // --- Photo preview ---
            window.previewPhotos=function(input,snagId){
                var container=document.getElementById('cf-prev-'+snagId);
                container.innerHTML='';
                Array.from(input.files).forEach(function(f){
                    var img=document.createElement('img');
                    img.src=URL.createObjectURL(f);
                    container.appendChild(img);
                });
            };

            // --- Client-side image compression ---
            // Handles JPEG/PNG via canvas. HEIC (unsupported in non-Safari browsers) falls back to raw upload.
            function compressImage(file,maxBytes){
                return new Promise(function(resolve){
                    // If file is already under limit, skip compression
                    if(file.size<=maxBytes){resolve(file);return;}
                    var reader=new FileReader();
                    reader.onload=function(e){
                        var img=new Image();
                        img.onload=function(){
                            var canvas=document.createElement('canvas');
                            var w=img.width,h=img.height,max=2048;
                            if(w>max||h>max){var r=Math.min(max/w,max/h);w=Math.round(w*r);h=Math.round(h*r);}
                            canvas.width=w;canvas.height=h;
                            canvas.getContext('2d').drawImage(img,0,0,w,h);
                            var q=0.85;
                            (function tryQ(){
                                canvas.toBlob(function(b){
                                    if(!b){resolve(file);return;} // toBlob failed, send original
                                    if(b.size<=maxBytes||q<=0.3){resolve(b);}
                                    else{q-=0.1;tryQ();}
                                },'image/jpeg',q);
                            })();
                        };
                        // HEIC and unsupported formats: onerror fires, upload original
                        img.onerror=function(){resolve(file);};
                        img.src=e.target.result;
                    };
                    reader.onerror=function(){resolve(file);};
                    reader.readAsDataURL(file);
                });
            }

            // --- Upload with retry ---
            function uploadPhoto(blob,snagId,idx,total){
                var maxRetries=3,delays=[1000,2000,4000],attempt=0;
                return new Promise(function(resolve,reject){
                    function tryUp(){
                        attempt++;
                        var fd=new FormData();
                        fd.append('file',blob,'photo.jpg');
                        var xhr=new XMLHttpRequest();
                        xhr.open('POST',BASE+'/api/v1/uploads/photo?token='+TOKEN);
                        xhr.upload.onprogress=function(e){
                            if(e.lengthComputable){
                                var pct=Math.round(((idx/total)+(e.loaded/e.total/total))*100);
                                var fill=document.getElementById('cf-fill-'+snagId);
                                var txt=document.getElementById('cf-ptext-'+snagId);
                                if(fill)fill.style.width=pct+'%';
                                if(txt)txt.textContent='Uploading photo '+(idx+1)+' of '+total+'...';
                            }
                        };
                        xhr.onload=function(){
                            if(xhr.status>=200&&xhr.status<300){
                                try{resolve(JSON.parse(xhr.responseText).url);}
                                catch(e){resolve('');}
                            } else if(attempt<maxRetries){
                                setTimeout(tryUp,delays[attempt-1]);
                            } else {
                                reject(new Error('Upload failed after '+maxRetries+' attempts'));
                            }
                        };
                        xhr.onerror=function(){
                            if(attempt<maxRetries){setTimeout(tryUp,delays[attempt-1]);}
                            else{reject(new Error('Network error'));}
                        };
                        xhr.send(fd);
                    }
                    tryUp();
                });
            }

            // --- Submit completion ---
            window.submitCompletion=async function(snagId){
                var name=document.getElementById('cf-name-'+snagId).value.trim();
                if(!name){showError(snagId,'Please enter your name.');return;}
                var notes=document.getElementById('cf-notes-'+snagId).value.trim();
                var submitBtn=document.getElementById('cf-submit-'+snagId);
                submitBtn.disabled=true;
                submitBtn.textContent='Submitting...';
                hideError(snagId);

                // Upload photos first
                var photoUrls=[];
                var fileInput=document.querySelector('#cf-'+snagId+' input[type=file]');
                if(fileInput&&fileInput.files.length>0){
                    var prog=document.getElementById('cf-progress-'+snagId);
                    if(prog)prog.style.display='block';
                    try{
                        var files=Array.from(fileInput.files);
                        for(var i=0;i<files.length;i++){
                            var compressed=await compressImage(files[i],2*1024*1024);
                            var url=await uploadPhoto(compressed,snagId,i,files.length);
                            if(url)photoUrls.push(url);
                        }
                    }catch(err){
                        submitBtn.disabled=false;
                        submitBtn.textContent='Submit';
                        showError(snagId,'Photo upload failed: '+err.message);
                        return;
                    }
                }

                // Submit completion
                try{
                    var resp=await fetch(BASE+'/api/v1/magic-links/'+TOKEN+'/snags/'+snagId+'/complete',{
                        method:'POST',
                        headers:{'Content-Type':'application/json'},
                        body:JSON.stringify({
                            contractorName:name,
                            notes:notes||null,
                            photoUrls:photoUrls.length>0?photoUrls:null
                        })
                    });
                    var result=await resp.json();
                    if(result.success||resp.ok){
                        updateCardStatus(snagId,'completed');
                        hideForm(snagId);
                        updateStats();
                        // Show success message
                        var card=document.querySelector('[data-snag-id="'+snagId+'"]');
                        if(card){
                            var msg=document.createElement('div');
                            msg.className='snag-success';
                            msg.textContent='\\u2705 Submitted for review';
                            card.appendChild(msg);
                        }
                        checkAllComplete();
                    } else {
                        submitBtn.disabled=false;
                        submitBtn.textContent='Submit';
                        showError(snagId,result.reason||result.message||'Submission failed');
                    }
                }catch(err){
                    submitBtn.disabled=false;
                    submitBtn.textContent='Submit';
                    showError(snagId,'Network error. Please try again.');
                }
            };

            // --- DOM helpers ---
            function updateCardStatus(snagId,newStatus){
                var card=document.querySelector('[data-snag-id="'+snagId+'"]');
                if(!card)return;
                card.setAttribute('data-status',newStatus);
                // Update status badge
                var badge=card.querySelector('.status-badge');
                if(badge){
                    var colors={open:'#DC2626',in_progress:'#CA8A04',completed:'#16A34A',closed:'#16A34A',resolved:'#16A34A'};
                    var labels={open:'Open',in_progress:'In Progress',completed:'Completed',closed:'Closed',resolved:'Resolved'};
                    var c=colors[newStatus]||'#6B7280';
                    badge.style.background=c+'18';
                    badge.style.color=c;
                    badge.textContent=labels[newStatus]||newStatus.replace(/_/g,' ');
                }
                // Update action buttons
                var actions=card.querySelector('.snag-actions');
                if(newStatus==='in_progress'&&actions){
                    var b=document.createElement('button');
                    b.className='action-btn action-complete';
                    b.textContent='Mark Complete';
                    b.onclick=function(){snagAction('complete',snagId,b);};
                    actions.innerHTML='';
                    actions.appendChild(b);
                } else if(newStatus==='completed'||newStatus==='closed'){
                    if(actions)actions.style.display='none';
                    card.classList.add('completed');
                }
            }

            function updateStats(){
                var cards=document.querySelectorAll('.snag-card');
                var o=0,p=0,c=0;
                cards.forEach(function(card){
                    var s=card.getAttribute('data-status');
                    if(s==='open')o++;
                    else if(s==='in_progress')p++;
                    else c++;
                });
                var total=cards.length;
                var pct=total>0?Math.round(c/total*100):0;
                var bar=document.querySelector('.progress-bar');
                if(bar)bar.style.width=pct+'%';
                var label=document.getElementById('progressLabel');
                if(label)label.textContent=c+' of '+total+' snags completed \\u2014 '+pct+'%';
                var so=document.getElementById('statOpen');if(so)so.textContent=o;
                var sp=document.getElementById('statProgress');if(sp)sp.textContent=p;
                var sc=document.getElementById('statComplete');if(sc)sc.textContent=c;
            }

            function checkAllComplete(){
                var cards=document.querySelectorAll('.snag-card');
                var allDone=true;
                cards.forEach(function(card){
                    var s=card.getAttribute('data-status');
                    if(s==='open'||s==='in_progress')allDone=false;
                });
                if(allDone&&cards.length>0){
                    showCelebration(cards.length);
                }
            }

            function showCelebration(count){
                if(document.getElementById('snaglist-celebration'))return; // prevent duplicate
                var overlay=document.createElement('div');
                overlay.id='snaglist-celebration';
                overlay.style.cssText='position:fixed;inset:0;z-index:10001;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;padding:24px';
                var card=document.createElement('div');
                card.style.cssText='background:#fff;border-radius:20px;padding:40px 32px;text-align:center;max-width:400px;width:100%';
                card.innerHTML='<div style="font-size:48px;margin-bottom:12px">&#127881;</div>'
                    +'<h2 style="font-size:22px;font-weight:800;color:#111827;margin-bottom:8px">All snags completed!</h2>'
                    +'<p style="color:#6B7280;font-size:15px;margin-bottom:20px">'+count+' snags submitted for review</p>'
                    +'<a href="https://apps.apple.com/app/id6758858102?ct=magic_link_complete" style="display:inline-block;background:#F97316;color:#fff;text-decoration:none;padding:14px 28px;border-radius:12px;font-size:15px;font-weight:600;margin-bottom:12px">Get Snaglist</a><br>';
                var dismissBtn=document.createElement('button');
                dismissBtn.textContent='Dismiss';
                dismissBtn.style.cssText='background:none;border:none;color:#9CA3AF;font-size:14px;cursor:pointer;padding:8px;font-family:inherit';
                dismissBtn.onclick=function(){overlay.remove();};
                card.appendChild(dismissBtn);
                overlay.appendChild(card);
                overlay.addEventListener('click',function(e){if(e.target===overlay)overlay.remove();});
                document.body.appendChild(overlay);
            }

            function showError(snagId,msg){
                var el=document.getElementById('cf-error-'+snagId);
                if(el){el.textContent=msg;el.style.display='block';}
            }
            function hideError(snagId){
                var el=document.getElementById('cf-error-'+snagId);
                if(el)el.style.display='none';
            }
        })();
        </script>
        """
    }
}
