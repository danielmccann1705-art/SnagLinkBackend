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

    static func renderPINForm(slug: String, error: String? = nil, attemptsRemaining: Int? = nil) -> String {
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
        let projectName: String
        let projectAddress: String?
        let contractorName: String
        let generatedDate: String
        let openCount: Int
        let inProgressCount: Int
        let completedCount: Int
        let snags: [SnagData]
    }

    struct SnagData {
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
        let isBefore: Bool
    }

    static func renderReport(data: ReportData) -> String {
        let totalCount = data.openCount + data.inProgressCount + data.completedCount
        let completionPercent = totalCount > 0 ? Int(Double(data.completedCount) / Double(totalCount) * 100) : 0

        var snagCards = ""
        for snag in data.snags {
            snagCards += renderSnagCard(snag)
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Snaglist Report - \(data.projectName.htmlEscaped)</title>
            <meta name="apple-itunes-app" content="app-clip-bundle-id=com.snaglist.app.Clip, app-id=6758858102">
            \(sharedStyles)
            \(reportStyles)
        </head>
        <body>
            <div class="report">
                \(renderReportHeader(data: data, completionPercent: completionPercent))
                \(renderStatsBar(data: data))
                <div class="snag-list">
                    \(snagCards.isEmpty ? renderEmptyState() : snagCards)
                </div>
                \(renderFooter())
            </div>
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
            <p class="progress-label">\(completionPercent)% complete</p>
        </header>
        """
    }

    private static func renderStatsBar(data: ReportData) -> String {
        return """
        <div class="stats-bar">
            <div class="stat stat-open">
                <div class="stat-value">\(data.openCount)</div>
                <div class="stat-label">Open</div>
            </div>
            <div class="stat stat-progress">
                <div class="stat-value">\(data.inProgressCount)</div>
                <div class="stat-label">In Progress</div>
            </div>
            <div class="stat stat-complete">
                <div class="stat-value">\(data.completedCount)</div>
                <div class="stat-label">Completed</div>
            </div>
        </div>
        """
    }

    private static func renderSnagCard(_ snag: SnagData) -> String {
        let statusColor = statusColorCSS(snag.status)
        let statusLabel = snag.status.replacingOccurrences(of: "_", with: " ").capitalized
        let priorityColor = priorityColorCSS(snag.priority)
        let priorityLabel = snag.priority.capitalized

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

        let photosHTML = renderPhotoGallery(snag.photos)
        let floorPlanHTML = renderFloorPlanOverlay(url: snag.floorPlanURL, pinX: snag.pinX, pinY: snag.pinY)

        return """
        <div class="snag-card">
            <div class="snag-header">
                <span class="snag-number">#\(snag.index)</span>
                <h3 class="snag-title">\(snag.title.htmlEscaped)</h3>
                <div class="snag-badges">
                    <span class="badge" style="background:\(statusColor)18;color:\(statusColor)">\(statusLabel.htmlEscaped)</span>
                    <span class="badge" style="background:\(priorityColor)18;color:\(priorityColor)">\(priorityLabel.htmlEscaped)</span>
                </div>
            </div>
            \(descHTML)
            \(metaHTML)
            \(photosHTML)
            \(floorPlanHTML)
        </div>
        """
    }

    private static func renderPhotoGallery(_ photos: [PhotoData]) -> String {
        guard !photos.isEmpty else { return "" }

        var items = ""
        for photo in photos {
            let label = photo.isBefore ? "Before" : "After"
            items += """
            <div class="photo-item">
                <img src="\(photo.url.htmlEscaped)" alt="Snag photo" loading="lazy">
                <span class="photo-label">\(label)</span>
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
            .stat-open .stat-value { color: #6B7280; }
            .stat-open .stat-label { color: #9CA3AF; }
            .stat-progress .stat-value { color: #CA8A04; }
            .stat-progress .stat-label { color: #CA8A04; }
            .stat-complete .stat-value { color: #16A34A; }
            .stat-complete .stat-label { color: #16A34A; }

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

            /* Photos */
            .photo-gallery {
                display: flex; gap: 8px; overflow-x: auto; padding: 4px 0;
                -webkit-overflow-scrolling: touch; scroll-snap-type: x mandatory;
            }
            .photo-item {
                flex: 0 0 auto; width: 160px; position: relative;
                border-radius: 10px; overflow: hidden; scroll-snap-align: start;
            }
            .photo-item img {
                width: 100%; height: 120px; object-fit: cover; display: block;
                background: #F3F4F6;
            }
            .photo-label {
                position: absolute; bottom: 6px; left: 6px;
                background: rgba(0,0,0,0.6); color: #fff; font-size: 10px;
                font-weight: 600; padding: 2px 8px; border-radius: 4px;
            }

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

            /* Responsive */
            @media (max-width: 480px) {
                .report { padding: 12px 10px 40px; }
                .report-header { padding: 24px 16px; }
                .header-title { font-size: 20px; }
                .stats-bar { gap: 8px; }
                .stat { padding: 12px 4px; }
                .stat-value { font-size: 22px; }
                .snag-card { padding: 16px; }
                .photo-item { width: 140px; }
                .photo-item img { height: 100px; }
            }
        </style>
        """
    }
}
