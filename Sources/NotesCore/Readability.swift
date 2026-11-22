import Foundation

/// Pulling the readable part out of an HTML page, ported from `enrich.py`.
///
/// This is what makes a pasted link file as well as a typed note: a bare URL
/// has almost no text to embed, so without it every link lands in Inbox. With
/// the page's title and opening prose it routes like anything else.
///
/// Hand-rolled rather than regex-driven, and pure, so it is testable on
/// Windows against saved fixtures — which matters because the failure mode of
/// a bad extractor is silent: you get *some* text, just the wrong text, and
/// notes quietly file themselves by a site's cookie banner.
public struct Article: Sendable, Equatable {
    public var title: String
    public var description: String
    public var text: String
    public var siteName: String
    /// The page's own preview image, for a link tile.
    public var imageURL: String
    /// Who made it, where the page says so.
    public var author: String

    public init(
        title: String = "", description: String = "", text: String = "",
        siteName: String = "", imageURL: String = "", author: String = ""
    ) {
        self.title = title
        self.description = description
        self.text = text
        self.siteName = siteName
        self.imageURL = imageURL
        self.author = author
    }

    public var isEmpty: Bool {
        title.isEmpty && description.isEmpty && text.isEmpty
    }
}

public enum Readability {

    /// Cap on extracted body text, matching the Python side. Long enough to
    /// describe an article, short enough not to swamp the user's own words.
    public static let maxText = 8000

    /// Elements whose text is never part of the article. Navigation and
    /// cookie notices are the ones that actually cause misfiling, because
    /// every page on a site shares them — so notes cluster by website rather
    /// than by subject.
    static let skipped: Set<String> = [
        "script", "style", "nav", "footer", "header", "aside",
        "noscript", "form", "svg", "iframe", "button", "select", "template"
    ]

    /// Elements that end a line of text.
    static let blocks: Set<String> = [
        "p", "div", "br", "li", "tr", "section", "article",
        "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre"
    ]

    public static func extract(_ html: String) -> Article {
        var article = Article()
        article.title = decode(tagText(html, tag: "title"))
        article.description = decode(meta(html, property: "og:description"))
            .ifEmpty(decode(meta(html, name: "description")))
        article.siteName = decode(meta(html, property: "og:site_name"))

        let ogTitle = decode(meta(html, property: "og:title"))
        if article.title.isEmpty { article.title = ogTitle }

        article.imageURL = decode(meta(html, property: "og:image"))
            .ifEmpty(decode(meta(html, name: "twitter:image")))
        article.author = decode(meta(html, property: "article:author"))
            .ifEmpty(decode(meta(html, name: "author")))
        article.text = bodyText(html)
        return article
    }

    // MARK: - Body text

    static func bodyText(_ html: String) -> String {
        var out: [String] = []
        var current = ""
        var index = html.startIndex

        while index < html.endIndex {
            guard let open = html[index...].firstIndex(of: "<") else {
                current += html[index...]
                break
            }
            current += html[index..<open]

            guard let close = html[open...].firstIndex(of: ">") else { break }
            let tag = String(html[html.index(after: open)..<close])
            let name = tagName(tag)

            if skipped.contains(name), !tag.hasPrefix("/") {
                // Skip the element whole, not just its opening tag: otherwise
                // a script's contents become "article text".
                if let end = closingTag(html, name: name, from: close) {
                    index = end
                    continue
                }
                break
            }

            if blocks.contains(name) {
                out.append(current)
                current = ""
            }
            index = html.index(after: close)
        }
        out.append(current)

        let text = out
            .map { collapse(decode($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return String(text.prefix(maxText))
    }

    static func tagName(_ tag: String) -> String {
        var name = tag
        if name.hasPrefix("/") { name.removeFirst() }
        let cut = name.prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }
        return cut.lowercased()
    }

    static func closingTag(_ html: String, name: String, from: String.Index) -> String.Index? {
        var search = html.index(after: from)
        while search < html.endIndex {
            guard let open = html[search...].firstIndex(of: "<") else { return nil }
            guard let close = html[open...].firstIndex(of: ">") else { return nil }
            let tag = String(html[html.index(after: open)..<close])
            if tag.hasPrefix("/"), tagName(tag) == name {
                return html.index(after: close)
            }
            search = html.index(after: close)
        }
        return nil
    }

    // MARK: - Head

    static func tagText(_ html: String, tag: String) -> String {
        guard let range = html.range(of: "<\(tag)", options: .caseInsensitive),
              let open = html[range.lowerBound...].firstIndex(of: ">") else { return "" }
        let start = html.index(after: open)
        guard let end = html.range(of: "</\(tag)", options: .caseInsensitive, range: start..<html.endIndex) else {
            return ""
        }
        return collapse(String(html[start..<end.lowerBound]))
    }

    static func meta(_ html: String, property: String) -> String {
        metaContent(html, attribute: "property", value: property)
            .ifEmpty(metaContent(html, attribute: "name", value: property))
    }

    static func meta(_ html: String, name: String) -> String {
        metaContent(html, attribute: "name", value: name)
    }

    /// Finds `<meta … content="…">` without assuming attribute order — pages
    /// write these both ways round, and half of them would be missed by a
    /// pattern that assumes one.
    static func metaContent(_ html: String, attribute: String, value: String) -> String {
        var search = html.startIndex
        while let open = html.range(of: "<meta", options: .caseInsensitive, range: search..<html.endIndex) {
            guard let close = html[open.lowerBound...].firstIndex(of: ">") else { return "" }
            let tag = String(html[open.lowerBound...close])
            search = html.index(after: close)

            guard let found = attributeValue(tag, name: attribute),
                  found.caseInsensitiveCompare(value) == .orderedSame else { continue }
            if let content = attributeValue(tag, name: "content") {
                return collapse(content)
            }
        }
        return ""
    }

    static func attributeValue(_ tag: String, name: String) -> String? {
        guard let found = tag.range(of: name + "=", options: .caseInsensitive) else { return nil }
        var rest = tag[found.upperBound...]
        guard let quote = rest.first, quote == "\"" || quote == "'" else {
            let unquoted = rest.prefix { !$0.isWhitespace && $0 != ">" }
            return unquoted.isEmpty ? nil : String(unquoted)
        }
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: quote) else { return nil }
        return String(rest[..<end])
    }

    // MARK: - Text

    static func collapse(_ text: String) -> String {
        var out = ""
        var lastWasSpace = true
        for character in text {
            if character.isWhitespace || character.isNewline {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(character)
                lastWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "mdash": "\u{2014}", "ndash": "\u{2013}",
        "hellip": "\u{2026}", "rsquo": "\u{2019}", "lsquo": "\u{2018}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "#39": "'", "#x27": "'"
    ]

    public static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&",
                  let semicolon = text[index...].firstIndex(of: ";"),
                  text.distance(from: index, to: semicolon) <= 10 else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            let name = String(text[text.index(after: index)..<semicolon])
            if let replacement = entities[name.lowercased()] {
                out += replacement
            } else if name.hasPrefix("#"), let scalar = numericEntity(name) {
                out.append(Character(scalar))
            } else {
                out += "&" + name + ";"
            }
            index = text.index(after: semicolon)
        }
        return out
    }

    static func numericEntity(_ name: String) -> Unicode.Scalar? {
        var digits = name.dropFirst()
        let radix: Int
        if digits.first == "x" || digits.first == "X" {
            digits = digits.dropFirst()
            radix = 16
        } else {
            radix = 10
        }
        guard let value = UInt32(digits, radix: radix) else { return nil }
        return Unicode.Scalar(value)
    }
}

extension String {
    /// `public` because the app layer uses it too — a site name falling back
    /// to a host, a title falling back to a URL.
    public func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
