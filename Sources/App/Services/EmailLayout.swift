import Foundation

/// The one layout every Snaglist transactional email is rendered through.
///
/// Brand values are the manager portal's (`SnaglistPortal/src/styles.css`) and the
/// website's (`app.css`): red marker accent, ink text, stone background, raised white
/// surface, rule borders and a 6 px radius. The markup is email-safe: presentation
/// tables, inline styles only, a system font stack, no images or remote resources, a
/// 560 px maximum width, and an explicit background behind every piece of text so a
/// client that darkens messages never leaves light text on a transparent area.
///
/// Every string handed to this type is plain text. The layout escapes all of it, so
/// callers must never pre-escape (that would double-escape) and never pass markup.
enum EmailLayout {
    enum Brand {
        static let accent = "#d8321e"      // portal --marker, website --color-primary
        static let ink = "#1a1d23"         // portal --ink
        static let muted = "#59616d"       // portal --muted
        static let background = "#f7f8fa"  // portal --stone
        static let surface = "#ffffff"     // portal --raised
        static let rule = "#d9dce1"        // portal --rule
        static let success = "#1f7a4d"     // portal --moss
        static let radius = "6px"          // portal --radius
        static let fontStack = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
        static let maxWidth = 560
    }

    static let footerLines = [
        "Snaglist · usesnaglist.com · support@usesnaglist.com",
        "Snaglist is provided by Reeve Technologies Ltd, 66 Paul Street, London EC2A 4NA.",
    ]

    enum Tone {
        case neutral, success, attention
    }

    enum Inline {
        case text(String)
        case strong(String)
    }

    enum Block {
        case greeting(String)
        case paragraph([Inline])
        case summary(title: String, detail: String?)
        case note(label: String, text: String)
        case status(String, tone: Tone)
        case button(label: String, url: String)
        case small(String)
    }

    struct Message {
        var preheader: String
        var heading: String
        var blocks: [Block]
        var closing: String
    }

    struct Rendered {
        let subject: String
        let html: String
        let text: String
    }

    static func render(subject: String, _ message: Message) -> Rendered {
        Rendered(subject: subject, html: html(message), text: text(message))
    }

    /// Escapes plain text for HTML element content and for quoted attribute values.
    static func escape(_ value: String) -> String {
        value.htmlEscaped
    }

    // MARK: - HTML part

    private static let font = "font-family: \(Brand.fontStack);"

    static func html(_ message: Message) -> String {
        let body = message.blocks.map(htmlBlock).joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html lang="en-GB">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta name="x-apple-disable-message-reformatting">
        <meta name="color-scheme" content="light">
        <meta name="supported-color-schemes" content="light">
        <title>\(escape(message.heading))</title>
        </head>
        <body style="margin: 0; padding: 0; width: 100%; background-color: \(Brand.background); color: \(Brand.ink); \(font) -webkit-text-size-adjust: 100%;">
        <div style="display: none; max-height: 0; overflow: hidden; mso-hide: all; font-size: 1px; line-height: 1px; color: \(Brand.background);">\(escape(message.preheader))</div>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="\(Brand.background)" style="width: 100%; background-color: \(Brand.background);">
        <tr>
        <td align="center" bgcolor="\(Brand.background)" style="padding: 32px 16px; background-color: \(Brand.background);">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width: 100%; max-width: \(Brand.maxWidth)px;">
        <tr>
        <td align="left" bgcolor="\(Brand.background)" style="padding: 0 4px 16px 4px; background-color: \(Brand.background); \(font) font-size: 22px; line-height: 1.2; font-weight: 700; letter-spacing: -0.3px; color: \(Brand.ink);">Snagl<span style="color: \(Brand.accent);">i</span>st</td>
        </tr>
        <tr>
        <td align="left" bgcolor="\(Brand.surface)" style="padding: 32px 28px; background-color: \(Brand.surface); border: 1px solid \(Brand.rule); border-radius: \(Brand.radius); \(font) color: \(Brand.ink);">
        <h1 style="margin: 0 0 20px 0; \(font) font-size: 22px; line-height: 1.3; font-weight: 700; color: \(Brand.ink);">\(escape(message.heading))</h1>
        \(body)
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width: 100%; margin: 8px 0 20px 0;"><tr><td style="height: 1px; font-size: 1px; line-height: 1px; border-top: 1px solid \(Brand.rule);">&nbsp;</td></tr></table>
        <p style="margin: 0; \(font) font-size: 13px; line-height: 1.6; color: \(Brand.muted);">\(escape(message.closing))</p>
        </td>
        </tr>
        <tr>
        <td align="left" bgcolor="\(Brand.background)" style="padding: 20px 4px 0 4px; background-color: \(Brand.background); \(font) font-size: 12px; line-height: 1.7; color: \(Brand.muted);">
        Snaglist &middot; <a href="https://usesnaglist.com" style="color: \(Brand.muted); text-decoration: underline;">usesnaglist.com</a> &middot; <a href="mailto:support@usesnaglist.com" style="color: \(Brand.muted); text-decoration: underline;">support@usesnaglist.com</a><br>
        Snaglist is provided by Reeve Technologies Ltd, 66 Paul Street, London EC2A 4NA.
        </td>
        </tr>
        </table>
        </td>
        </tr>
        </table>
        </body>
        </html>
        """
    }

    private static func htmlBlock(_ block: Block) -> String {
        switch block {
        case .greeting(let name):
            return "<p style=\"margin: 0 0 16px 0; \(font) font-size: 16px; line-height: 1.6; color: \(Brand.ink);\">Hi \(escape(name)),</p>"
        case .paragraph(let parts):
            return "<p style=\"margin: 0 0 16px 0; \(font) font-size: 16px; line-height: 1.6; color: \(Brand.ink);\">\(parts.map(htmlInline).joined())</p>"
        case .summary(let title, let detail):
            let detailLine = detail.map {
                "<p style=\"margin: 4px 0 0 0; \(font) font-size: 14px; line-height: 1.5; color: \(Brand.muted);\">\(multiline($0))</p>"
            } ?? ""
            return card("<p style=\"margin: 0; \(font) font-size: 16px; line-height: 1.5; font-weight: 600; color: \(Brand.ink);\">\(escape(title))</p>\(detailLine)")
        case .note(let label, let text):
            return card("<p style=\"margin: 0 0 4px 0; \(font) font-size: 12px; line-height: 1.5; font-weight: 600; letter-spacing: 0.4px; text-transform: uppercase; color: \(Brand.muted);\">\(escape(label))</p><p style=\"margin: 0; \(font) font-size: 15px; line-height: 1.6; color: \(Brand.ink);\">\(multiline(text))</p>")
        case .status(let text, let tone):
            let colour: String
            switch tone {
            case .neutral: colour = Brand.ink
            case .success: colour = Brand.success
            case .attention: colour = Brand.accent
            }
            return "<p style=\"margin: 0 0 16px 0; \(font) font-size: 14px; line-height: 1.5; font-weight: 600; color: \(colour);\">\(escape(text))</p>"
        case .button(let label, let url):
            let href = escape(url)
            return """
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin: 8px 0 16px 0;"><tr><td align="center" bgcolor="\(Brand.accent)" style="background-color: \(Brand.accent); border-radius: \(Brand.radius);"><a href="\(href)" target="_blank" style="display: inline-block; padding: 13px 24px; border: 1px solid \(Brand.accent); border-radius: \(Brand.radius); background-color: \(Brand.accent); \(font) font-size: 16px; line-height: 1.2; font-weight: 600; color: #ffffff; text-decoration: none;">\(escape(label))</a></td></tr></table>
            <p style="margin: 0 0 16px 0; \(font) font-size: 13px; line-height: 1.6; color: \(Brand.muted);">If the button does not work, copy this link into your browser:<br><a href="\(href)" target="_blank" style="color: \(Brand.ink); text-decoration: underline; word-break: break-all;">\(href)</a></p>
            """
        case .small(let text):
            return "<p style=\"margin: 0 0 16px 0; \(font) font-size: 14px; line-height: 1.6; color: \(Brand.muted);\">\(escape(text))</p>"
        }
    }

    private static func htmlInline(_ part: Inline) -> String {
        switch part {
        case .text(let value):
            return escape(value)
        case .strong(let value):
            return "<strong style=\"font-weight: 600; color: \(Brand.ink);\">\(escape(value))</strong>"
        }
    }

    private static func card(_ inner: String) -> String {
        "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"width: 100%; margin: 0 0 20px 0;\"><tr><td align=\"left\" bgcolor=\"\(Brand.background)\" style=\"padding: 14px 16px; background-color: \(Brand.background); border: 1px solid \(Brand.rule); border-radius: \(Brand.radius);\">\(inner)</td></tr></table>"
    }

    /// Escapes, then keeps the author's line breaks.
    private static func multiline(_ value: String) -> String {
        escape(value)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    // MARK: - Plain-text part

    static func text(_ message: Message) -> String {
        var lines: [String] = ["Snaglist", "", message.heading, ""]
        for block in message.blocks {
            switch block {
            case .greeting(let name):
                lines += ["Hi \(name),", ""]
            case .paragraph(let parts):
                let sentence = parts.map { part -> String in
                    switch part {
                    case .text(let value), .strong(let value):
                        return value
                    }
                }.joined()
                lines += [sentence, ""]
            case .summary(let title, let detail):
                lines.append(title)
                if let detail {
                    lines.append(detail)
                }
                lines.append("")
            case .note(let label, let text):
                lines += ["\(label):", text, ""]
            case .status(let text, _):
                lines += [text, ""]
            case .button(let label, let url):
                lines += ["\(label):", url, ""]
            case .small(let text):
                lines += [text, ""]
            }
        }
        lines += ["---", message.closing, ""]
        lines += footerLines
        return lines.joined(separator: "\n") + "\n"
    }
}
