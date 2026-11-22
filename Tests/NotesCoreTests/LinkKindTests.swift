import XCTest
@testable import NotesCore

final class LinkKindTests: XCTestCase {

    func testWorksOutTheKindFromHostAndPath() {
        let cases: [(String, String)] = [
            ("https://www.youtube.com/watch?v=abc", "video"),
            ("https://youtube.com/shorts/abc", "short"),
            ("https://www.youtube.com/live/abc", "live"),
            ("https://www.youtube.com/@someone", "profile"),
            ("https://youtu.be/abc", "video"),
            ("https://www.instagram.com/reel/abc/", "reel"),
            ("https://www.instagram.com/p/abc/", "post"),
            ("https://www.instagram.com/someone/", "profile"),
            ("https://x.com/someone/status/123", "post"),
            ("https://x.com/someone", "profile"),
            ("https://www.linkedin.com/in/someone/", "profile"),
            ("https://www.reddit.com/r/swift/comments/abc", "post"),
            ("https://vimeo.com/123456", "video"),
            ("https://www.twitch.tv/someone", "live"),
            ("https://docs.google.com/document/d/abc/edit", "doc"),
            ("https://docs.google.com/spreadsheets/d/abc/edit", "sheet"),
            ("https://docs.google.com/presentation/d/abc/edit", "slides"),
            ("https://docs.google.com/forms/d/abc/viewform", "form"),
            ("https://drive.google.com/file/d/abc/view", "drive"),
            ("https://github.com/apple/swift", "code"),
            ("https://maps.apple.com/?ll=1,2", "place"),
            ("https://www.google.com/maps/place/somewhere", "place"),
            ("https://example.com/an-article", "page")
        ]
        for (url, expected) in cases {
            XCTAssertEqual(LinkKind.of(urlString: url), expected, url)
        }
    }

    /// The host is matched on its suffix so regional and subdomain variants
    /// land in the same bucket, rather than silently becoming plain links.
    func testMatchesSubdomains() {
        XCTAssertEqual(LinkKind.of(urlString: "https://m.youtube.com/watch?v=a"), "video")
        XCTAssertEqual(LinkKind.of(urlString: "https://old.reddit.com/r/a/comments/b"), "post")
    }

    func testUnparseableLinksAreJustPages() {
        XCTAssertEqual(LinkKind.of(urlString: "not a url"), "page")
        XCTAssertEqual(LinkKind.of(urlString: ""), "page")
        XCTAssertEqual(LinkKind.of(host: "", path: ""), "page")
    }
}
