import Foundation
import XCTest
@testable import ImmichKit
@testable import ImmichUI

/// The app in Norwegian Bokmål: language choice, translations and their completeness.
final class LocalizationTests: XCTestCase {
    override func tearDown() { Localization.languageOverride = nil; super.tearDown() }

    private var packageRoot: URL {
        // The folder holding Package.swift, however deep this test file sits.
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path),
              url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return url
    }

    func testNorwegianVariantsChooseBokmalAndEverythingElseEnglish() {
        for language in ["nb-NO", "nb", "no", "nn-NO", "NB_no"] {
            Localization.languageOverride = language
            XCTAssertEqual(Localization.languageCode, "nb", language)
        }
        for language in ["en-GB", "en", "sv-SE", "de"] {
            Localization.languageOverride = language
            XCTAssertEqual(Localization.languageCode, "en", language)
        }
        Localization.languageOverride = "nb-NO"
        XCTAssertEqual(Localization.locale.identifier, "nb_NO")
    }

    func testNorwegianTextsFromBothModules() {
        Localization.languageOverride = "nb"
        XCTAssertEqual(ImmichUI.tr("Library"), "Bibliotek")
        XCTAssertEqual(ImmichUI.tr("Sort by Date Captured"), "Sorter etter dato tatt")
        XCTAssertEqual(ImmichUI.tr("%lld Columns", Int64(5)), "5 kolonner")
        XCTAssertEqual(ImmichUI.tr("%@, %lld items", "Juni", Int64(12)), "Juni, 12 objekter")
        XCTAssertEqual(LoginError.invalidAPIKey.title, "Feil API-nøkkel")
        XCTAssertEqual(ImmichServiceError.unexpectedStatus(503).errorDescription, "Serveren svarte med HTTP-status 503.")
        let memory = Memory(id: "m", kind: .birthday(personId: "p", personName: "Kari", year: 2000), memoryAt: .now, assets: [])
        XCTAssertEqual(memory.title(), "Kari har bursdag")
    }

    func testBackgroundBackupStatusIsTranslated() {
        Localization.languageOverride = "nb"
        XCTAssertEqual(ImmichUI.tr("Uploading in the background: %lld", Int64(3)), "Lastes opp i bakgrunnen: 3")
        XCTAssertEqual(ImmichUI.tr("Last backup: %@", "for 2 timer siden"), "Siste sikkerhetskopi: for 2 timer siden")
        XCTAssertEqual(
            ImmichUI.tr("Bloom backs up when it is open and at night while charging. iOS decides the exact time."),
            "Bloom tar sikkerhetskopi når appen er åpen og om natten mens den lader. iOS bestemmer nøyaktig når.")
        XCTAssertEqual(
            ImmichUI.tr("Background App Refresh is off for Bloom. Turn it on in Settings to back up when Bloom is closed."),
            "Bakgrunnsoppdatering er av for Bloom. Slå den på i Innstillinger for å ta sikkerhetskopi når Bloom er lukket.")
        XCTAssertEqual(
            ImmichUI.tr("Backup stopped: the server redirected an upload to another address. Check your server setup, then open Backup again."),
            "Sikkerhetskopiering stoppet: serveren sendte en opplasting videre til en annen adresse. Sjekk serveroppsettet og åpne Sikkerhetskopi igjen.")
        Localization.languageOverride = "en"
        XCTAssertEqual(ImmichUI.tr("Last backup: %@", "2 hours ago"), "Last backup: 2 hours ago")
    }

    func testEnglishIsTheKeyItself() {
        Localization.languageOverride = "en"
        XCTAssertEqual(ImmichUI.tr("Library"), "Library")
        XCTAssertEqual(ImmichUI.tr("%lld Columns", Int64(3)), "3 Columns")
        XCTAssertEqual(LoginError.invalidAPIKey.title, "Wrong API Key")
    }

    func testMonthsAndDatesFollowTheLanguage() {
        Localization.languageOverride = "nb"
        let october = TimeBucket(id: "2026-10-01", year: 2026, month: 10, count: 1)
        XCTAssertTrue(LibraryGridModel.monthTitle(for: october).lowercased().contains("oktober"),
                      LibraryGridModel.monthTitle(for: october))
    }

    /// Every text passed to `tr` in the sources has a Norwegian translation (a new English text
    /// without one fails here), and the translations keep the same format placeholders.
    func testEveryTextHasANorwegianTranslation() throws {
        for module in ["ImmichKit", "ImmichUI"] {
            let sources = packageRoot.appendingPathComponent("Sources/\(module)")
            let stringsURL = sources.appendingPathComponent("Resources/nb.lproj/Localizable.strings")
            let translations = try XCTUnwrap(NSDictionary(contentsOf: stringsURL) as? [String: String], module)
            var keys: Set<String> = []
            let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            let pattern = try NSRegularExpression(pattern: #"tr\((?:[a-z]+ == 1 \? )?"((?:[^"\\]|\\.)*)"(?: : "((?:[^"\\]|\\.)*)")?"#)
            for case let file as URL in files where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    for group in 1...2 {
                        if let range = Range(match.range(at: group), in: text) { keys.insert(String(text[range])) }
                    }
                }
            }
            XCTAssertGreaterThan(keys.count, 10, module)
            for key in keys.sorted() {
                guard let translation = translations[key] else {
                    XCTFail("\(module): no Norwegian translation for \"\(key)\""); continue
                }
                let placeholders = { (s: String) -> [String] in
                    let plain = s.replacingOccurrences(of: #"%\d\$"#, with: "%", options: .regularExpression)
                    let regex = try! NSRegularExpression(pattern: "%(@|lld)")
                    return regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
                        .compactMap { Range($0.range(at: 1), in: plain).map { String(plain[$0]) } }.sorted()
                }
                XCTAssertEqual(placeholders(translation), placeholders(key), "\(module): placeholders of \"\(key)\"")
            }
        }
    }
}
