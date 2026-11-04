import XCTest
@testable import FujiCore

final class XM5CapabilityTests: XCTestCase {
    private let required: [UInt16] = [0xD16E, 0xD186, 0xD187, 0xD18C, 0xD18D]
    private func device(manufacturer: String = "FUJIFILM", model: String = "X-M5", serial: String = "TEST123", properties: [UInt16]? = nil) -> PTPDeviceInfo {
        PTPDeviceInfo(manufacturer: manufacturer, model: model, deviceVersion: "1.30", serialNumber: serial,
                      operations: [0x1001, 0x1014, 0x1015, 0x1016],
                      properties: properties ?? required + Array(UInt16(0xD18E)...UInt16(0xD1A5)))
    }
    private func profile(_ info: PTPDeviceInfo? = nil) throws -> XM5CapabilityProfile {
        try .resolve(device: info ?? device(), usbMode: PTP.u16(6),
                     condition: PTP.string("X-M5_0100"), compatibility: PTP.string("X-M5_0100"))
    }
    func testResolvesCapabilityGenerationIndependentlyOfDisplayFirmware() throws {
        XCTAssertNoThrow(try profile())
        XCTAssertNoThrow(try profile(device(manufacturer: "FUJIFILM CORPORATION", model: "FUJIFILM X-M5")))
    }
    func testRequiresIdentifiedFujifilmXM5AndAdvertisedIdentityProperties() throws {
        for info in [device(manufacturer: "Other"), device(manufacturer: "NOT FUJIFILM"),
                     device(model: "X-T5"), device(serial: ""), device(serial: " \n ")] {
            XCTAssertThrowsError(try profile(info))
        }
        for omitted in required {
            XCTAssertThrowsError(try profile(device(properties: required.filter { $0 != omitted })))
        }
    }
    func testRejectsUnknownOrMismatchedCapabilityStringsAndUSBMode() throws {
        let valid = try PTP.string("X-M5_0100")
        for invalid in [try PTP.string("X-M5_0130"), try PTP.string("X-M5_0200"),
                        try PTP.string("X-H2_0200"), try PTP.string("X-M5_0100 "), Data(), valid + Data([0]), Data(valid.dropLast())] {
            XCTAssertThrowsError(try XM5CapabilityProfile.resolve(device: device(), usbMode: PTP.u16(6), condition: invalid, compatibility: valid))
            XCTAssertThrowsError(try XM5CapabilityProfile.resolve(device: device(), usbMode: PTP.u16(6), condition: valid, compatibility: invalid))
        }
        for mode in [Data(), Data([6]), PTP.u16(5), PTP.u16(7), PTP.u32(6)] {
            XCTAssertThrowsError(try XM5CapabilityProfile.resolve(device: device(), usbMode: mode, condition: valid, compatibility: valid))
        }
    }
    func testRequiresAdvertisedMappedPropertyAndExactPayloadWidth() throws {
        let p = try profile()
        for code: UInt16 in [0xD16E, 0xD186, 0xD187, 0xD18E, 0xD18F, 0xD198, 0xD1A3, 0xD1A4, 0xD1A5, 0xFFFF] {
            XCTAssertThrowsError(try p.validate(property: code, value: PTP.u16(1)))
        }
        XCTAssertThrowsError(try profile(device(properties: required)).validate(property: 0xD192, value: PTP.u16(11)))
        for code in [UInt16(0xD18C)] + RecipeWireCodec.writeOrder {
            for malformed in [Data(), Data([1]), Data([1, 0, 0]), PTP.u32(1)] {
                XCTAssertThrowsError(try p.validate(property: code, value: malformed))
            }
        }
    }
    func testExactEnumSetsRejectGapsAndReadOnlySentinels() throws {
        let p = try profile()
        let cases: [(UInt16, [Int], [Int])] = [
            (0xD18C, [1, 2, 3, 4], [0, 5, 7, 32768, 65535]),
            (0xD190, [100, 200, 400, 65535], [0, 1, 300, 32768]),
            (0xD191, [0, 1, 2, 32768], [3, 32767, 65535]),
            (0xD192, Array(1...20), [0, 21, 32768, 65535]),
            (0xD195, Array(1...5), [0, 6, 7, 32768, 65535]),
            (0xD196, [1, 2, 3], [0, 4, 32768, 65535]),
            (0xD197, [1, 2, 3], [0, 4, 32768, 65535]),
            (0xD199, [2, 4, 6, 8, 0x8001, 0x8002, 0x8003, 0x8006, 0x8007, 0x8008, 0x8009, 0x800A, 0x8020, 0x8021], [0, 3, 32768, 0x8004, 0x8022, 65535]),
            (0xD1A1, [32768, 28672, 16384, 12288, 8192, 4096, 0, 24576, 20480], [1, 2, 4, 8193, 65535])
        ]
        for (property, accepted, rejected) in cases {
            for value in accepted { XCTAssertNoThrow(try p.validate(property: property, value: PTP.u16(UInt16(value)))) }
            for value in rejected { XCTAssertThrowsError(try p.validate(property: property, value: PTP.u16(UInt16(value)))) }
        }
    }
    func testSignedRangesRequireExactStepsAndRejectUnsetSentinels() throws {
        let p = try profile()
        let ranges: [(UInt16, Int, Int, Int)] = [
            (0xD193, -180, 180, 10), (0xD194, -180, 180, 10),
            (0xD19A, -9, 9, 1), (0xD19B, -9, 9, 1),
            (0xD19D, -20, 40, 5), (0xD19E, -20, 40, 5),
            (0xD19F, -40, 40, 10), (0xD1A0, -40, 40, 10), (0xD1A2, -50, 50, 10)
        ]
        for (property, lower, upper, step) in ranges {
            for value in stride(from: lower, through: upper, by: step) {
                XCTAssertNoThrow(try p.validate(property: property, value: PTP.i16(Int16(value))))
            }
            for value in [lower - 1, upper + 1, -32768, 32767] {
                XCTAssertThrowsError(try p.validate(property: property, value: PTP.i16(Int16(value))))
            }
            if step > 1 { XCTAssertThrowsError(try p.validate(property: property, value: PTP.i16(Int16(lower + 1)))) }
        }
        // 0xFFFF is valid WB shift -1; 0x8000 is valid NR -4 and priority Auto.
        XCTAssertNoThrow(try p.validate(property: 0xD19A, value: PTP.u16(0xFFFF)))
        XCTAssertNoThrow(try p.validate(property: 0xD1A1, value: PTP.u16(0x8000)))
        XCTAssertNoThrow(try p.validate(property: 0xD191, value: PTP.u16(0x8000)))
    }
    func testKelvinUses2500To10000InTenDegreeSteps() throws {
        let p = try profile()
        for value in stride(from: 2500, through: 10000, by: 10) {
            XCTAssertNoThrow(try p.validate(property: 0xD19C, value: PTP.u16(UInt16(value))))
        }
        for value: UInt16 in [0, 2000, 2490, 2501, 5601, 10001, 32768, 65535] {
            XCTAssertThrowsError(try p.validate(property: 0xD19C, value: PTP.u16(value)))
        }
    }
    func testNamesAllowOriginalEmptyNameButRejectUnsafeOrTrailingData() throws {
        let p = try profile()
        for name in ["", "Perfect Summer", "Ronin Neg", "Reality Plus", "Everyday Ace", String(repeating: "A", count: 25), "C1: Film + Grain!"] {
            XCTAssertNoThrow(try p.validate(property: 0xD18D, value: PTP.string(name)))
        }
        XCTAssertNoThrow(try p.validate(property: 0xD18D, value: Data([0])))
        for name in [String(repeating: "A", count: 26), "Café", "Film 🎞", "Line\nBreak", "A\0B", "back`tick"] {
            XCTAssertThrowsError(try p.validate(property: 0xD18D, value: PTP.string(name)))
        }
        let valid = try PTP.string("C1")
        for malformed in [Data(), Data(valid.dropLast()), valid + Data([0])] {
            XCTAssertThrowsError(try p.validate(property: 0xD18D, value: malformed))
        }
    }
}
