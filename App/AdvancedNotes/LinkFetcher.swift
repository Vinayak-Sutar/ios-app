import Foundation
import NotesCore

/// Fetches a pasted link so it can be filed like any other note.
///
/// A bare URL has almost no text to embed, so without this every link lands in
/// Inbox. With the page's title and opening prose it routes like anything
/// else — which is the whole reason the Python app fetches links too.
///
/// Two rules carried over, both privacy ones, and both enforced here rather
/// than remembered:
///
/// - **Only the link's own site is ever contacted**, never with any of the
///   user's note text. The request carries the URL and nothing else.
/// - **Links that might need the user's account are never fetched at all.**
///   Fetching a Drive or Calendar URL would at best get a sign-in page and at
///   worst tell that service the link had been opened.
actor LinkFetcher {

    /// Hosts where a fetch would either be useless or a disclosure. Matched on
    /// the registrable suffix, so `docs.google.com` and
    /// `calendar.google.com` are covered by their own entries rather than by
    /// blocking all of Google.
    static let neverFetch: Set<String> = [
        "docs.google.com", "drive.google.com", "calendar.google.com",
        "mail.google.com", "meet.google.com", "forms.gle", "goo.gl",
        "notion.so", "www.notion.so", "dropbox.com", "www.dropbox.com",
        "chat.whatsapp.com", "t.me", "chatgpt.com", "chat.openai.com",
        "claude.ai", "teams.microsoft.com", "zoom.us", "outlook.office.com",
        "sharepoint.com", "onedrive.live.com", "icloud.com"
    ]

    static let timeout: TimeInterval = 12
    static let maxBytes = 2_000_000

    enum Refusal: Error, CustomStringConvertible {
        case privateHost(String)
        case notHTTP
        case tooLarge
        case badStatus(Int)

        var description: String {
            switch self {
            case let .privateHost(host): return "\(host) may need your account, so it was not contacted"
            case .notHTTP: return "not an http link"
            case .tooLarge: return "page was too large"
            case let .badStatus(code): return "the site answered \(code)"
            }
        }
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // No personal details in the User-Agent: a generic client name is all
        // a site needs, and anything more identifies the user to every site
        // they ever save a link from.
        configuration.httpAdditionalHeaders = ["User-Agent": "AdvancedNotes/0.1 (link preview)"]
        self.session = URLSession(configuration: configuration)
    }

    static func shouldFetch(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host?.lowercased() else { return false }
        if neverFetch.contains(host) { return false }
        // Also block a subdomain of a listed host, so sheets.google.com is
        // covered without listing every Google product.
        return !neverFetch.contains { host.hasSuffix("." + $0) }
    }

    func fetch(_ url: URL) async throws -> Article {
        guard Self.shouldFetch(url) else {
            throw url.scheme?.hasPrefix("http") == true
                ? Refusal.privateHost(url.host ?? "that site")
                : Refusal.notHTTP
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Refusal.badStatus(http.statusCode)
        }
        guard data.count <= Self.maxBytes else { throw Refusal.tooLarge }

        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return Readability.extract(html)
    }
}

enum LinkText {

    /// The first http(s) URL in a piece of text.
    static func firstURL(in text: String) -> URL? {
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            let candidate = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]<>,\"'"))
            guard candidate.lowercased().hasPrefix("http://")
                || candidate.lowercased().hasPrefix("https://") else { continue }
            if let url = URL(string: candidate), url.host != nil { return url }
        }
        return nil
    }

    /// Every http(s) URL in a note, in order, without duplicates. What the
    /// Links page is built from.
    static func allURLs(in text: String) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            let candidate = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]<>,\"'"))
            guard candidate.lowercased().hasPrefix("http"),
                  let url = URL(string: candidate), url.host != nil else { continue }
            let key = canonical(url)
            if seen.insert(key).inserted { out.append(url) }
        }
        return out
    }

    /// Tracking parameters removed, so the same article shared two ways is one
    /// tile rather than two.
    static func canonical(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let noise: Set<String> = [
            "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
            "fbclid", "gclid", "igshid", "si", "ref", "ref_src", "mc_cid", "mc_eid"
        ]
        parts.queryItems = parts.queryItems?.filter { !noise.contains($0.name.lowercased()) }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        parts.fragment = nil
        return (parts.url?.absoluteString ?? url.absoluteString)
            .lowercased()
            .replacingOccurrences(of: "https://www.", with: "https://")
    }

    /// The body of a link note: the user's own words first, then what the page
    /// said. Their comment is the part they will look for.
    static func body(userText: String, url: URL, article: Article) -> String {
        var out = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a bare URL that is the entire note; keep one written in a
        // sentence, because there it is part of what they wrote.
        if out == url.absoluteString { out = "" }

        var parts: [String] = []
        if !out.isEmpty { parts.append(out) }

        let site = article.siteName.ifEmpty(url.host ?? "link")
        if !article.title.isEmpty {
            parts.append("[\(site)] \(article.title)")
        } else {
            parts.append("[\(site)] \(url.absoluteString)")
        }
        if !article.description.isEmpty { parts.append(article.description) }
        if !article.text.isEmpty { parts.append(String(article.text.prefix(2000))) }

        return parts.joined(separator: "\n\n")
    }
}
