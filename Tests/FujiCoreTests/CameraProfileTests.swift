import XCTest
@testable import FujiCore

final class CameraProfileTests: XCTestCase {
    private func device(model: String = "X-T5", serial: String = "SECRET123", operations: [UInt16] = [0x1001, 0x1015], properties: [UInt16] = [0x5001, 0xD186, 0xD18C, 0xD192]) -> PTPDeviceInfo {
        PTPDeviceInfo(manufacturer: "FUJIFILM", model: model, deviceVersion: "2.10", serialNumber: serial, operations: operations, properties: properties)
    }

    func testOnlyVerifiedModelsHaveAProfile() {
        XCTAssertEqual(CameraProfile.matching(device(model: "X-M5"))?.name, "X-M5")
        XCTAssertEqual(CameraProfile.matching(device(model: "FUJIFILM X-M5"))?.bankCount, 4)
        for model in ["X-T5", "X-S20", "X-M50", "GFX100S", ""] { XCTAssertNil(CameraProfile.matching(device(model: model)), model) }
    }

    func testReadsOnlyAdvertisedRecipeProperties() {
        XCTAssertEqual(CameraDiagnostics.propertiesToRead(for: device()), [0xD186, 0xD18C, 0xD192])
        XCTAssertEqual(CameraDiagnostics.propertiesToRead(for: device(operations: [0x1001])), [])
    }

    func testReportNeverContainsTheSerialNumber() throws {
        let values: [UInt16: Data] = [
            0xD186: try PTP.string("X-T5_0100"),
            0xD18C: PTP.u16(1),
            0xD18D: try PTP.string("has SECRET123 inside"),
            0xD192: Data("xxSECRET123xx".utf8)
        ]
        let report = CameraDiagnostics.report(device: device(), values: values, errors: [0xD193: "refused"], appVersion: "0.7.0")
        XCTAssertFalse(report.contains("SECRET123"))
        for hex in [Data("SECRET123".utf8), "SECRET123".data(using: .utf16LittleEndian)!].map({ $0.map { String(format: "%02X", $0) }.joined(separator: " ") }) {
            XCTAssertFalse(report.contains(hex))
        }
        XCTAssertTrue(report.contains("Model: X-T5"))
        XCTAssertTrue(report.contains("“X-T5_0100”"))
        XCTAssertTrue(report.contains("0xD193: error, refused"))
        XCTAssertTrue(report.contains("not supported yet"))
    }
}
