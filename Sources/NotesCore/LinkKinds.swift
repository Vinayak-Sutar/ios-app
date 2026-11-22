import Foundation

/// What a saved link *is* — a video, a post, a profile, a doc — worked out
/// from its host and path.
///
/// The Links page shows this on every tile and filters by it, so it has to be
/// decided for links that will never be fetched: a Drive URL is deliberately
/// never contacted, and a tile reading "Link · Drive" is still useful. Pure
/// string work, which is why it lives here and is tested on Windows rather
/// than guessed at on the phone.
///
/// The vocabulary is fixed by `app.html`'s own label table — `reel`, `post`,
/// `profile`, `short`, `video`, `live`, `doc`, `sheet`, `slides`, `form`,
/// `drive`, `code`, `place`, `page` — and anything unrecognised falls back to
/// `page`, which the page renders as plain "Link".
public enum LinkKind {

    public static func of(host rawHost: String, path rawPath: String) -> String {
        var host = rawHost.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = rawPath.lowercased()
        let parts = path.split(separator: "/").map(String.init)
        let first = parts.first ?? ""

        func on(_ suffix: String) -> Bool {
            host == suffix || host.hasSuffix("." + suffix)
        }

        switch true {
        case on("youtube.com"), on("youtu.be"):
            if parts.contains("shorts") { return "short" }
            if parts.contains("live") { return "live" }
            if first.hasPrefix("@") || ["channel", "c", "user"].contains(first) { return "profile" }
            return "video"

        case on("instagram.com"):
            if first == "reel" || first == "reels" { return "reel" }
            if first == "p" || first == "tv" { return "post" }
            return parts.count == 1 ? "profile" : "post"

        case on("tiktok.com"):
            // Short-form by default, and a bare `/@name` is the account.
            return parts.count == 1 && first.hasPrefix("@") ? "profile" : "short"

        case on("x.com"), on("twitter.com"):
            if parts.contains("status") { return "post" }
            return parts.count == 1 ? "profile" : "post"

        case on("facebook.com"), on("threads.net"), on("reddit.com"),
             on("bsky.app"), on("mastodon.social"), on("news.ycombinator.com"):
            return "post"

        case on("linkedin.com"):
            return first == "in" || first == "company" ? "profile" : "post"

        case on("vimeo.com"), on("dailymotion.com"):
            return "video"

        case on("twitch.tv"):
            return "live"

        case on("docs.google.com"):
            // The product is the first path segment: /document/d/…,
            // /spreadsheets/d/…, /presentation/d/…, /forms/d/…
            switch first {
            case "spreadsheets": return "sheet"
            case "presentation": return "slides"
            case "forms": return "form"
            default: return "doc"
            }

        case on("sheets.google.com"): return "sheet"
        case on("slides.google.com"): return "slides"
        case on("forms.gle"): return "form"
        case on("drive.google.com"), on("dropbox.com"), on("onedrive.live.com"):
            return "drive"

        case on("github.com"), on("gitlab.com"), on("bitbucket.org"),
             on("codepen.io"), on("npmjs.com"), on("pypi.org"):
            return "code"

        case on("maps.apple.com"), on("openstreetmap.org"), on("maps.google.com"):
            return "place"

        case on("google.com"):
            return first == "maps" ? "place" : "page"

        default:
            return "page"
        }
    }

    /// The same, from a URL string. Returns `page` for anything unparseable,
    /// because a tile with a plain label is better than no tile.
    public static func of(urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return "page" }
        return of(host: host, path: url.path)
    }
}
