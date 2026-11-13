import XCTest
import ImmichKit
@testable import ImmichUI

/// Original names come from the uploader (another person, for shared albums) and become the
/// names the share sheet and the receiving app show.
final class ShareFileNameTests: XCTestCase {
    private func name(_ original: String?, mimeType: String? = "image/jpeg") -> String {
        var asset = MockLibrary.standard.assets[0]
        asset.originalFileName = original
        asset.mimeType = mimeType
        return SelectionShareFiles.safeName(for: asset)
    }

    func testOrdinaryNamesAreKept() {
        XCTAssertEqual(name("IMG_1234.HEIC"), "IMG_1234.HEIC")
        XCTAssertEqual(name("Ferie på Sørlandet 2024.jpg"), "Ferie på Sørlandet 2024.jpg")
        XCTAssertEqual(name("👨‍👩‍👧 family.png"), "👨‍👩‍👧 family.png", "emoji sequences keep their joiners")
    }

    func testDirectionOverridesCannotDisguiseTheExtension() {
        XCTAssertEqual(name("IMG\u{202E}gpj.exe"), "IMGgpj.exe")
        XCTAssertEqual(name("a\u{200B}b\u{2066}c\u{FEFF}.jpg"), "abc.jpg")
    }

    func testSeparatorsControlsAndHiddenNames() {
        XCTAssertEqual(name("../../etc/passwd"), "_.._etc_passwd")
        XCTAssertEqual(name("a\\b:c.jpg"), "a_b_c.jpg")
        XCTAssertEqual(name("line\nbreak\t.jpg"), "linebreak.jpg")
        XCTAssertEqual(name(".hidden.jpg"), "hidden.jpg")
        XCTAssertEqual(name(" .. "), "original.jpeg")
        XCTAssertEqual(name("\u{202E}"), "original.jpeg")
        XCTAssertEqual(name(nil, mimeType: "video/quicktime"), "original.mov")
    }

    func testLongNamesFitTheFileSystemAndKeepTheExtension() {
        let long = name(String(repeating: "å", count: 300) + ".jpg")
        XCTAssertLessThanOrEqual(long.utf8.count, SelectionShareFiles.maxNameBytes)
        XCTAssertTrue(long.hasSuffix(".jpg"))
        XCTAssertTrue(long.hasPrefix("ååå"))
    }
}
