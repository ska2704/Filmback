import XCTest
@testable import FujiCore

final class PhotoInspectorTests: XCTestCase {
    func testRecoversModernSettingsIncludingHalfStepsAndSignedWBWithoutDefaults() throws {
        let report = try inspect([
            .short(0x1401, 0xb00), .short(0x1003, 0xe0), .short(0x1002, 1),
            .signed(0x100a, [40, -100]), .signed(0x1041, [24]), .signed(0x1040, [-8]),
            .signed(0x100f, [-2000]), .short(0x1001, 0x82), .short(0x100e, 0x2e0),
            .signed(0x1047, [32]), .short(0x104c, 16), .signed(0x1048, [64]), .signed(0x104e, [0]),
            .short(0x1402, 1), .short(0x1403, 400)
        ])
        let recipe = try XCTUnwrap(report.result.recipes.first)
        XCTAssertEqual(recipe.settings[.filmSimulation], "Reala Ace")
        XCTAssertEqual(recipe.settings[.color], "4")
        XCTAssertEqual(recipe.settings[.whiteBalance], "Auto (white priority)")
        XCTAssertEqual(recipe.settings[.wbShiftR], "2")
        XCTAssertEqual(recipe.settings[.wbShiftB], "-5")
        XCTAssertEqual(recipe.settings[.highlight], "-1.5")
        XCTAssertEqual(recipe.settings[.shadow], "0.5")
        XCTAssertEqual(recipe.settings[.clarity], "-2")
        XCTAssertEqual(recipe.settings[.sharpness], "-1")
        XCTAssertEqual(recipe.settings[.highISONR], "-4")
        XCTAssertEqual(recipe.settings[.grainRoughness], "Weak")
        XCTAssertEqual(recipe.settings[.grainSize], "Small")
        XCTAssertEqual(recipe.settings[.colorChromeEffect], "Strong")
        XCTAssertEqual(recipe.settings[.colorChromeFXBlue], "Off")
        XCTAssertEqual(recipe.settings[.dynamicRange], "DR400")
        XCTAssertNil(recipe.settings[.dRangePriority])
        XCTAssertNil(recipe.settings[.portraitEnhancer])
        XCTAssertNil(recipe.suggestedSlot)
        XCTAssertTrue(recipe.sensors.isEmpty)
        XCTAssertTrue(report.missingFields.contains(.portraitEnhancer))
        XCTAssertEqual(try RecipeImporter.parse(RecipeExporter.json(recipes: [recipe])).recipes[0].settings, recipe.settings)
    }

    func testMonochromeSaturationOverridesFilmModeWithoutInventingColor() throws {
        for (raw, name) in [(0x501, "Acros Red"), (0x302, "Monochrome Yellow"), (0x310, "Sepia")] {
            let result = try inspect([.short(0x1401, 0), .short(0x1003, UInt16(raw))])
            XCTAssertEqual(result.result.recipes[0].settings[.filmSimulation], name)
            XCTAssertNil(result.result.recipes[0].settings[.color])
        }
    }

    func testUnknownAndMissingValuesRemainUnspecified() throws {
        let result = try inspect([.short(0x1401, 0xeeee), .signed(0x100a, [1, -5]),
                                  .signed(0x1040, [-7]), .short(0x7777, 123)])
        XCTAssertTrue(result.result.recipes[0].settings.isEmpty)
        XCTAssertTrue(result.unrecognized.contains { $0.contains("0x1401") })
        XCTAssertTrue(result.unrecognized.contains { $0.contains("fine tune") })
        XCTAssertTrue(result.unrecognized.contains { $0.contains("0x1040") })
        XCTAssertTrue(result.unrecognized.contains { $0.contains("0x7777") })
        XCTAssertTrue(result.result.warnings.contains { $0.contains("remain unspecified") })
    }

    func testLegacyWhiteBalanceEncodingIsNotGuessed() throws {
        let result = try inspect([.signed(0x100a, [20, -40]), .short(0x1002, 0)], model: "FinePix S5Pro")
        XCTAssertEqual(result.result.recipes[0].settings[.whiteBalance], "Auto")
        XCTAssertNil(result.result.recipes[0].settings[.wbShiftR])
        XCTAssertTrue(result.unrecognized.contains { $0.contains("unverified model") })
    }

    func testAutoDynamicRangeIsPreservedInsteadOfEffectivePhotoValue() throws {
        let result = try inspect([.short(0x1402, 0), .short(0x1403, 200)])
        XCTAssertEqual(result.result.recipes[0].settings[.dynamicRange], "DR-Auto")
        XCTAssertTrue(result.metadata.contains(.init(label: "Development dynamic range", value: "200%")))
        let effectiveOnly = try inspect([.short(0x1403, 400)])
        XCTAssertNil(effectiveOnly.result.recipes[0].settings[.dynamicRange])
    }

    func testDRangePriorityAndCustomWhiteBalanceCaveats() throws {
        let fixed = try inspect([.short(0x1443, 1), .short(0x1445, 2), .short(0x1002, 0xf00)])
        XCTAssertEqual(fixed.result.recipes[0].settings[.dRangePriority], "Strong")
        XCTAssertEqual(fixed.result.recipes[0].settings[.whiteBalance], "Custom 1")
        XCTAssertTrue(fixed.result.warnings.contains { $0.contains("reference measurements") })
        let auto = try inspect([.short(0x1443, 0), .short(0x1444, 1)])
        XCTAssertEqual(auto.result.recipes[0].settings[.dRangePriority], "Auto")
        let missing = try inspect([])
        XCTAssertNil(missing.result.recipes[0].settings[.dRangePriority])
    }

    func testExposureAndLensStayInNotesNotAutoISOOrRecipeDefaults() throws {
        let result = try inspect([.short(0x1401, 0x600)], extraExif: [
            .ascii(0xa434, "XF35mmF2 R WR"), .ascii(0x9003, "2026:10:18 09:00:00"),
            .short(0x8827, 640), .rational(0x829a, 1, 250), .rational(0x829d, 28, 10),
            .rational(0x920a, 35, 1), .rational(0x9204, 1, 3)
        ])
        let notes = result.result.recipes[0].notes
        XCTAssertTrue(notes.contains("Lens: XF35mmF2 R WR"))
        XCTAssertTrue(notes.contains("ISO used: 640"))
        XCTAssertTrue(notes.contains("Exposure time: 0.004 s"))
        XCTAssertTrue(notes.contains("Aperture: f/2.8"))
        XCTAssertTrue(notes.contains("Focal length: 35 mm"))
        XCTAssertTrue(notes.contains("Exposure compensation: 0.333333 EV"))
        XCTAssertEqual(result.result.recipes[0].settings.count, 1)
    }

    func testBigEndianEXIFStillReadsLittleEndianFujifilmMakerNote() throws {
        let result = try inspect([.short(0x1401, 0x800), .signed(0x100a, [-180, 180])], littleEndian: false)
        XCTAssertEqual(result.result.recipes[0].settings[.filmSimulation], "Classic Negative")
        XCTAssertEqual(result.result.recipes[0].settings[.wbShiftR], "-9")
        XCTAssertEqual(result.result.recipes[0].settings[.wbShiftB], "9")
    }

    func testRejectsOtherCamerasAndNonJPEGFormats() throws {
        XCTAssertThrowsError(try FujifilmPhotoInspector.inspectJPEG(jpeg(tags: [.short(0x1401, 0)], make: "SONY"), filename: "photo.jpg"))
        for data in [Data(), Data("FUJIFILMCCD-RAW".utf8), Data([137, 80, 78, 71]), Data([0xff, 0xd8, 0xff, 0xd9])] {
            XCTAssertThrowsError(try FujifilmPhotoInspector.inspectJPEG(data, filename: "photo.raf"))
        }
    }

    func testEveryTruncatedMetadataPrefixFailsWithoutCrashing() throws {
        let data = jpeg(tags: [.short(0x1401, 0x600), .signed(0x100a, [40, -100])])
        for length in 0..<(data.count - 2) {
            XCTAssertThrowsError(try FujifilmPhotoInspector.inspectJPEG(data.prefix(length), filename: "truncated.jpg"), "length \(length)")
        }
    }

    func testRejectsOutOfBoundsMakerDirectoryAndValuePointer() throws {
        var badOffset = makerNote([.short(0x1401, 0)])
        badOffset.replaceSubrange(8..<12, with: [0xff, 0xff, 0xff, 0x7f])
        XCTAssertThrowsError(try FujifilmPhotoInspector.inspectJPEG(jpeg(maker: badOffset), filename: "bad.jpg"))
        var badPointer = makerNote([.signed(0x100a, [20, -40])])
        badPointer.replaceSubrange(22..<26, with: [0xfe, 0xff, 0xff, 0xff])
        XCTAssertThrowsError(try FujifilmPhotoInspector.inspectJPEG(jpeg(maker: badPointer), filename: "bad.jpg"))
        var excessiveCount = makerNote([.short(0x1401, 0)])
        excessiveCount.replaceSubrange(18..<22, with: [0xff, 0xff, 0xff, 0xff])
        XCTAssertThrowsError(try FujifilmPhotoInspector.inspectJPEG(jpeg(maker: excessiveCount), filename: "bad.jpg"))
    }

    func testDuplicateTagsAndZeroDenominatorAreHandled() throws {
        XCTAssertThrowsError(try inspect([.short(0x1401, 0), .short(0x1401, 0x600)]))
        let report = try inspect([.short(0x1401, 0)], extraExif: [.rational(0x829a, 1, 0)])
        XCTAssertFalse(report.metadata.contains { $0.label == "Exposure time" })
    }

    private func inspect(_ tags: [Entry], model: String = "X-M5", littleEndian: Bool = true, extraExif: [Entry] = []) throws -> PhotoInspection {
        try FujifilmPhotoInspector.inspectJPEG(jpeg(tags: tags, model: model, littleEndian: littleEndian, extraExif: extraExif), filename: "DSCF0001.JPG")
    }

    private struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let bytes: [UInt8]
        static func short(_ tag: UInt16, _ value: UInt16) -> Entry { .init(tag: tag, type: 3, count: 1, bytes: encoded(UInt32(value), width: 2)) }
        static func long(_ tag: UInt16, _ value: UInt32) -> Entry { .init(tag: tag, type: 4, count: 1, bytes: encoded(value)) }
        static func signed(_ tag: UInt16, _ values: [Int32]) -> Entry { .init(tag: tag, type: 9, count: UInt32(values.count), bytes: values.flatMap { encoded(UInt32(bitPattern: $0)) }) }
        static func ascii(_ tag: UInt16, _ text: String) -> Entry { let bytes = Array(text.utf8) + [0]; return .init(tag: tag, type: 2, count: UInt32(bytes.count), bytes: bytes) }
        static func blob(_ tag: UInt16, _ bytes: [UInt8]) -> Entry { .init(tag: tag, type: 7, count: UInt32(bytes.count), bytes: bytes) }
        static func rational(_ tag: UInt16, _ a: UInt32, _ b: UInt32) -> Entry { .init(tag: tag, type: 5, count: 1, bytes: encoded(a) + encoded(b)) }
        func valueBytes(littleEndian: Bool) -> [UInt8] {
            guard !littleEndian, let unit = [3: 2, 4: 4, 5: 4, 9: 4][Int(type)] else { return bytes }
            return stride(from: 0, to: bytes.count, by: unit).flatMap { Array(bytes[$0..<($0 + unit)].reversed()) }
        }
    }

    private static func encoded(_ value: UInt32, width: Int = 4, littleEndian: Bool = true) -> [UInt8] {
        (0..<width).map { UInt8(truncatingIfNeeded: value >> (($0) * 8)) }.sortedByEndian(littleEndian)
    }

    private func appendDirectory(_ entries: [Entry], to bytes: inout [UInt8], littleEndian: Bool = true) -> Int {
        let offset = bytes.count
        bytes += Self.encoded(UInt32(entries.count), width: 2, littleEndian: littleEndian)
        bytes += Array(repeating: 0, count: entries.count * 12 + 4)
        for (index, entry) in entries.enumerated() {
            let position = offset + 2 + index * 12
            var row = Self.encoded(UInt32(entry.tag), width: 2, littleEndian: littleEndian)
            row += Self.encoded(UInt32(entry.type), width: 2, littleEndian: littleEndian)
            row += Self.encoded(entry.count, littleEndian: littleEndian)
            let value = entry.valueBytes(littleEndian: littleEndian)
            if value.count <= 4 { row += value + Array(repeating: 0, count: 4 - value.count) }
            else { row += Self.encoded(UInt32(bytes.count), littleEndian: littleEndian); bytes += value }
            bytes.replaceSubrange(position..<(position + 12), with: row)
        }
        return offset
    }

    private func makerNote(_ tags: [Entry]) -> [UInt8] {
        var data = Array("FUJIFILM".utf8) + Self.encoded(12)
        _ = appendDirectory(tags, to: &data)
        return data
    }

    private func jpeg(tags: [Entry] = [], make: String = "FUJIFILM", model: String = "X-M5", littleEndian: Bool = true,
                      extraExif: [Entry] = [], maker: [UInt8]? = nil) -> Data {
        var tiff: [UInt8] = littleEndian ? [73, 73, 42, 0, 0, 0, 0, 0] : [77, 77, 0, 42, 0, 0, 0, 0]
        let exifOffset = appendDirectory([.blob(0x927c, maker ?? makerNote(tags))] + extraExif, to: &tiff, littleEndian: littleEndian)
        let rootOffset = appendDirectory([.ascii(0x010f, make), .ascii(0x0110, model), .long(0x8769, UInt32(exifOffset))], to: &tiff, littleEndian: littleEndian)
        tiff.replaceSubrange(4..<8, with: Self.encoded(UInt32(rootOffset), littleEndian: littleEndian))
        let payload = [69, 120, 105, 102, 0, 0] + tiff
        return Data([0xff, 0xd8, 0xff, 0xe1] + Self.encoded(UInt32(payload.count + 2), width: 2, littleEndian: false) + payload + [0xff, 0xd9])
    }

    private func raf(jpeg: Data, offset: UInt32? = nil, length: UInt32? = nil) -> Data {
        func big(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - $0 * 8)) }) }
        var data = Data("FUJIFILMCCD-RAW ".utf8) + Data(count: 68)
        data += big(offset ?? 148); data += big(length ?? UInt32(jpeg.count))
        data += Data(count: 148 - data.count)
        return data + jpeg
    }

    func testRAFExposesItsEmbeddedJPEG() throws {
        let jpeg = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        XCTAssertEqual(try FujifilmPhotoInspector.embeddedJPEG(inRAF: raf(jpeg: jpeg)), jpeg)
    }

    func testDamagedRAFIsRefused() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        XCTAssertThrowsError(try FujifilmPhotoInspector.embeddedJPEG(inRAF: Data("FUJIFILMCCD-RAW ".utf8)))
        XCTAssertThrowsError(try FujifilmPhotoInspector.embeddedJPEG(inRAF: raf(jpeg: jpeg, length: 4096)))
        XCTAssertThrowsError(try FujifilmPhotoInspector.embeddedJPEG(inRAF: raf(jpeg: jpeg, offset: 0)))
        XCTAssertThrowsError(try FujifilmPhotoInspector.embeddedJPEG(inRAF: raf(jpeg: jpeg, offset: UInt32.max)))
    }

    /// Set RECIPEVAULT_RAF_FIXTURE to check a real RAF, which stays out of the repository.
    func testRealRAFSettingsAreRead() throws {
        guard let path = ProcessInfo.processInfo.environment["RECIPEVAULT_RAF_FIXTURE"] else { throw XCTSkip("No RAF fixture configured.") }
        let result = try FujifilmPhotoInspector.inspect(Data(contentsOf: URL(fileURLWithPath: path)), filename: "fixture.raf")
        XCTAssertNotNil(result.result.recipes.first?.settings[.filmSimulation])
    }
}

private extension Array where Element == UInt8 {
    func sortedByEndian(_ littleEndian: Bool) -> [UInt8] { littleEndian ? self : Array(reversed()) }
}
