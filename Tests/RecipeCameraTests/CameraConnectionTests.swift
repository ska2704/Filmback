import XCTest
import FujiCore
@testable import RecipeVault

@MainActor
final class CameraConnectionTests: XCTestCase {
    private func response(code: UInt16, transaction: UInt32 = 42) -> Data {
        var data = PTP.u32(12)
        data.append(PTP.u16(3))
        data.append(PTP.u16(code))
        data.append(PTP.u32(transaction))
        return data
    }

    func testValidImageCaptureCoreResponseRetainsFrameworkTransactionSemantics() async throws {
        let camera = CameraConnection()
        let status = camera.status
        try camera.validateCommandCompletion(response: response(code: 0x2001, transaction: 999), error: nil)
        XCTAssertEqual(camera.status, status)
    }

    func testWellFormedPTPRejectionDoesNotInvalidateSession() async throws {
        let camera = CameraConnection()
        let status = camera.status
        XCTAssertThrowsError(try camera.validateCommandCompletion(response: response(code: 0x200A), error: nil)) { error in
            guard case PTPError.response(let code) = error else { return XCTFail("Expected the camera's PTP rejection") }
            XCTAssertEqual(code, 0x200A)
        }
        XCTAssertEqual(camera.status, status)
    }

    func testTransportFailureRequiresReconnectEvenWithSuccessResponse() async throws {
        let camera = CameraConnection()
        let failure = NSError(domain: "CameraTransportFixture", code: 123)
        XCTAssertThrowsError(try camera.validateCommandCompletion(response: response(code: 0x2001), error: failure)) { error in
            XCTAssertEqual(error as NSError, failure)
        }
        XCTAssertFalse(camera.isConnected)
        XCTAssertNil(camera.deviceInfo)
        XCTAssertTrue(camera.status.contains("reconnect"))
        do {
            _ = try await camera.command(0x1016, parameters: [0xD192], outData: PTP.u16(11))
            XCTFail("A failed transport must not send a subsequent write")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Connect the camera")) }
    }

    func testMalformedRejectionRequiresReconnect() async throws {
        let camera = CameraConnection()
        var malformed = response(code: 0x200A)
        malformed[0] = 16
        XCTAssertThrowsError(try camera.validateCommandCompletion(response: malformed, error: nil)) { error in
            guard case PTPError.malformed = error else { return XCTFail("Malformed framing must not become a recoverable rejection") }
        }
        XCTAssertFalse(camera.isConnected)
        XCTAssertNil(camera.deviceInfo)
        XCTAssertTrue(camera.status.contains("reconnect"))
    }
}
