import XCTest
@testable import NotesCore

final class ImageFormatTests: XCTestCase {

    func header(_ bytes: [UInt8], padTo count: Int = 16) -> [UInt8] {
        bytes + [UInt8](repeating: 0, count: max(0, count - bytes.count))
    }

    func testRecognisesTheFormatsAPhoneProduces() {
        XCTAssertEqual(ImageFormat.sniff(header([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), .png)
        XCTAssertEqual(ImageFormat.sniff(header([0xFF, 0xD8, 0xFF, 0xE0])), .jpeg)
        XCTAssertEqual(ImageFormat.sniff(header(Array("GIF89a".utf8))), .gif)
        XCTAssertEqual(ImageFormat.sniff(header([0x49, 0x49, 0x2A, 0x00])), .tiff)
    }

    func testRecognisesWebP() {
        var bytes = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8)
        bytes += [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(ImageFormat.sniff(bytes), .webp)
    }

    /// An iPhone screenshot or photo is usually HEIC, so this is the format
    /// that matters most here.
    func testRecognisesHEIC() {
        for brand in ["heic", "heix", "mif1"] {
            let bytes = [UInt8](repeating: 0, count: 4) + Array("ftyp".utf8) + Array(brand.utf8) + [0, 0, 0, 0]
            XCTAssertEqual(ImageFormat.sniff(bytes), .heic, brand)
        }
    }

    /// Never trust a filename or a declared type — both come from whatever
    /// sent the data. Anything unrecognised is refused.
    func testRefusesThingsThatAreNotImages() {
        XCTAssertNil(ImageFormat.sniff(Array("<html><body>hello".utf8)))
        XCTAssertNil(ImageFormat.sniff(Array("%PDF-1.7".utf8) + [UInt8](repeating: 0, count: 8)))
        XCTAssertNil(ImageFormat.sniff([UInt8](repeating: 0, count: 32)))
        XCTAssertNil(ImageFormat.sniff([]))
        XCTAssertNil(ImageFormat.sniff([0x89, 0x50]), "too short to tell")
    }

    func testStripsDataURLPrefix() {
        XCTAssertEqual(ImageFormat.base64Payload(of: "data:image/png;base64,AAAA"), "AAAA")
        XCTAssertEqual(ImageFormat.base64Payload(of: "AAAA"), "AAAA")
        XCTAssertEqual(ImageFormat.base64Payload(of: "data:image/png;base64,"), "")
    }

    func testExtensionsAndTypesAgree() {
        for format in ImageFormat.allCases {
            XCTAssertFalse(format.fileExtension.isEmpty)
            XCTAssertTrue(format.contentType.hasPrefix("image/"))
        }
    }
}

final class ImageNoteTests: XCTestCase {

    let body = """
        my own words about this screenshot

        **What's in the picture**

        a terminal window

        **Text in image**

        error: unable to load standard library
        """

    func testSplitsTheThreeParts() {
        let parts = ImageNote.split(body)
        XCTAssertEqual(parts.userText, "my own words about this screenshot")
        XCTAssertEqual(parts.description, "a terminal window")
        XCTAssertEqual(parts.transcript, "error: unable to load standard library")
    }

    func testRoundTrips() {
        XCTAssertEqual(ImageNote.join(ImageNote.split(body)), body)
    }

    func testANoteWithNoMachineTextIsAllUserText() {
        let parts = ImageNote.split("just a caption")
        XCTAssertEqual(parts.userText, "just a caption")
        XCTAssertTrue(parts.description.isEmpty)
        XCTAssertTrue(parts.transcript.isEmpty)
    }

    func testMultiParagraphSectionsSurvive() {
        let source = ImageNote.join(ImageNote.Parts(
            userText: "line one\n\nline two",
            description: "para one\n\npara two",
            transcript: "a\nb\nc"
        ))
        let parts = ImageNote.split(source)
        XCTAssertEqual(parts.userText, "line one\n\nline two")
        XCTAssertEqual(parts.description, "para one\n\npara two")
        XCTAssertEqual(parts.transcript, "a\nb\nc")
    }

    /// Re-running recognition must not clobber what the user typed, and
    /// editing a caption must not disturb a transcript they did not write.
    func testReplacingMachineTextLeavesTheCaptionAlone() {
        let updated = ImageNote.replacingMachineText(
            in: body, description: nil, transcript: "a better transcript"
        )
        let parts = ImageNote.split(updated)
        XCTAssertEqual(parts.userText, "my own words about this screenshot")
        XCTAssertEqual(parts.description, "a terminal window", "untouched when passed nil")
        XCTAssertEqual(parts.transcript, "a better transcript")
    }

    func testTranscriptCanBeAddedToANoteThatHadNone() {
        let updated = ImageNote.replacingMachineText(
            in: "my caption", description: nil, transcript: "found text"
        )
        XCTAssertEqual(ImageNote.split(updated).userText, "my caption")
        XCTAssertEqual(ImageNote.split(updated).transcript, "found text")
    }

    /// A line that merely looks like a heading inside a transcript must not
    /// split the note — OCR of a screenshot can contain anything.
    func testHeadingsOnlyCountOnTheirOwnLine() {
        let tricky = ImageNote.join(ImageNote.Parts(
            userText: "caption",
            transcript: "the slide said **Text in image** was a heading"
        ))
        XCTAssertEqual(ImageNote.split(tricky).transcript, "the slide said **Text in image** was a heading")
    }

    func testPlaceholderIsRecognised() {
        let placeholder = ImageNote.placeholder(filename: "abc123.png")
        XCTAssertEqual(placeholder, "(image: abc123.png)")
        XCTAssertTrue(ImageNote.isPlaceholder(placeholder))
        XCTAssertFalse(ImageNote.isPlaceholder("a real caption"))
    }

    func testEmptyPartsProduceEmptyBody() {
        XCTAssertEqual(ImageNote.join(ImageNote.Parts()), "")
    }
}
