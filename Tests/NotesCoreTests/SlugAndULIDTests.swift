import XCTest
@testable import NotesCore

final class SlugTests: XCTestCase {

    func testSlugifyBasics() {
        XCTAssertEqual(Slug.slugify("Hello World"), "hello-world")
        XCTAssertEqual(Slug.slugify("Elden Ring: Malenia"), "elden-ring-malenia")
        XCTAssertEqual(Slug.slugify("  spaced  out  "), "spaced-out")
        XCTAssertEqual(Slug.slugify("---leading---"), "leading")
        XCTAssertEqual(Slug.slugify("RTX 4070"), "rtx-4070")
    }

    func testSlugifyNeverReturnsEmpty() {
        XCTAssertEqual(Slug.slugify(""), "untitled")
        XCTAssertEqual(Slug.slugify("!!!"), "untitled")
        XCTAssertEqual(Slug.slugify("   "), "untitled")
    }

    /// Accents fold to their base letter rather than vanishing, so a note
    /// titled "Café" files as `cafe` and not `caf`.
    func testAccentsFoldToBaseLetters() {
        XCTAssertEqual(Slug.slugify("Café"), "cafe")
        XCTAssertEqual(Slug.slugify("naïve"), "naive")
        XCTAssertEqual(Slug.slugify("Jägermeister"), "jagermeister")
        XCTAssertEqual(Slug.slugify("straße"), "strasse")
    }

    /// The vault is meant to be copyable to the Windows app, so folder names
    /// stay legal there even though iOS would accept them.
    func testWindowsReservedNamesGetSuffixed() {
        XCTAssertEqual(Slug.safeDirname("CON"), "CON_")
        XCTAssertEqual(Slug.safeDirname("com1"), "com1_")
        XCTAssertEqual(Slug.safeDirname("NUL.txt"), "NUL.txt_")
        XCTAssertEqual(Slug.safeDirname("Console"), "Console")
    }

    func testSafeDirnameKeepsCaseAndSpaces() {
        XCTAssertEqual(Slug.safeDirname("Technology"), "Technology")
        XCTAssertEqual(Slug.safeDirname("Elden Ring"), "Elden Ring")
        XCTAssertEqual(Slug.safeDirname("Web  Dev"), "Web Dev")
    }

    func testSafeDirnameStripsIllegalCharacters() {
        XCTAssertEqual(Slug.safeDirname("a/b"), "ab")
        XCTAssertEqual(Slug.safeDirname("why?"), "why")
        XCTAssertEqual(Slug.safeDirname("a:b*c|d"), "abcd")
        XCTAssertEqual(Slug.safeDirname("trailing."), "trailing")
        XCTAssertEqual(Slug.safeDirname("///"), "Untitled")
    }

    func testLengthCaps() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(Slug.safeDirname(long).count, Slug.maxDirname)
        XCTAssertEqual(Slug.filenameStem(title: long, body: "").count, Slug.maxFilename)
    }

    func testDirComponentsSplitsACollectionPath() {
        XCTAssertEqual(Slug.dirComponents(forTopicPath: "Gaming/Elden Ring"), ["Gaming", "Elden Ring"])
        XCTAssertEqual(Slug.dirComponents(forTopicPath: "Technology"), ["Technology"])
        XCTAssertEqual(Slug.dirComponents(forTopicPath: ""), [])
    }

    func testFilenameStemFallsBackToBody() {
        XCTAssertEqual(Slug.filenameStem(title: "", body: "buy milk and coffee"), "buy-milk-and-coffee")
        XCTAssertEqual(Slug.filenameStem(title: "Title Here", body: "ignored"), "title-here")
    }
}

final class ULIDTests: XCTestCase {

    func testShapeIsTwentySixCrockfordCharacters() {
        for _ in 0..<200 {
            let id = ULID.generate()
            XCTAssertEqual(id.count, 26)
            XCTAssertTrue(ULID.isValid(id), "not Crockford base32: \(id)")
        }
    }

    func testIdsAreUnique() {
        var seen = Set<String>()
        for _ in 0..<2000 { seen.insert(ULID.generate()) }
        XCTAssertEqual(seen.count, 2000)
    }

    /// Sorting by id must sort by creation time -- several listings rely on
    /// that instead of keeping a separate index.
    func testIdsSortByTime() {
        let earlier = ULID.generate(milliseconds: 1_700_000_000_000, randomHigh: 0, randomLow: 0)
        let later = ULID.generate(milliseconds: 1_700_000_001_000, randomHigh: 0, randomLow: 0)
        XCTAssertLessThan(earlier, later)

        // Same millisecond, different randomness: still a valid, stable order.
        let a = ULID.generate(milliseconds: 1_700_000_000_000, randomHigh: 0, randomLow: 1)
        let b = ULID.generate(milliseconds: 1_700_000_000_000, randomHigh: 0, randomLow: 2)
        XCTAssertLessThan(a, b)
    }

    func testRejectsMalformedIds() {
        XCTAssertFalse(ULID.isValid("short"))
        XCTAssertFalse(ULID.isValid(String(repeating: "U", count: 26)))  // U is not in Crockford
        XCTAssertFalse(ULID.isValid(String(repeating: "0", count: 27)))
        XCTAssertTrue(ULID.isValid(String(repeating: "0", count: 26)))
    }
}

final class TimestampTests: XCTestCase {

    func testUTCFormIsSecondPrecisionWithZ() {
        let date = Date(timeIntervalSince1970: 1_762_108_833)
        XCTAssertEqual(Timestamp.utcNow(date), "2025-11-02T18:40:33Z")
    }

    /// `due` and `remind` carry no zone on purpose: a reminder set for 6pm
    /// means 6pm wherever you are. Mixing the two forms up is the easiest way
    /// to make reminders fire at the wrong hour.
    func testLocalFormHasNoZoneSuffix() {
        let local = Timestamp.localNow(Date(timeIntervalSince1970: 1_762_108_833))
        XCTAssertFalse(local.hasSuffix("Z"))
        XCTAssertEqual(local.count, 19)
    }
}
