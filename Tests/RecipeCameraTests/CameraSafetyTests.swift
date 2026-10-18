import XCTest
import FujiCore
@testable import RecipeVault

@MainActor
private final class FakeCamera: RecipeCameraTransport {
    var isConnected = true
    var deviceInfo: PTPDeviceInfo?
    var selected = 1
    var slots: [Int: [UInt16:Data]] = [:]
    var savedWrites: [UInt16] = []
    var readOnly: Set<UInt16> = []
    var failWrite: UInt16?
    var ignoreWrite: UInt16?
    var backupPersisted = false
    var wroteBeforeBackup = false
    var leased = false
    init() {
        deviceInfo = PTPDeviceInfo(manufacturer:"FUJIFILM",model:"X-M5",deviceVersion:"1.00",serialNumber:"TEST",operations:[0x1001,0x1014,0x1015,0x1016],properties:Array(0xD18C...0xD1A4))
        for slot in 1...4 {
            var values: [UInt16:Data] = [:]
            for code in UInt16(0xD18E)...UInt16(0xD1A4) { values[code] = PTP.u16(0) }
            values[0xD18D] = try! PTP.string("C\(slot)")
            values[0xD192] = PTP.u16(11); values[0xD199] = PTP.u16(2); values[0xD195] = PTP.u16(1)
            slots[slot] = values
        }
    }
    func acquireOperation() throws { if leased { throw PTPError.unsupported("busy") }; leased = true }
    func releaseOperation() { leased = false }
    func command(_ operation: UInt16, parameters: [UInt32], outData: Data?) async throws -> Data {
        let property = UInt16(parameters.first ?? 0)
        switch operation {
        case 0x1001:
            let info = deviceInfo!
            var d = PTP.u16(100); d.append(PTP.u32(0)); d.append(PTP.u16(100)); d.append(try PTP.string("")); d.append(PTP.u16(0))
            for list in [info.operations,[],info.properties,[],[]] { d.append(PTP.u32(UInt32(list.count))); list.forEach { d.append(PTP.u16($0)) } }
            for text in [info.manufacturer,info.model,info.deviceVersion,info.serialNumber] { d.append(try PTP.string(text)) }; return d
        case 0x1015:
            if property == 0xD18C { return PTP.u16(UInt16(selected)) }
            guard let value = slots[selected]?[property] else { throw PTPError.response(0x200A) }; return value
        case 0x1014:
            let type: UInt16 = property == 0xD18D ? 0xFFFF : 4
            let current = property == 0xD18C ? PTP.u16(UInt16(selected)) : slots[selected]![property]!
            var d = PTP.u16(property); d.append(PTP.u16(type)); d.append(readOnly.contains(property) ? 0 : 1)
            d.append(current); d.append(current); d.append(0); return d
        case 0x1016:
            if property == 0xD18C { selected = try PTP.scalar(outData!); return Data() }
            if !backupPersisted { wroteBeforeBackup = true }
            if property == failWrite { throw PTPError.response(0x201C) }
            savedWrites.append(property)
            if property != ignoreWrite { slots[selected]![property] = outData! }
            return Data()
        default: throw PTPError.response(0x2005)
        }
    }
}

@MainActor
final class CameraSafetyTests: XCTestCase {
    func testPersistenceFailurePreventsRecipeMutation() async throws {
        let camera = FakeCamera()
        let tested = RecipeCameraService(connection:camera)
        let plan = try await tested.plan(recipe:Recipe(name:"New",settings:[.clarity:"2"]),slot:2)
        do {
            _ = try await tested.apply(plan) { _,_ in throw PTPError.unsupported("disk full") }
            XCTFail("Expected failed backup")
        } catch { XCTAssertTrue(error.localizedDescription.contains("disk full")) }
        XCTAssertTrue(camera.savedWrites.isEmpty); XCTAssertFalse(camera.wroteBeforeBackup); XCTAssertEqual(camera.selected,1); XCTAssertFalse(camera.leased)
    }
    func testSuccessfulWritePersistsEveryBankAndVerifies() async throws {
        let camera = FakeCamera()
        let tested = RecipeCameraService(connection:camera)
        let plan = try await tested.plan(recipe:Recipe(name:"Custom",settings:[.clarity:"2"]),slot:3)
        let report = try await tested.apply(plan) { slots,info in
            XCTAssertEqual(slots.map(\.slot),[1,2,3,4]); XCTAssertEqual(info.model,"X-M5"); camera.backupPersisted = true
        }
        XCTAssertEqual(report.verifiedProperties,1); XCTAssertEqual(report.snapshot.name,"Custom")
        XCTAssertEqual(camera.savedWrites,[0xD1A2,0xD18D]); XCTAssertFalse(camera.wroteBeforeBackup); XCTAssertEqual(camera.selected,1)
    }
    func testStalePlanRejectedBeforePersistenceOrWrite() async throws {
        let camera = FakeCamera(); let service = RecipeCameraService(connection:camera)
        let plan = try await service.plan(recipe:Recipe(name:"Custom",settings:[.clarity:"2"]),slot:1)
        camera.slots[1]![0xD1A2] = PTP.i16(30)
        do { _ = try await service.apply(plan) { _,_ in XCTFail("Stale plan must not persist or write") }; XCTFail("Expected stale plan") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertTrue(camera.savedWrites.isEmpty)
    }
    func testUnsupportedDescriptorBlocksPlanning() async throws {
        let camera = FakeCamera(); camera.readOnly.insert(0xD1A2)
        do { _ = try await RecipeCameraService(connection:camera).plan(recipe:Recipe(name:"Custom",settings:[.clarity:"2"]),slot:1); XCTFail("Expected read-only refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("read-only")) }
        XCTAssertTrue(camera.savedWrites.isEmpty)
    }
    func testMidWriteFailureReportsPartialStateAndKeepsBackup() async throws {
        let camera = FakeCamera(); let service = RecipeCameraService(connection:camera)
        let plan = try await service.plan(recipe:Recipe(name:"Custom",settings:[.sharpness:"2",.clarity:"2"]),slot:1)
        camera.failWrite = 0xD1A2
        do { _ = try await service.apply(plan) { _,_ in camera.backupPersisted = true }; XCTFail("Expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("0xD1A0")); XCTAssertTrue(error.localizedDescription.contains("stopped")) }
        XCTAssertEqual(camera.savedWrites,[0xD1A0]); XCTAssertTrue(camera.backupPersisted); XCTAssertFalse(camera.wroteBeforeBackup)
    }
    func testAcceptedButIgnoredWriteFailsVerification() async throws {
        let camera = FakeCamera(); let service = RecipeCameraService(connection:camera)
        let plan = try await service.plan(recipe:Recipe(name:"C1",settings:[.clarity:"2"]),slot:1)
        camera.ignoreWrite = 0xD1A2
        do { _ = try await service.apply(plan) { _,_ in camera.backupPersisted = true }; XCTFail("Expected read-back mismatch") }
        catch { XCTAssertTrue(error.localizedDescription.contains("verification")) }
    }
    func testLiveStateWriteIsRefusedEvenInConstructedPlan() async throws {
        let camera = FakeCamera(); let service = RecipeCameraService(connection:camera)
        let initial = try await service.plan(recipe:Recipe(name:"C1",settings:[:]),slot:1)
        let evil = RecipeWritePlan(slot:1,name:"C1",writes:[PTPPropertyWrite(property:0xD1A5,data:PTP.u16(7),label:"Live",displayValue:"7")],before:initial.before,warnings:[],device:initial.device)
        do { _ = try await service.apply(evil) { _,_ in camera.backupPersisted = true }; XCTFail("Expected refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("live-state")) }
        XCTAssertTrue(camera.savedWrites.isEmpty)
    }
    func testSharedTransportPreventsSeparateServicesInterleaving() async throws {
        let camera = FakeCamera(); try camera.acquireOperation()
        do { _ = try await RecipeCameraService(connection:camera).readSlots(); XCTFail("Expected busy refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("busy")) }
        camera.releaseOperation(); XCTAssertTrue(camera.savedWrites.isEmpty)
    }
}
