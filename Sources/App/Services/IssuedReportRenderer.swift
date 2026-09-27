import Foundation

/// Print-ready HTML for an issued report (contract v1 download). Stage 5 order: a
/// left-aligned cover with a key-value block, a four-count band, then the schedule.
/// Self-contained: inline styles, no scripts, no images, no remote resources, so it
/// is served under `default-src 'none'`. Every interpolated value is escaped.
/// People are named from `people`, resolved when the document is downloaded.
enum IssuedReportRenderer {
    static let contentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    static func dateTime(_ date: Date, timezone: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: timezone) ?? TimeZone(identifier: "UTC")!
        formatter.dateFormat = "d MMM yyyy, HH:mm zzz"
        return formatter.string(from: date)
    }
    static func day(_ calendarDate: String?) -> String {
        guard let calendarDate else { return "—" }
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone(identifier: "UTC"); parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: calendarDate) else { return calendarDate }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_GB"); formatter.timeZone = TimeZone(identifier: "UTC"); formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
    static func scopeDescription(_ scope: ReportScope) -> String {
        var parts: [String] = []
        if scope.archived == true { parts.append("archived snags") }
        if let status = scope.status { parts.append("status: " + IssuedReportService.statusLabel(status: status, legacy: false, acceptance: nil).lowercased()) }
        if let priority = scope.priority { parts.append("priority: " + priority) }
        if scope.contractorId == "unassigned" { parts.append("unassigned") } else if scope.contractorId != nil { parts.append("one contractor") }
        if let due = scope.due {
            parts.append(["overdue": "overdue (contractor owes work)", "today": "due today", "next7": "due in the next 7 days", "none": "no due date"][due] ?? due)
        }
        if let location = scope.location { parts.append("location contains “" + location + "”") }
        if let q = scope.q { parts.append("search “" + q + "”") }
        return parts.isEmpty ? "All current snags" : parts.joined(separator: " · ")
    }

    static func html(report: IssuedReportResponse, snapshot: ReportSnapshot, people: [ReportPerson]) -> String {
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.userId, $0.name ?? "Unnamed member") })
        let tz = snapshot.project.timezone
        func e(_ value: String) -> String { value.htmlEscaped }
        var rows = ""
        for item in snapshot.items {
            let who = item.contractor.map { c in e(c.companyName) + (c.contactName.map { "<br><span class=\"muted\">" + e($0) + "</span>" } ?? "") } ?? "<span class=\"muted\">Unassigned</span>"
            var status = e(item.statusLabel)
            if let acceptance = item.acceptance {
                status += "<br><span class=\"muted\">" + e(names[acceptance.reviewerUserId] ?? "Former member") + " · " + e(dateTime(acceptance.decidedAt, timezone: tz)) + "</span>"
            }
            let due = item.dueOn == nil ? "<span class=\"muted\">—</span>" : e(day(item.dueOn)) + (item.overdue ? "<br><span class=\"late\">Overdue</span>" : "")
            let photos = item.evidence.captureAssetIds.count + item.evidence.completionAssetIds.count
            let evidence = photos == 0 ? "" : "<br><span class=\"muted\">\(item.evidence.captureAssetIds.count) photo\(item.evidence.captureAssetIds.count == 1 ? "" : "s") · \(item.evidence.completionAssetIds.count) evidence</span>"
            rows += """
            <tr\(item.legacyUnverified ? " class=\"legacy\"" : "")><td class="ref">\(e(item.reference))</td>
            <td><strong>\(e(item.title))</strong>\(item.location.map { "<br><span class=\"muted\">" + e($0) + "</span>" } ?? "")\(item.description.map { "<br>" + e($0) } ?? "")\(evidence)</td>
            <td>\(who)</td><td>\(due)</td><td>\(e(item.priority.capitalized))</td><td>\(status)</td></tr>

            """
        }
        if snapshot.items.isEmpty { rows = "<tr><td colspan=\"6\" class=\"muted\">No snags matched this report's scope.</td></tr>" }
        let issuer = report.issuedBy.name ?? "Unnamed member"
        let s = snapshot.summary
        return """
        <!doctype html>
        <html lang="en-GB"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="robots" content="noindex,nofollow"><title>\(e(report.reference)) · \(e(snapshot.title))</title>
        <style>
        :root{--marker:#d8321e;--ink:#1a1d23;--stone:#f7f8fa;--muted:#59616d;--rule:#d9dce1}
        *{box-sizing:border-box}body{margin:0;background:#fff;color:var(--ink);font:14px/1.45 "IBM Plex Sans",-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif}
        main{max-width:1040px;margin:0 auto;padding:32px 24px}
        .brand{font-weight:700;font-size:18px}.brand span{color:var(--marker)}
        h1{font-size:26px;margin:20px 0 4px}.muted{color:var(--muted)}.late{color:var(--marker);font-weight:600}
        dl{display:grid;grid-template-columns:max-content 1fr;gap:4px 16px;margin:16px 0 24px}dt{color:var(--muted)}dd{margin:0}
        .band{display:grid;grid-template-columns:repeat(4,1fr);border:1px solid var(--rule);border-radius:6px;margin:0 0 8px}
        .band div{padding:12px 16px;border-left:1px solid var(--rule)}.band div:first-child{border-left:0}
        .band b{display:block;font-size:24px}.note{font-size:12px;margin:0 0 24px}
        table{width:100%;border-collapse:collapse}th,td{text-align:left;vertical-align:top;padding:8px;border-bottom:1px solid var(--rule)}
        th{font-size:12px;color:var(--muted);font-weight:600;background:var(--stone)}td.ref{font-family:"IBM Plex Mono",ui-monospace,Menlo,monospace;white-space:nowrap}
        tr.legacy td{background:#fbfbfc}footer{margin-top:24px;font-size:12px;color:var(--muted)}
        @media print{main{padding:0}thead{display:table-header-group}tr{break-inside:avoid}}
        </style></head><body><main>
        <div class="brand">Snag<span>list</span></div>
        <h1>\(e(snapshot.title))</h1>
        <div class="muted">\(e(report.reference)) · issued report</div>
        <dl>
        <dt>Project</dt><dd>\(e(snapshot.project.name))\(snapshot.project.reference.map { " (" + e($0) + ")" } ?? "")</dd>
        \(snapshot.project.address.map { "<dt>Address</dt><dd>" + e($0) + "</dd>" } ?? "")
        <dt>Issued</dt><dd>\(e(dateTime(report.issuedAt, timezone: tz))) by \(e(issuer))</dd>
        <dt>Status as of</dt><dd>\(e(day(snapshot.asOfDate))) (\(e(tz)))</dd>
        <dt>Scope</dt><dd>\(e(scopeDescription(snapshot.scope)))</dd>
        <dt>Snags</dt><dd>\(s.total)</dd>
        </dl>
        <div class="band"><div><b>\(s.open)</b>Open</div><div><b>\(s.overdue)</b>Overdue</div><div><b>\(s.awaitingReview)</b>Awaiting review</div><div><b>\(s.closed)</b>Closed</div></div>
        <p class="note muted">Open and overdue count work the contractor still owes. Awaiting review is waiting for the manager's decision.\(s.legacyUnverified > 0 ? " \(s.legacyUnverified) imported item\(s.legacyUnverified == 1 ? "" : "s") carry an unverified legacy status and are not counted above." : "")</p>
        <table><thead><tr><th>Ref</th><th>Snag</th><th>Contractor</th><th>Due</th><th>Priority</th><th>Status</th></tr></thead>
        <tbody>
        \(rows)</tbody></table>
        <footer>Record fingerprint (SHA-256): \(e(report.snapshotSha256)). Photos are held in Snaglist and are not embedded in this document. Snaglist · usesnaglist.com</footer>
        </main></body></html>
        """
    }

    /// A download file name made only of safe characters.
    static func filename(project: ReportSnapshot.ProjectInfo, reference: String) -> String {
        let source = (project.reference?.isEmpty == false ? project.reference! : project.name)
        let safe = source.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
        let collapsed = String(safe).split(separator: "-").joined(separator: "-").prefix(40)
        return (collapsed.isEmpty ? "Snaglist" : String(collapsed)) + "-" + reference + ".html"
    }
}
