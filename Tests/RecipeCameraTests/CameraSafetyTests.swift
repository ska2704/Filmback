import XCTest
import FujiCore
@testable import Filmback

@MainActor
private final class FakeCamera: RecipeCameraTransport {
    var isConnected = true
    var deviceInfo: PTPDeviceInfo?
    var selectorWritten = false
    var settingsObject: Data?
    var objectFetches = 0
    var selectorWrites = 0
    var grainOffReadsSix = false
    var selected = 1
    var slots: [Int: [UInt16:Data]] = [:]
    var savedWrites: [UInt16] = []
    var readOnly: Set<UInt16> = []
    var failWrite: UInt16?
    var ignoreWrite: UInt16?
    var backupPersisted = false
    var wroteBeforeBackup = false
    var leased = false
    var descriptorError: UInt16?
    var globals: [UInt16:Data] = [:]
    var rejectSelector: Set<Int> = []
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
    /// Firmware 1.30 behaviour: every recipe descriptor query returns GeneralError 0x2002.
    func emulateDescriptorStub(generation: String = "X-M5_0100") {
        let info = deviceInfo!
        deviceInfo = PTPDeviceInfo(manufacturer:info.manufacturer,model:info.model,deviceVersion:"1.30",serialNumber:info.serialNumber,operations:info.operations,properties:[0xD16E,0xD186,0xD187] + info.properties)
        descriptorError = 0x2002
        globals = [0xD16E: PTP.u16(6), 0xD186: try! PTP.string(generation), 0xD187: try! PTP.string(generation)]
    }
    func acquireOperation() throws { if leased { throw PTPError.unsupported("busy") }; leased = true }
    func releaseOperation() { leased = false }
    func invalidateSession(reason: String) { isConnected = false; deviceInfo = nil }
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
            if let value = globals[property] { return value }
            guard let value = slots[selected]?[property] else { throw PTPError.response(0x200A) }; return value
        case 0x1014:
            if let descriptorError { throw PTPError.response(descriptorError) }
            let type: UInt16 = property == 0xD18D ? 0xFFFF : 4
            let current = property == 0xD18C ? PTP.u16(UInt16(selected)) : slots[selected]![property]!
            var d = PTP.u16(property); d.append(PTP.u16(type)); d.append(readOnly.contains(property) ? 0 : 1)
            d.append(current); d.append(current); d.append(0); return d
        case 0x1016:
            if property == 0xD18C {
                selectorWrites += 1
                let slot = try PTP.scalar(outData!)
                if rejectSelector.contains(slot) { throw PTPError.response(0x201C) }
                selected = slot; return Data()
            }
            if !backupPersisted { wroteBeforeBackup = true }
            if property == failWrite { throw PTPError.response(0x201C) }
            savedWrites.append(property)
            if property != ignoreWrite {
                slots[selected]![property] = grainOffReadsSix && property == 0xD195 && outData == PTP.u16(1) ? PTP.u16(6) : outData!
            }
            return Data()
        case 0x1008:
            var d = PTP.u32(0x10001); d.append(PTP.u16(0x5000)); d.append(PTP.u16(0)); d.append(PTP.u32(UInt32(settingsObject?.count ?? 0))); return d
        case 0x1009:
            objectFetches += 1
            guard let settingsObject else { throw PTPError.response(0x2009) }; return settingsObject
        default: throw PTPError.response(0x2005)
        }
    }
}

@MainActor
final class CameraSafetyTests: XCTestCase {
    private func unsupportedCamera() -> FakeCamera {
        let camera = FakeCamera()
        let info = camera.deviceInfo!
        camera.deviceInfo = PTPDeviceInfo(manufacturer: info.manufacturer, model: "X-T5", deviceVersion: "2.10", serialNumber: info.serialNumber,
                                          operations: info.operations + [0x1008, 0x1009], properties: info.properties)
        return camera
    }
    func testUnsupportedModelCannotTouchBanks() async throws {
        let camera = unsupportedCamera()
        let service = RecipeCameraService(connection: camera)
        func assertRefused<T>(_ work: () async throws -> T) async {
            do { _ = try await work(); XCTFail("Expected a refusal") }
            catch { XCTAssertTrue("\(error.localizedDescription)".contains("X-T5"), "\(error.localizedDescription)") }
        }
        await assertRefused { try await service.readSlots() }
        await assertRefused { try await service.readAllProperties() }
        await assertRefused { try await service.readFullBackup() }
        await assertRefused { try await service.plan(recipe: Recipe(name: "Test"), slot: 1) }
        await assertRefused { try await service.planCatalog(id: UUID(), name: "Test", recipes: [:]) }
        XCTAssertEqual(camera.selectorWrites, 0)
        XCTAssertEqual(camera.objectFetches, 0)
        XCTAssertEqual(camera.savedWrites, [])
        XCTAssertFalse(camera.leased)
    }
    func testDiagnosticsReportOnlyReadsAndOmitsSerial() async throws {
        let camera = unsupportedCamera()
        let report = try await RecipeCameraService(connection: camera).diagnosticsReport(appVersion: "test")
        XCTAssertTrue(report.contains("Model: X-T5"))
        XCTAssertFalse(report.contains("TEST"))
        XCTAssertEqual(camera.selectorWrites, 0)
        XCTAssertEqual(camera.objectFetches, 0)
        XCTAssertEqual(camera.savedWrites, [])
        XCTAssertFalse(camera.leased)
        XCTAssertFalse(camera.selectorWritten)
    }
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
    func testDescriptorStubUsesResearchedProfileAndStillVerifies() async throws {
        let camera = FakeCamera(); camera.emulateDescriptorStub()
        let service = RecipeCameraService(connection:camera)
        let plan = try await service.plan(recipe:Recipe(name:"Custom",settings:[.clarity:"2"]),slot:3)
        XCTAssertTrue(plan.warnings.contains { $0.contains("X-M5_0100") })
        let report = try await service.apply(plan) { _,_ in camera.backupPersisted = true }
        XCTAssertEqual(report.verifiedProperties,1); XCTAssertEqual(camera.savedWrites,[0xD1A2,0xD18D])
        XCTAssertFalse(camera.wroteBeforeBackup); XCTAssertEqual(camera.selected,1); XCTAssertTrue(camera.isConnected)
    }
    func testDescriptorStubRejectsValuesOutsideResearchedRange() async throws {
        let camera = FakeCamera(); camera.emulateDescriptorStub()
        // Kelvin is inactive under Auto WB, so a restore could not put the stored value back.
        do { _ = try await RecipeCameraService(connection:camera).plan(recipe:Recipe(name:"Warm",settings:[.whiteBalance:"Kelvin",.kelvin:"5600"]),slot:2); XCTFail("Expected recovery refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("cannot restore exactly")) }
        camera.slots[2]![0xD199] = PTP.u16(0x8007); camera.slots[2]![0xD19C] = PTP.u16(5600)
        for kelvin in ["2000","5555"] {
            do { _ = try await RecipeCameraService(connection:camera).plan(recipe:Recipe(name:"Warm",settings:[.whiteBalance:"Kelvin",.kelvin:kelvin]),slot:2); XCTFail("Expected \(kelvin) K refusal") }
            catch { XCTAssertTrue(error.localizedDescription.contains("researched X-M5 range")) }
        }
        XCTAssertTrue(camera.savedWrites.isEmpty); XCTAssertEqual(camera.selected,1)
    }
    func testOtherDescriptorErrorsDoNotFallBackToProfile() async throws {
        let camera = FakeCamera(); camera.emulateDescriptorStub(); camera.descriptorError = 0x2005
        do { _ = try await RecipeCameraService(connection:camera).plan(recipe:Recipe(name:"Custom",settings:[.clarity:"2"]),slot:2); XCTFail("Expected refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("0x2005")) }
        XCTAssertTrue(camera.savedWrites.isEmpty); XCTAssertEqual(camera.selected,1)
    }
    func testUnverifiedCapabilityGenerationRefusesFallbackWrites() async throws {
        let camera = FakeCamera(); camera.emulateDescriptorStub(generation:"X-M5_0200")
        do { _ = try await RecipeCameraService(connection:camera).plan(recipe:Recipe(name:"Custom",settings:[.clarity:"2"]),slot:2); XCTFail("Expected refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not been verified")) }
        XCTAssertTrue(camera.savedWrites.isEmpty)
    }
    func testUnmappedBaselineValueCannotBeOverwritten() async throws {
        let camera = FakeCamera(); camera.emulateDescriptorStub(); camera.slots[2]![0xD192] = PTP.u16(0x8000)
        let service = RecipeCameraService(connection:camera)
        // 0x8000 is what an unloaded bank returns, so no write may be planned from it, even to other fields.
        for settings: [RecipeField:String] in [[.filmSimulation:"Provia"],[.clarity:"2"]] {
            do { _ = try await service.plan(recipe:Recipe(name:"Custom",settings:settings),slot:2); XCTFail("Expected refusal") }
            catch { XCTAssertTrue(error.localizedDescription.contains("placeholder")) }
        }
        XCTAssertTrue(camera.savedWrites.isEmpty)
    }
    func testRestoringBackupWithUnmappedValueIsRefused() async throws {
        let camera = FakeCamera(); camera.emulateDescriptorStub()
        var properties = camera.slots[1]!; properties[0xD192] = PTP.u16(0x8000)
        let backup = CameraSlotSnapshot(slot:1,name:"C1",properties:properties)
        do { _ = try await RecipeCameraService(connection:camera).plan(snapshot:backup,slot:1); XCTFail("Expected refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("cannot be restored exactly")) }
        XCTAssertTrue(camera.savedWrites.isEmpty)
    }
    func testFailedSelectorRestoreRequiresReconnect() async throws {
        let camera = FakeCamera(); camera.rejectSelector = [1]
        do { _ = try await RecipeCameraService(connection:camera).plan(recipe:Recipe(name:"Custom",settings:[.clarity:"2"]),slot:2); XCTFail("Expected unconfirmed selector") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unconfirmed")) }
        XCTAssertFalse(camera.isConnected); XCTAssertNil(camera.deviceInfo); XCTAssertTrue(camera.savedWrites.isEmpty)
    }
    func testUnknownSelectorRefusesAnyBankChange() async throws {
        let camera = FakeCamera(); camera.selected = 0
        do { _ = try await RecipeCameraService(connection:camera).readSlots(); XCTFail("Expected refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unknown slot selector")) }
        XCTAssertEqual(camera.selected,0); XCTAssertTrue(camera.savedWrites.isEmpty); XCTAssertFalse(camera.leased)
    }
    func testSharedTransportPreventsSeparateServicesInterleaving() async throws {
        let camera = FakeCamera(); try camera.acquireOperation()
        do { _ = try await RecipeCameraService(connection:camera).readSlots(); XCTFail("Expected busy refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("busy")) }
        camera.releaseOperation(); XCTAssertTrue(camera.savedWrites.isEmpty)
    }

    // MARK: Reading through the settings object

    private func settingsObjectCamera() -> FakeCamera {
        let camera = FakeCamera()
        let info = camera.deviceInfo!
        camera.deviceInfo = PTPDeviceInfo(manufacturer:info.manufacturer,model:info.model,deviceVersion:info.deviceVersion,serialNumber:info.serialNumber,operations:info.operations + [0x1008,0x1009],properties:[0xD16E] + info.properties)
        camera.globals = [0xD16E: PTP.u16(6)]
        var object = Data(count: XM5BackupDecoder.size)
        object.replaceSubrange(0..<XM5BackupDecoder.magic.count, with: XM5BackupDecoder.magic)
        for (index, offset) in [63_985, 65_009, 66_033, 67_057].enumerated() {
            let name = Data("bank \(index + 1)".utf8)
            object.replaceSubrange(offset..<(offset + name.count), with: name)
            object[offset - 394] = 2
        }
        camera.settingsObject = object
        return camera
    }

    func testReadSlotsUsesSettingsObjectWithoutSwitchingBanks() async throws {
        let camera = settingsObjectCamera(); camera.selected = 3
        let banks = try await RecipeCameraService(connection:camera).readSlots()
        XCTAssertEqual(banks.map(\.name), ["bank 1","bank 2","bank 3","bank 4"])
        XCTAssertEqual(banks[0].recipe.settings[.filmSimulation], "Astia")
        XCTAssertEqual(camera.selectorWrites, 0); XCTAssertEqual(camera.selected, 3); XCTAssertEqual(camera.objectFetches, 1); XCTAssertFalse(camera.leased)
    }
    func testSelectorWriteStopsLaterSettingsObjectFetch() async throws {
        let camera = settingsObjectCamera()
        let service = RecipeCameraService(connection:camera)
        _ = try await service.plan(recipe:Recipe(name:"Custom",settings:[.clarity:"2"]),slot:2)
        XCTAssertTrue(camera.selectorWritten)
        do { _ = try await service.readFullBackup(); XCTFail("Expected refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("reconnect")) }
        let banks = try await service.readSlots()
        XCTAssertEqual(banks.count, 4)
        XCTAssertEqual(camera.objectFetches, 0)
    }
    func testSelectingCurrentBankStillWritesSelector() async throws {
        let camera = FakeCamera(); camera.selected = 2
        _ = try await RecipeCameraService(connection:camera).plan(recipe:Recipe(name:"Custom",settings:[.clarity:"2"]),slot:2)
        XCTAssertGreaterThanOrEqual(camera.selectorWrites, 1); XCTAssertEqual(camera.selected, 2)
    }

    // MARK: Catalogs

    /// Live values read from all four banks on firmware 1.30.
    private func hardwareCamera() -> FakeCamera {
        let camera = FakeCamera(); camera.emulateDescriptorStub()
        let banks: [(String,[UInt16:Int])] = [
            ("perfect summer",[0xD192:11,0xD195:6,0xD196:3,0xD197:2,0xD199:32775,0xD19A:6,0xD19B:-7,0xD19C:4500,0xD19D:20,0xD19E:-10,0xD19F:40,0xD1A0:-20,0xD1A1:32768,0xD1A2:0]),
            ("ronin neg.",[0xD192:19,0xD195:2,0xD196:2,0xD197:3,0xD199:32800,0xD19A:2,0xD19B:-5,0xD19C:10000,0xD19D:-20,0xD19E:0,0xD19F:40,0xD1A0:0,0xD1A1:8192,0xD1A2:-20]),
            ("everyday astia",[0xD192:3,0xD195:2,0xD196:1,0xD197:1,0xD199:2,0xD19A:-1,0xD19B:-2,0xD19C:10000,0xD19D:10,0xD19E:10,0xD19F:10,0xD1A0:-10,0xD1A1:32768,0xD1A2:0]),
            ("reala stillness",[0xD192:20,0xD195:6,0xD196:3,0xD197:2,0xD199:32775,0xD19A:-4,0xD19B:5,0xD19C:6700,0xD19D:-10,0xD19E:10,0xD19F:10,0xD1A0:-10,0xD1A1:16384,0xD1A2:-20])]
        for (index, bank) in banks.enumerated() {
            var values = camera.slots[index + 1]!
            values[0xD18D] = try! PTP.string(bank.0)
            values[0xD190] = PTP.u16(400); values[0xD18E] = PTP.u16(7); values[0xD18F] = PTP.u16(2)
            values[0xD198] = PTP.u16(1); values[0xD1A3] = PTP.u16(1); values[0xD1A4] = PTP.u16(1)
            for (code, value) in bank.1 { values[code] = PTP.u16(UInt16(truncatingIfNeeded: value)) }
            camera.slots[index + 1] = values
        }
        camera.selected = 3
        return camera
    }

    func testCatalogOfCurrentBanksPlansNoChanges() async throws {
        let camera = hardwareCamera(); let service = RecipeCameraService(connection:camera)
        let banks = try await service.readAllProperties()
        let plan = try await service.planCatalog(id:UUID(),name:"Now",recipes:Dictionary(uniqueKeysWithValues:banks.map { ($0.slot,$0.recipe) }))
        XCTAssertEqual(plan.changeCount, 0, plan.plans.flatMap { $0.writes.map(\.label) }.joined(separator:", "))
        XCTAssertTrue(camera.savedWrites.isEmpty); XCTAssertEqual(camera.selected, 3)
    }
    func testCatalogLoadsEveryBankOnceAndVerifies() async throws {
        let camera = hardwareCamera(); let service = RecipeCameraService(connection:camera)
        var recipes: [Int:Recipe] = [:]
        for slot in 1...4 { recipes[slot] = Recipe(name:"Outing \(slot)",settings:[.filmSimulation:"Provia",.highlight:"-1.5",.grainRoughness:"Off"]) }
        let plan = try await service.planCatalog(id:UUID(),name:"Outing",recipes:recipes)
        var backups = 0
        let reports = try await service.applyAll(plan.plans) { snapshots,_ in
            XCTAssertEqual(snapshots.map(\.slot),[1,2,3,4]); backups += 1; camera.backupPersisted = true
        }
        XCTAssertEqual(backups, 1); XCTAssertFalse(camera.wroteBeforeBackup); XCTAssertEqual(reports.map(\.slot),[1,2,3,4])
        for slot in 1...4 {
            XCTAssertEqual(camera.slots[slot]![0xD192], PTP.u16(1)); XCTAssertEqual(camera.slots[slot]![0xD19D], PTP.i16(-15))
            XCTAssertEqual(camera.slots[slot]![0xD18D], try PTP.string("Outing \(slot)"))
        }
        XCTAssertEqual(camera.selected, 3, "the selection is restored"); XCTAssertFalse(camera.leased)
    }
    func testCatalogNeedsFourRecipes() async throws {
        let camera = hardwareCamera()
        do { _ = try await RecipeCameraService(connection:camera).planCatalog(id:UUID(),name:"Short",recipes:[1:Recipe(name:"One")]); XCTFail("Expected refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("each of C1")) }
        XCTAssertEqual(camera.selectorWrites, 0)
    }
    func testCatalogFailureNamesFinishedBanksAndRestoresSelection() async throws {
        let camera = hardwareCamera(); let service = RecipeCameraService(connection:camera)
        let plan = try await service.planCatalog(id:UUID(),name:"Mixed",recipes:[1:Recipe(name:"perfect summer",settings:[.clarity:"2"]),2:Recipe(name:"ronin neg.",settings:[.sharpness:"3"]),3:Recipe(name:"everyday astia"),4:Recipe(name:"reala stillness")])
        camera.failWrite = 0xD1A0
        do { _ = try await service.applyAll(plan.plans) { _,_ in camera.backupPersisted = true }; XCTFail("Expected failure") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("C2 write stopped"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("already changed: C1"), error.localizedDescription)
        }
        XCTAssertEqual(camera.savedWrites,[0xD1A2]); XCTAssertEqual(camera.selected, 3); XCTAssertTrue(camera.isConnected)
    }
    func testStaleCatalogWritesNothing() async throws {
        let camera = hardwareCamera(); let service = RecipeCameraService(connection:camera)
        let plan = try await service.planCatalog(id:UUID(),name:"Stale",recipes:[1:Recipe(name:"a",settings:[.clarity:"2"]),2:Recipe(name:"b"),3:Recipe(name:"c"),4:Recipe(name:"d")])
        camera.slots[4]![0xD1A2] = PTP.i16(30)
        do { _ = try await service.applyAll(plan.plans) { _,_ in XCTFail("Must not back up or write") }; XCTFail("Expected stale refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertTrue(camera.savedWrites.isEmpty)
    }
    func testKelvinRecipeLoadsOntoAutoBankAndCanBeRestored() async throws {
        let camera = hardwareCamera(); let service = RecipeCameraService(connection:camera)
        let before = try await service.readAllProperties().first { $0.slot == 3 }!
        let plan = try await service.plan(recipe:Recipe(name:"everyday astia",settings:[.whiteBalance:"Kelvin",.kelvin:"5600"]),slot:3)
        XCTAssertEqual(plan.writes.map(\.property),[0xD199,0xD19C])
        _ = try await service.apply(plan) { _,_ in camera.backupPersisted = true }
        XCTAssertEqual(camera.slots[3]![0xD19C], PTP.u16(5600))
        let restore = try await service.plan(snapshot:before,slot:3)
        XCTAssertEqual(restore.writes.map(\.property),[0xD199,0xD19A,0xD19B],"the unused Kelvin value isn't written, and shift follows the mode")
        _ = try await service.apply(restore) { _,_ in }
        XCTAssertEqual(camera.slots[3]![0xD199], PTP.u16(2)); XCTAssertEqual(camera.slots[3]![0xD19A], PTP.i16(-1))
    }
    func testDynamicRangeAutoUsesTheValueThisCameraStores() async throws {
        let camera = hardwareCamera(); let service = RecipeCameraService(connection:camera)
        // Value read from a bank set to DR Auto on the camera. The camera refused 0.
        let plan = try await service.plan(recipe:Recipe(name:"reala stillness",settings:[.dynamicRange:"DR-Auto"]),slot:4)
        XCTAssertEqual(plan.writes.map(\.data),[PTP.u16(0xFFFF)])
        _ = try await service.apply(plan) { _,_ in camera.backupPersisted = true }
        XCTAssertEqual(camera.slots[4]![0xD190], PTP.u16(0xFFFF))
        // A bank on DR Auto reads as that recipe, can be changed, and plans no change against itself.
        let banks = try await service.readAllProperties()
        XCTAssertEqual(banks[3].recipe.settings[.dynamicRange], "DR-Auto")
        let same = try await service.plan(recipe:banks[3].recipe,slot:4)
        XCTAssertTrue(same.writes.isEmpty)
        let back = try await service.plan(recipe:Recipe(name:"reala stillness",settings:[.dynamicRange:"DR400"]),slot:4)
        XCTAssertEqual(back.writes.map(\.data),[PTP.u16(400)])
        // Restoring a saved bank on DR Auto writes the same value.
        _ = try await service.apply(back) { _,_ in }
        let restore = try await service.plan(snapshot:banks[3],slot:4)
        XCTAssertEqual(restore.writes.map(\.data),[PTP.u16(0xFFFF)]); XCTAssertEqual(restore.writes.first?.displayValue,"DR-Auto")
    }
    func testDynamicRangePlaceholderUnderPriorityIsNotDynamicRangeAuto() {
        let bank = CameraSlotSnapshot(slot:1,name:"x",properties:[0xD191:PTP.u16(1),0xD190:PTP.u16(0xFFFF),0xD192:PTP.u16(3)])
        XCTAssertNil(bank.recipe.settings[.dynamicRange])
    }
    func testRefusedDynamicRangeExplainsISOAndOnlyNamesBanksThatChanged() async throws {
        let camera = hardwareCamera(); camera.slots[4]![0xD190] = PTP.u16(0xFFFF)
        let service = RecipeCameraService(connection:camera)
        // C1–C3 have nothing to write, as in the First Four load refused on 4 November.
        let banks = try await service.readAllProperties()
        var recipes = Dictionary(uniqueKeysWithValues:banks.map { ($0.slot,$0.recipe) })
        recipes[4]!.settings[.dynamicRange] = "DR400"
        let plan = try await service.planCatalog(id:UUID(),name:"First Four",recipes:recipes)
        XCTAssertTrue(plan.plans[3].warnings.contains { $0.contains("ISO 640") }, plan.plans[3].warnings.joined())
        XCTAssertFalse(plan.plans[0].warnings.contains { $0.contains("ISO 640") }, "a bank whose dynamic range isn't changing gets no ISO warning")
        camera.failWrite = 0xD190
        do { _ = try await service.applyAll(plan.plans) { _,_ in camera.backupPersisted = true }; XCTFail("Expected refusal") }
        catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("needs ISO 640"), text)
            XCTAssertTrue(text.contains("No other banks were changed"), text)
            XCTAssertFalse(text.contains("already changed"), text)
        }
        XCTAssertEqual(camera.selected, 3); XCTAssertTrue(camera.savedWrites.isEmpty)
    }
    func testChangingWhiteBalanceAlwaysWritesAndVerifiesItsShift() async throws {
        let camera = hardwareCamera(); let service = RecipeCameraService(connection:camera)
        // C3 is Auto with -1/-2. The same numbers on Kelvin are a different stored pair.
        let plan = try await service.plan(recipe:Recipe(name:"everyday astia",settings:[.whiteBalance:"Kelvin",.kelvin:"5600",.wbShiftR:"-1",.wbShiftB:"-2"]),slot:3)
        XCTAssertEqual(plan.writes.map(\.property),[0xD199,0xD19C,0xD19A,0xD19B])
        let same = try await service.plan(recipe:Recipe(name:"everyday astia",settings:[.whiteBalance:"Auto",.wbShiftR:"-1",.wbShiftB:"-2"]),slot:3)
        XCTAssertTrue(same.writes.isEmpty)
    }
    func testRestoreSkipsValuesItsModesIgnore() async throws {
        let camera = hardwareCamera(); let service = RecipeCameraService(connection:camera)
        var saved = camera.slots[3]!
        saved[0xD191] = PTP.u16(1); saved[0xD190] = PTP.u16(200); saved[0xD19D] = PTP.i16(30); saved[0xD193] = PTP.i16(10); saved[0xD19C] = PTP.u16(5000)
        let plan = try await service.plan(snapshot:CameraSlotSnapshot(slot:3,name:"everyday astia",properties:saved),slot:3)
        XCTAssertEqual(plan.writes.map(\.property),[0xD191])
    }
    func testIncompleteBackupIsRefusedAndPartialOneWarns() async throws {
        let camera = hardwareCamera(); let service = RecipeCameraService(connection:camera)
        do { _ = try await service.plan(snapshot:CameraSlotSnapshot(slot:3,name:"x",properties:[:],readErrors:["0xD192":"failed"]),slot:3); XCTFail("Expected refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("every value")) }
        let partial = try await service.plan(snapshot:CameraSlotSnapshot(slot:3,name:"everyday astia",properties:[0xD1A2:PTP.i16(0)]),slot:3)
        XCTAssertTrue(partial.warnings.contains { $0.contains("missing") })
    }
    func testVerificationReportsSettingsThatChangedWithoutBeingWritten() async throws {
        let camera = hardwareCamera(); let service = RecipeCameraService(connection:camera)
        let plan = try await service.planCatalog(id:UUID(),name:"Clean",recipes:[1:Recipe(name:"perfect summer",settings:[.clarity:"2"]),2:Recipe(name:"ronin neg."),3:Recipe(name:"everyday astia"),4:Recipe(name:"reala stillness")])
        let reports = try await service.applyAll(plan.plans) { _,_ in camera.backupPersisted = true
            camera.slots[4]![0xD1A0] = PTP.i16(30)
        }
        XCTAssertEqual(reports.first { $0.slot == 4 }?.unexpected, ["C4: Sharpness"], "a bank marked No change is still checked")
        XCTAssertEqual(reports.first { $0.slot == 1 }?.unexpected, [])
    }
    func testPlaceholderValuesAreRecognised() {
        XCTAssertTrue(CameraSlotSnapshot(slot:1,name:"",properties:[0xD192:PTP.u16(0x8000)]).holdsPlaceholders)
        XCTAssertFalse(CameraSlotSnapshot(slot:1,name:"",properties:[0xD192:PTP.u16(3),0xD190:PTP.u16(0xFFFF)]).holdsPlaceholders)
        XCTAssertFalse(CameraSlotSnapshot(slot:1,name:"",properties:[0xD192:PTP.u16(3),0xD191:PTP.u16(0x8000)]).holdsPlaceholders)
    }
    func testGrainReadingSixCanBeChangedAndOffVerifies() async throws {
        let camera = hardwareCamera(); camera.grainOffReadsSix = true
        let service = RecipeCameraService(connection:camera)
        let noChange = try await service.plan(recipe:Recipe(name:"perfect summer",settings:[.grainRoughness:"Off"]),slot:1)
        XCTAssertTrue(noChange.writes.isEmpty)
        let weak = try await service.plan(recipe:Recipe(name:"perfect summer",settings:[.grainRoughness:"Weak",.grainSize:"Small"]),slot:1)
        XCTAssertEqual(weak.writes.first?.data, PTP.u16(2))
        _ = try await service.apply(weak) { _,_ in camera.backupPersisted = true }
        let off = try await service.plan(recipe:Recipe(name:"perfect summer",settings:[.grainRoughness:"Off"]),slot:1)
        XCTAssertEqual(off.writes.first?.data, PTP.u16(1), "6 is never written")
        _ = try await service.apply(off) { _,_ in }
        XCTAssertEqual(camera.slots[1]![0xD195], PTP.u16(6))
    }
    func testCatalogFileUsesBankNumbersOrOrderAndNeedsFour() throws {
        let numbered = [4,3,2,1].map { (slot: Int) in Recipe(name:"r\(slot)",suggestedSlot:slot) }
        XCTAssertEqual(try CatalogFile.slots(from:numbered).first { $0.slot == 1 }?.recipe.name, "r1")
        let plain = ["a","b","c","d"].map { Recipe(name:$0) }
        XCTAssertEqual(try CatalogFile.slots(from:plain).map(\.slot),[1,2,3,4])
        XCTAssertThrowsError(try CatalogFile.slots(from:Array(plain.prefix(3))))
    }
}
