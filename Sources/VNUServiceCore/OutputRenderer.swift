import Foundation
import VNUCore

public struct RenderedOutput: Sendable {
    public var contentType: String
    public var body: Data

    public init(contentType: String, body: Data) {
        self.contentType = contentType
        self.body = body
    }
}

public enum OutputRenderer {
    public static func render(result: ValidationResult, format: OutputFormat, callback: String? = nil, asciiQuotes: Bool = false) -> RenderedOutput {
        switch format {
        case .json:
            return renderJSON(result: result, callback: callback)
        case .xml:
            return RenderedOutput(contentType: "application/xml; charset=utf-8", body: Data(renderXML(result: result).utf8))
        case .gnu:
            return RenderedOutput(contentType: "text/plain; charset=utf-8", body: Data(renderGNU(result: result, asciiQuotes: asciiQuotes).utf8))
        case .text:
            return RenderedOutput(contentType: "text/plain; charset=utf-8", body: Data(renderText(result: result).utf8))
        case .xhtml:
            return RenderedOutput(contentType: "application/xhtml+xml; charset=utf-8", body: Data(renderHTML(result: result, xhtml: true).utf8))
        case .html:
            return RenderedOutput(contentType: "text/html; charset=utf-8", body: Data(renderHTML(result: result, xhtml: false).utf8))
        }
    }

    public static func renderJSON(result: ValidationResult, callback: String?) -> RenderedOutput {
        let data = ValidationJSON.encode(result)
        if let callback, isValidJavaScriptCallback(callback), let json = String(data: data, encoding: .utf8) {
            return RenderedOutput(contentType: "application/javascript; charset=utf-8", body: Data("\(callback)(\(json));".utf8))
        }
        return RenderedOutput(contentType: "application/json; charset=utf-8", body: data)
    }

    public static func renderXML(result: ValidationResult) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        xml += "<messages>\n"
        for message in result.messages {
            let element = xmlElementName(for: message)
            xml += "  <\(element)"
            if let line = message.lastLine { xml += #" lastLine="\#(line)""# }
            if let column = message.lastColumn { xml += #" lastColumn="\#(column)""# }
            if let subType = message.subType { xml += #" subtype="\#(escapeXML(subType))""# }
            xml += ">\n"
            xml += "    <message>\(escapeXML(message.message))</message>\n"
            if let extract = message.extract {
                xml += "    <extract>\(escapeXML(extract))</extract>\n"
            }
            xml += "  </\(element)>\n"
        }
        xml += "</messages>\n"
        return xml
    }

    public static func renderGNU(result: ValidationResult, asciiQuotes: Bool) -> String {
        result.messages.map { message in
            let severity = gnuSeverity(for: message)
            let text = asciiQuotes ? asciiQuote(message.message) : message.message
            if let line = message.lastLine, let column = message.lastColumn {
                return "\(result.url ?? "stdin"):\(line).\(column): \(severity): \(text)"
            }
            return "\(result.url ?? "stdin"): \(severity): \(text)"
        }.joined(separator: "\n") + (result.messages.isEmpty ? "" : "\n")
    }

    public static func renderText(result: ValidationResult) -> String {
        if result.messages.isEmpty {
            return "The document validates.\n"
        }
        return result.messages.map { message in
            let prefix: String
            if message.type == "info", message.subType == "warning" {
                prefix = "Warning"
            } else if message.type == "info" {
                prefix = "Info"
            } else if message.type == "non-document-error" {
                prefix = "Non-document error"
            } else {
                prefix = "Error"
            }
            if let line = message.lastLine, let column = message.lastColumn {
                return "\(prefix): \(message.message) From line \(line), column \(column)."
            }
            return "\(prefix): \(message.message)"
        }.joined(separator: "\n") + "\n"
    }

    public static func renderHTML(result: ValidationResult, xhtml: Bool) -> String {
        let failed = result.messages.contains { $0.type == "error" || $0.type == "non-document-error" }
        let status = failed ? "failure" : "success"
        var html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Nu Html Checker</title>
        <style>\(UIAssets.css)</style>
        </head>
        <body>
        \(UIAssets.form)
        <section id="results">
        <p class="\(status)">\(failed ? "There were errors." : "The document validates.")</p>
        """
        if let url = result.url {
            html += #"<p class="checked-url">Checked <code>\#(escapeHTML(url))</code></p>"#
        }
        if !result.messages.isEmpty {
            html += "<ol>\n"
            for (index, message) in result.messages.enumerated() {
                let cssClass = htmlClass(for: message)
                html += #"<li id="msg\#(index)" class="\#(cssClass)"><p>"#
                html += escapeHTML(message.message)
                if let line = message.lastLine, let column = message.lastColumn {
                    html += " <span class=\"location\">From line \(line), column \(column).</span>"
                }
                html += "</p></li>\n"
            }
            html += "</ol>\n"
            html += filtersHTML(for: result.messages)
        }
        html += """
        </section>
        <script>\(UIAssets.javascript)</script>
        </body>
        </html>
        """
        if xhtml {
            html = html.replacingOccurrences(of: "<meta charset=\"utf-8\">", with: "<meta charset=\"utf-8\" />")
        }
        return html
    }

    public static func formPage() -> RenderedOutput {
        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Nu Html Checker</title>
        <style>\(UIAssets.css)</style>
        </head>
        <body>
        \(UIAssets.form)
        <section id="results"></section>
        <script>\(UIAssets.javascript)</script>
        </body>
        </html>
        """
        return RenderedOutput(contentType: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    private static func filtersHTML(for messages: [ValidationMessage]) -> String {
        let grouped = Dictionary(grouping: messages.enumerated()) { _, message in
            htmlClass(for: message)
        }
        var html = #"<aside id="filters" class="unexpanded"><button type="button">Message Filtering</button>"#
        for key in ["error", "warning", "info", "non-document-error"] {
            guard let entries = grouped[key], !entries.isEmpty else { continue }
            html += "<fieldset hidden><legend>\(legend(for: key)) (\(entries.count))</legend>"
            let unique = Dictionary(grouping: entries) { _, message in message.message }
            for (messageText, messageEntries) in unique.sorted(by: { $0.key < $1.key }) {
                let ids = messageEntries.map { "msg\($0.offset)" }.joined(separator: " ")
                html += #"<label><input type="checkbox" checked data-targets="\#(ids)"> \#(escapeHTML(messageText))</label>"#
            }
            html += "</fieldset>"
        }
        html += #"<p class="filtercount" hidden></p></aside>"#
        return html
    }

    private static func legend(for key: String) -> String {
        switch key {
        case "error": return "Errors"
        case "warning": return "Warnings"
        case "non-document-error": return "Non-document errors"
        default: return "Info messages"
        }
    }

    private static func htmlClass(for message: ValidationMessage) -> String {
        if message.type == "info", message.subType == "warning" { return "warning" }
        return message.type
    }

    private static func xmlElementName(for message: ValidationMessage) -> String {
        if message.type == "info", message.subType == "warning" { return "warning" }
        if message.type == "non-document-error" { return "non-document-error" }
        return message.type
    }

    private static func gnuSeverity(for message: ValidationMessage) -> String {
        if message.type == "info", message.subType == "warning" { return "warning" }
        if message.type == "info" { return "info" }
        return "error"
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeXML(_ text: String) -> String {
        escapeHTML(text).replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func asciiQuote(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{201c}", with: "\"")
            .replacingOccurrences(of: "\u{201d}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static func isValidJavaScriptCallback(_ value: String) -> Bool {
        let reserved: Set<String> = [
            "break", "case", "catch", "class", "const", "continue", "debugger",
            "default", "delete", "do", "else", "export", "extends", "finally",
            "for", "function", "if", "import", "in", "instanceof", "new",
            "return", "super", "switch", "this", "throw", "try", "typeof",
            "var", "void", "while", "with", "yield"
        ]
        guard !reserved.contains(value) else { return false }
        return value.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)*$"#, options: .regularExpression) != nil
    }
}
