import XCTest
import PDFKit
import FujiCore
@testable import Filmback

final class RecipeShareTests: XCTestCase {
    func testPDFPreservesAttributionHalfStepsAndLongNotesAcrossPages() throws {
        let recipe = Recipe(name: "Summer study", sourceURL: "https://example.com/original", author: "Photographer",
                            notes: String(repeating: "Keep the original creator credit and test in changing light.\n", count: 160) + "END OF FIELD NOTES",
                            settings: [.filmSimulation: "Classic Chrome", .highlight: "-1.5", .portraitEnhancer: "Off"])
        let pdf = try XCTUnwrap(PDFDocument(data: RecipeShare.pdf(recipe)))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        let text = try XCTUnwrap(pdf.string)
        XCTAssertTrue(text.contains("https://example.com/original"))
        XCTAssertTrue(text.contains("Photographer"))
        XCTAssertTrue(text.contains("Highlight: -1.5"))
        XCTAssertTrue(text.contains("Portrait enhancer: Off"))
        XCTAssertTrue(text.contains("END OF FIELD NOTES"))
        XCTAssertFalse(text.contains("White balance:"))
    }

    func testTextKeepsUnicodeAndDoesNotAddUnspecifiedValues() {
        let recipe = Recipe(name: "旅 · Été", settings: [.shadow: "0.5"])
        let text = RecipeShare.text(recipe)
        XCTAssertTrue(text.contains("旅 · Été"))
        XCTAssertTrue(text.contains("Shadow: 0.5"))
        XCTAssertFalse(text.contains("Film simulation:"))
    }
}
