import XCTest
@testable import NotesCore

final class ReadabilityTests: XCTestCase {

    let page = """
        <!doctype html>
        <html><head>
          <title>Chunking for retrieval &mdash; Example Blog</title>
          <meta name="description" content="Why 200-token overlap beats 50.">
          <meta property="og:site_name" content="Example Blog">
          <script>var tracker = "<p>not article text</p>";</script>
          <style>body { color: red }</style>
        </head>
        <body>
          <nav><a href="/">Home</a><a href="/about">About</a></nav>
          <header>Subscribe to our newsletter</header>
          <article>
            <h1>Chunking for retrieval</h1>
            <p>Overlap of 200 tokens beats 50 by a wide margin.</p>
            <p>The reason is that a boundary rarely falls where meaning does.</p>
          </article>
          <aside>Related: five other posts</aside>
          <footer>Copyright 2026</footer>
        </body></html>
        """

    func testTakesTheTitle() {
        let article = Readability.extract(page)
        XCTAssertEqual(article.title, "Chunking for retrieval — Example Blog")
    }

    func testTakesTheDescriptionAndSiteName() {
        let article = Readability.extract(page)
        XCTAssertEqual(article.description, "Why 200-token overlap beats 50.")
        XCTAssertEqual(article.siteName, "Example Blog")
    }

    func testKeepsTheArticleProse() {
        let text = Readability.extract(page).text
        XCTAssertTrue(text.contains("Overlap of 200 tokens beats 50"), text)
        XCTAssertTrue(text.contains("a boundary rarely falls where meaning does"), text)
    }

    /// Navigation and cookie notices are shared by every page on a site, so
    /// keeping them makes notes cluster by website instead of by subject.
    /// This is the failure that actually matters.
    func testDropsChromeThatWouldMakeNotesClusterBySite() {
        let text = Readability.extract(page).text
        for noise in ["Home", "About", "Subscribe", "Related:", "Copyright"] {
            XCTAssertFalse(text.contains(noise), "kept \(noise): \(text)")
        }
    }

    /// A script's contents are not article text, and skipping only the opening
    /// tag would pull the whole thing in.
    func testSkipsScriptAndStyleContents() {
        let text = Readability.extract(page).text
        XCTAssertFalse(text.contains("tracker"), text)
        XCTAssertFalse(text.contains("not article text"), text)
        XCTAssertFalse(text.contains("color: red"), text)
    }

    func testPrefersOpenGraphDescription() {
        let html = """
            <html><head>
            <meta name="description" content="the plain one">
            <meta property="og:description" content="the written one">
            </head><body><p>x</p></body></html>
            """
        XCTAssertEqual(Readability.extract(html).description, "the written one")
    }

    /// Pages write meta attributes in either order, and a pattern that assumes
    /// one would silently miss half the web.
    func testFindsMetaWhateverTheAttributeOrder() {
        let first = "<meta property=\"og:title\" content=\"A\">"
        let second = "<meta content=\"A\" property=\"og:title\">"
        XCTAssertEqual(Readability.meta(first, property: "og:title"), "A")
        XCTAssertEqual(Readability.meta(second, property: "og:title"), "A")
    }

    func testAcceptsSingleQuotedAttributes() {
        let html = "<meta property='og:title' content='Single quoted'>"
        XCTAssertEqual(Readability.meta(html, property: "og:title"), "Single quoted")
    }

    func testFallsBackToOpenGraphTitleWhenThereIsNoTitleTag() {
        let html = "<html><head><meta property=\"og:title\" content=\"Only OG\"></head><body></body></html>"
        XCTAssertEqual(Readability.extract(html).title, "Only OG")
    }

    // MARK: - Entities

    func testDecodesNamedEntities() {
        XCTAssertEqual(Readability.decode("Tom &amp; Jerry"), "Tom & Jerry")
        XCTAssertEqual(Readability.decode("5 &lt; 6 &gt; 4"), "5 < 6 > 4")
        XCTAssertEqual(Readability.decode("it&rsquo;s"), "it\u{2019}s")
    }

    func testDecodesNumericEntities() {
        XCTAssertEqual(Readability.decode("&#39;quoted&#39;"), "'quoted'")
        XCTAssertEqual(Readability.decode("&#x2014;"), "\u{2014}")
    }

    func testLeavesUnknownEntitiesAlone() {
        XCTAssertEqual(Readability.decode("&notareal; thing"), "&notareal; thing")
        XCTAssertEqual(Readability.decode("plain text"), "plain text")
    }

    // MARK: - Robustness
    //
    // A page that breaks the extractor must not break capture: the note is
    // already on disk by then, and a link with no text is merely unfiled.

    func testMalformedHTMLDoesNotCrash() {
        let broken = [
            "<html><body><p>unclosed",
            "<<<>>>",
            "<script>never closed",
            "",
            "no tags at all",
            "<meta property=\"og:title\" content=\"unterminated"
        ]
        for html in broken {
            _ = Readability.extract(html)
        }
    }

    func testVeryLongPagesAreCapped() {
        let long = "<html><body>" + String(repeating: "<p>word word word</p>", count: 5000) + "</body></html>"
        XCTAssertLessThanOrEqual(Readability.extract(long).text.count, Readability.maxText)
    }

    func testWhitespaceIsCollapsed() {
        let html = "<html><body><p>lots\n\n   of     space</p></body></html>"
        XCTAssertEqual(Readability.extract(html).text, "lots of space")
    }

    func testEmptyPageIsEmpty() {
        XCTAssertTrue(Readability.extract("").isEmpty)
    }
}

extension ReadabilityTests {

    func testTakesThePreviewImage() {
        let html = """
            <html><head>
            <meta property="og:image" content="https://example.test/cover.jpg">
            <meta property="article:author" content="A Writer">
            </head><body><p>x</p></body></html>
            """
        let article = Readability.extract(html)
        XCTAssertEqual(article.imageURL, "https://example.test/cover.jpg")
        XCTAssertEqual(article.author, "A Writer")
    }

    func testFallsBackToTwitterImage() {
        let html = "<html><head><meta name=\"twitter:image\" content=\"https://x.test/a.png\"></head></html>"
        XCTAssertEqual(Readability.extract(html).imageURL, "https://x.test/a.png")
    }

    func testPagesWithNoPreviewImageSaySo() {
        XCTAssertEqual(Readability.extract(page).imageURL, "")
    }
}
