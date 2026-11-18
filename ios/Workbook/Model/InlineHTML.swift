import Foundation
import SwiftUI

/// The API's text nodes carry small HTML fragments (`<h2 id=…>`, `<b>`,
/// `<sub>`, `<a class="qv qv-tool" target=…>`). This turns them into
/// AttributedStrings without a web view.
enum InlineHTML {
    struct Heading {
        let level: Int
        let id: String?
        let text: String
    }

    struct Anchor {
        let classes: String
        let target: String
        let text: String
    }

    /// `workbook://anchor/<id>` — in-document links, handled by the document screen.
    static func anchorURL(_ target: String) -> URL? {
        var components = URLComponents()
        components.scheme = "workbook"
        components.host = "anchor"
        components.path = "/" + target
        return components.url
    }

    /// A fragment that is exactly one `<hN>` element.
    static func heading(_ html: String) -> Heading? {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.wholeMatch(of: /<h([1-6])([^>]*)>(.*)<\/h[1-6]>/.dotMatchesNewlines()) else { return nil }
        return Heading(level: Int(match.1) ?? 2,
                       id: attribute("id", in: String(match.2)),
                       text: plain(String(match.3)))
    }

    /// The first `<a>` in a link node's html.
    static func anchor(_ html: String) -> Anchor? {
        guard let match = html.firstMatch(of: /<a\b([^>]*)>(.*?)<\/a>/.dotMatchesNewlines()) else { return nil }
        let attributes = String(match.1)
        return Anchor(classes: attribute("class", in: attributes) ?? "",
                      target: attribute("target", in: attributes) ?? "",
                      text: plain(String(match.2)))
    }

    static func plain(_ html: String) -> String {
        String(attributed(html).characters)
    }

    static func attributed(_ html: String) -> AttributedString {
        var result = AttributedString()
        var bold = 0, italic = 0, sub = 0, sup = 0
        var link: URL?
        var pendingSpace = false

        func append(_ raw: Substring) {
            let decoded = decodeEntities(String(raw))
            // Collapse the source's indentation/newlines into single spaces.
            for word in decoded.split(omittingEmptySubsequences: false, whereSeparator: \.isWhitespace) {
                if word.isEmpty { pendingSpace = true; continue }
                var text = String(word)
                if pendingSpace, !result.characters.isEmpty, result.characters.last != "\n" { text = " " + text }
                pendingSpace = true
                var run = AttributedString(text)
                var intent: InlinePresentationIntent = []
                if bold > 0 { intent.insert(.stronglyEmphasized) }
                if italic > 0 { intent.insert(.emphasized) }
                if !intent.isEmpty { run.inlinePresentationIntent = intent }
                if sub > 0 { run.baselineOffset = -3; run.font = .caption }
                if sup > 0 { run.baselineOffset = 5; run.font = .caption }
                if let link { run.link = link }
                result.append(run)
            }
            // A run ending in non-whitespace must not force a space before the next one.
            if let last = decoded.last, !last.isWhitespace { pendingSpace = false }
        }

        var rest = Substring(html)
        while let open = rest.firstIndex(of: "<") {
            append(rest[rest.startIndex..<open])
            guard let close = rest[open...].firstIndex(of: ">") else {
                rest = rest[open...].dropFirst()
                continue
            }
            let tag = rest[rest.index(after: open)..<close]
            let closing = tag.hasPrefix("/")
            let name = tag.drop(while: { $0 == "/" }).prefix(while: { $0.isLetter || $0.isNumber }).lowercased()
            let delta = closing ? -1 : 1
            switch name {
            case "b", "strong": bold = max(0, bold + delta)
            case "i", "em": italic = max(0, italic + delta)
            case "sub": sub = max(0, sub + delta)
            case "sup": sup = max(0, sup + delta)
            case "br":
                result.append(AttributedString("\n"))
                pendingSpace = false
            case "a":
                if closing {
                    link = nil
                } else if let target = attribute("target", in: String(tag)), !target.isEmpty {
                    link = anchorURL(target)
                }
            default: break
            }
            rest = rest[rest.index(after: close)...]
        }
        append(rest)
        return result
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? Regex("\\b\(name)\\s*=\\s*\"([^\"]*)\""),
              let match = tag.firstMatch(of: regex),
              let value = match.output[1].substring else { return nil }
        return String(value)
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "deg": "°", "micro": "µ", "times": "×", "plusmn": "±", "ndash": "–", "mdash": "—",
        "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "hellip": "…", "Oslash": "Ø", "oslash": "ø",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacing(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/) { match in
            let name = String(match.1)
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.0)
            }
            if name.hasPrefix("#") {
                return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.0)
            }
            return entities[name] ?? String(match.0)
        }
    }
}
