import XCTest
@testable import FujiCore

final class XM5BackupDecoderTests: XCTestCase {
    private static let nameOffsets = [63_985, 65_009, 66_033, 67_057]

    /// Byte values observed for one bank, keyed by offset from the bank name.
    private func object(banks: [(name: String, bytes: [Int: UInt8])]) -> Data {
        var data = Data(count: XM5BackupDecoder.size)
        data.replaceSubrange(0..<XM5BackupDecoder.magic.count, with: XM5BackupDecoder.magic)
        for (index, bank) in banks.enumerated() {
            let base = Self.nameOffsets[index]
            data.replaceSubrange(base..<(base + bank.name.utf8.count), with: Data(bank.name.utf8))
            for (offset, value) in bank.bytes { data[base + offset] = value }
        }
        return data
    }

    private func bytes(film: UInt8, grain: UInt8, chrome: UInt8, blue: UInt8, wb: UInt8, kelvin: UInt16, shift: (Int, UInt8, UInt8),
                       highlight: UInt8, shadow: UInt8, color: UInt8, sharpness: UInt8, noise: UInt8, clarity: UInt8) -> [Int: UInt8] {
        [-394: film, -364: grain, -366: chrome, -365: blue, -511: wb, -613: UInt8(kelvin & 0xFF), -612: UInt8(kelvin >> 8),
         shift.0: shift.1, shift.0 + 2: shift.2, -370: highlight, -368: shadow, -374: color, -372: sharpness, -453: noise, -448: clarity]
    }

    /// The four banks mapped from hardware on firmware 1.30.
    private var hardwareBanks: [(name: String, bytes: [Int: UInt8])] {
        [("perfect summer", bytes(film: 15, grain: 2, chrome: 2, blue: 1, wb: 10, kelvin: 4500, shift: (-485, 3, 16), highlight: 8, shadow: 2, color: 3, sharpness: 6, noise: 0, clarity: 6)),
         ("ronin neg.", bytes(film: 17, grain: 1, chrome: 1, blue: 2, wb: 1, kelvin: 10000, shift: (-505, 7, 14), highlight: 0, shadow: 4, color: 3, sharpness: 4, noise: 4, clarity: 4)),
         ("everyday astia", bytes(film: 2, grain: 1, chrome: 0, blue: 0, wb: 0, kelvin: 10000, shift: (-509, 10, 11), highlight: 6, shadow: 6, color: 6, sharpness: 5, noise: 0, clarity: 6)),
         ("reala stillness", bytes(film: 18, grain: 2, chrome: 2, blue: 1, wb: 10, kelvin: 6700, shift: (-485, 13, 4), highlight: 2, shadow: 6, color: 6, sharpness: 5, noise: 2, clarity: 4))]
    }

    func testDecodesAllFourBanksToWireValues() throws {
        let banks = try XM5BackupDecoder.decode(object(banks: hardwareBanks))
        XCTAssertEqual(banks.map(\.name), ["perfect summer", "ronin neg.", "everyday astia", "reala stillness"])
        XCTAssertTrue(banks.allSatisfy { $0.readErrors.isEmpty })
        let first = banks[0].properties
        XCTAssertEqual(first[0xD192], PTP.u16(11)); XCTAssertEqual(first[0xD195], PTP.u16(6)); XCTAssertEqual(first[0xD199], PTP.u16(0x8007))
        XCTAssertEqual(first[0xD19A], PTP.i16(6)); XCTAssertEqual(first[0xD19B], PTP.i16(-7)); XCTAssertEqual(first[0xD19C], PTP.u16(4500))
        XCTAssertEqual(first[0xD19D], PTP.i16(20)); XCTAssertEqual(first[0xD19E], PTP.i16(-10)); XCTAssertEqual(first[0xD19F], PTP.i16(40))
        XCTAssertEqual(first[0xD1A0], PTP.i16(-20)); XCTAssertEqual(first[0xD1A1], PTP.u16(32768)); XCTAssertEqual(first[0xD1A2], PTP.i16(0))
        let second = banks[1].properties
        XCTAssertNil(second[0xD195], "grain that's on doesn't record its size, so it isn't guessed")
        XCTAssertEqual(second[0xD196], PTP.u16(2)); XCTAssertEqual(second[0xD197], PTP.u16(3)); XCTAssertEqual(second[0xD19E], PTP.i16(0))
    }

    func testUnmappedValuesAreReportedAndLeftOut() throws {
        var banks = hardwareBanks
        banks[0].bytes[-394] = 7
        banks[0].bytes[-511] = 3
        let decoded = try XM5BackupDecoder.decode(object(banks: banks))[0]
        XCTAssertNil(decoded.properties[0xD192]); XCTAssertNil(decoded.properties[0xD199]); XCTAssertNil(decoded.properties[0xD19A])
        XCTAssertNotNil(decoded.readErrors["0xD192"]); XCTAssertNotNil(decoded.readErrors["0xD199"])
        XCTAssertNil(decoded.recipe.settings[.filmSimulation])
    }

    func testRejectsAnythingElse() {
        XCTAssertThrowsError(try XM5BackupDecoder.decode(Data(count: XM5BackupDecoder.size)))
        XCTAssertThrowsError(try XM5BackupDecoder.decode(XM5BackupDecoder.magic))
        var long = object(banks: hardwareBanks)
        long.replaceSubrange(Self.nameOffsets[0]..<(Self.nameOffsets[0] + 40), with: Data(repeating: 0x41, count: 40))
        XCTAssertThrowsError(try XM5BackupDecoder.decode(long))
    }

    func testGrainOffReadBackMatchesWrittenOff() {
        XCTAssertTrue(RecipeWireCodec.equivalent(property: 0xD195, PTP.u16(6), PTP.u16(1)))
        XCTAssertFalse(RecipeWireCodec.equivalent(property: 0xD195, PTP.u16(6), PTP.u16(2)))
        XCTAssertFalse(RecipeWireCodec.equivalent(property: 0xD19C, PTP.u16(6), PTP.u16(1)))
        XCTAssertEqual(RecipeWireCodec.writableValue(property: 0xD195, value: PTP.u16(6)), PTP.u16(1))
    }

    /// Set RECIPEVAULT_BACKUP_FIXTURE and RECIPEVAULT_LIVE_FIXTURE to check a real backup. Those files stay out of the repository.
    func testRealBackupMatchesLiveReads() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let backup = environment["RECIPEVAULT_BACKUP_FIXTURE"], let live = environment["RECIPEVAULT_LIVE_FIXTURE"] else {
            throw XCTSkip("No camera fixture configured.")
        }
        let banks = try XM5BackupDecoder.decode(Data(contentsOf: URL(fileURLWithPath: backup)))
        let truth = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: URL(fileURLWithPath: live)))
        var compared = 0
        for bank in banks {
            let values = try XCTUnwrap(truth[bank.slot == 3 ? "C3-after" : "C\(bank.slot)"])
            XCTAssertEqual(bank.name, values["name"])
            XCTAssertTrue(bank.readErrors.isEmpty)
            for (code, data) in bank.properties {
                let hex = data.map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(hex, values[String(format: "%04X", code)], String(format: "C%d %04X", bank.slot, code))
                compared += 1
            }
        }
        XCTAssertEqual(compared, 54)
    }
}
