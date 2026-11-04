import Foundation
import FujiCore

@MainActor
protocol RecipeCameraTransport: AnyObject {
    var isConnected: Bool { get }
    var deviceInfo: PTPDeviceInfo? { get }
    /// Set once a bank selector write is sent. GetObject stalled the camera's USB after selector writes,
    /// so the settings object is not fetched again until the USB session is reopened.
    var selectorWritten: Bool { get set }
    func acquireOperation() throws
    func releaseOperation()
    func invalidateSession(reason: String)
    func command(_ operation: UInt16, parameters: [UInt32], outData: Data?) async throws -> Data
}

extension RecipeCameraTransport {
    func command(_ operation: UInt16, parameters: [UInt32] = []) async throws -> Data {
        try await command(operation, parameters: parameters, outData: nil)
    }
}

struct RecipeWritePlan: Identifiable {
    let id = UUID()
    let slot: Int
    let name: String
    let writes: [PTPPropertyWrite]
    let before: CameraSlotSnapshot
    let warnings: [String]
    let device: PTPDeviceInfo
}

struct CatalogWritePlan: Identifiable {
    let id = UUID()
    let catalogID: UUID
    let catalogName: String
    let plans: [RecipeWritePlan]
    var changeCount: Int { plans.reduce(0) { $0 + $1.writes.count + ($1.name != $1.before.name ? 1 : 0) } }
}

struct RecipeWriteReport {
    let slot: Int
    let verifiedProperties: Int
    let snapshot: CameraSlotSnapshot
    let warnings: [String]
    var unexpected: [String] = []
}

@MainActor
final class RecipeCameraService {
    let connection: any RecipeCameraTransport
    private var busy = false
    private var capabilityProfile: XM5CapabilityProfile?
    init(connection: any RecipeCameraTransport) { self.connection = connection }

    private func begin() throws -> PTPDeviceInfo {
        guard !busy else { throw PTPError.unsupported("Wait for the current camera operation to finish.") }
        guard connection.isConnected, let info = connection.deviceInfo, info.isXM5 else { throw PTPError.unsupported("Connect your X-M5 first.") }
        try connection.acquireOperation()
        busy = true; capabilityProfile = nil; return info
    }
    private func get(_ code: UInt16) async throws -> Data { try await connection.command(0x1015, parameters: [UInt32(code)]) }
    private func set(_ code: UInt16, _ data: Data) async throws { _ = try await connection.command(0x1016, parameters: [UInt32(code)], outData: data) }
    private func profile() async throws -> XM5CapabilityProfile {
        if let capabilityProfile { return capabilityProfile }
        guard let info = connection.deviceInfo,
              [UInt16(0xD16E), 0xD186, 0xD187].allSatisfy(info.properties.contains) else {
            throw PTPError.unsupported("The camera cannot identify a supported recipe capability profile.")
        }
        let resolved = try XM5CapabilityProfile.resolve(device: info, usbMode: await get(0xD16E),
            condition: await get(0xD186), compatibility: await get(0xD187))
        capabilityProfile = resolved
        return resolved
    }
    private func validate(_ code: UInt16, _ value: Data) async throws {
        guard let info = connection.deviceInfo, info.properties.contains(code),
              code == 0xD18C || code == 0xD18D || RecipeWireCodec.writableProperties.contains(code) else {
            throw PTPError.unsupported("Unknown or live-state write refused.")
        }
        let raw: Data
        do { raw = try await connection.command(0x1014, parameters: [UInt32(code)]) }
        catch PTPError.response(0x2002) {
            // This exact response is the documented Fujifilm descriptor stub. All other errors stop.
            try await profile().validate(property: code, value: value)
            return
        }
        let descriptor = try PTPPropertyDescriptor.parse(raw)
        guard descriptor.code == code else { throw PTPError.malformed("descriptor property mismatch") }
        try descriptor.validate(value)
    }
    private func select(_ slot: Int) async throws {
        guard (1...4).contains(slot) else { throw PTPError.unsupported("X-M5 has C1–C4. No other slot will be accessed.") }
        let payload = PTP.u16(UInt16(slot))
        // Always write: after a power cycle the selector can already read 1 while the live
        // properties still hold placeholders, and writing it is what loads the bank.
        try await validate(0xD18C, payload)
        connection.selectorWritten = true
        try await set(0xD18C, payload)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard try await get(0xD18C) == payload else { throw PTPError.changed("Camera did not confirm the selected custom bank.") }
    }
    private func restoreSelector(_ original: Int) async throws {
        guard connection.isConnected else { throw PTPError.changed("Camera disconnected before the original bank selector could be verified.") }
        try await select(original)
        guard try await get(0xD18C) == PTP.u16(UInt16(original)) else {
            throw PTPError.changed("The original bank selector could not be verified.")
        }
    }
    private func preservingSelector<T>(_ operation: () async throws -> T) async throws -> T {
        let old = try await PTP.scalar(get(0xD18C))
        guard (1...4).contains(old) else { throw PTPError.unsupported("Camera returned an unknown slot selector (\(old)); no bank will be changed.") }
        let result: T
        do { result = try await operation() }
        catch {
            let originalError = error
            do { try await restoreSelector(old) }
            catch {
                let reason = "\(originalError.localizedDescription) Original bank selection is unconfirmed: \(error.localizedDescription) Reconnect and check the camera before continuing."
                connection.invalidateSession(reason: reason)
                throw PTPError.changed(reason)
            }
            throw originalError
        }
        do { try await restoreSelector(old) }
        catch {
            let reason = "Original bank selection is unconfirmed: \(error.localizedDescription) Reconnect and check the camera before continuing."
            connection.invalidateSession(reason: reason)
            throw PTPError.changed(reason)
        }
        return result
    }
    /// A change is allowed only if the bank's current raw value could be written back from the backup.
    private func validateRecovery(writes: [PTPPropertyWrite], name: String, before: CameraSlotSnapshot) async throws {
        for write in writes where !RecipeWireCodec.equivalent(property: write.property, before.properties[write.property], write.data) {
            func refusal(_ reason: String = "") -> PTPError {
                PTPError.unsupported("C\(before.slot) has a value for \(write.label) that RecipeVault cannot restore exactly. \(reason) No recipe settings will be written. Preserve it with Fujifilm Tether App and choose a bank with understood settings before trying again.")
            }
            guard let original = before.properties[write.property] else { throw refusal() }
            do { try await validate(write.property, RecipeWireCodec.writableValue(property: write.property, value: original)) }
            catch PTPError.unsupported(let reason) { throw refusal(reason) }
        }
        if name != before.name, !before.name.isEmpty, PTP.safeName(before.name) != before.name {
            throw PTPError.unsupported("The original C\(before.slot) name cannot be restored exactly by RecipeVault. No recipe settings will be written.")
        }
    }
    private func readSlot(_ slot: Int, info: PTPDeviceInfo) async throws -> CameraSlotSnapshot {
        try await select(slot)
        var nameReader = PTPReader(try await get(0xD18D)); let name = try nameReader.string()
        var properties: [UInt16:Data] = [:], errors: [String:String] = [:]
        for code in UInt16(0xD18E)...UInt16(0xD1A4) where info.properties.contains(code) {
            do { properties[code] = try await get(code) }
            catch {
                errors[String(format:"0x%04X",code)] = error.localizedDescription
                if !connection.isConnected { throw error }
            }
        }
        guard properties[0xD192] != nil else { throw PTPError.unsupported("The camera did not return a film simulation for C\(slot). No write is available.") }
        let snapshot = CameraSlotSnapshot(slot: slot, name: name, properties: properties, readErrors: errors)
        guard !snapshot.holdsPlaceholders else { throw PTPError.unsupported("C\(slot) returned placeholder values instead of its recipe. Nothing was changed. Turn the camera off, reconnect it, then try again.") }
        return snapshot
    }
    private func readAll(_ info: PTPDeviceInfo) async throws -> [CameraSlotSnapshot] {
        var slots: [CameraSlotSnapshot] = []
        for slot in 1...4 { slots.append(try await readSlot(slot,info:info)) }; return slots
    }

    /// Reads all four banks from the settings object, without touching the bank selector.
    /// Falls back to selector reads when the object is unavailable or was made unsafe by a selector write.
    func readSlots() async throws -> [CameraSlotSnapshot] {
        let info = try begin(); defer { busy = false; connection.releaseOperation() }
        guard !connection.selectorWritten, info.operations.contains(0x1008), info.operations.contains(0x1009) else {
            return try await preservingSelector { try await readAll(info) }
        }
        return try XM5BackupDecoder.decode(try await fetchSettingsObject(info))
    }

    /// Reads every property of every bank. This switches the bank selector, then restores it.
    func readAllProperties() async throws -> [CameraSlotSnapshot] {
        let info = try begin(); defer { busy = false; connection.releaseOperation() }
        return try await preservingSelector { try await readAll(info) }
    }

    private func makePlan(recipe: Recipe, baseline: CameraSlotSnapshot, info: PTPDeviceInfo) async throws -> RecipeWritePlan {
        let slot = baseline.slot
        guard baseline.readErrors.isEmpty else { throw PTPError.unsupported("C\(slot) could not be fully read. Retry its backup before preparing a write.") }
        let encoded = try RecipeWireCodec.encode(recipe,baseline:baseline)
        var warnings = encoded.warnings
        let name = PTP.safeName(recipe.name)
        if name != recipe.name { warnings.append("Camera name will be “\(name)” (25 safe ASCII characters maximum).") }
        // WB shift is stored per white balance mode, so matching the old mode's shift says nothing about the new one.
        let wbChanges = encoded.writes.contains { $0.property == 0xD199 && !RecipeWireCodec.equivalent(property: 0xD199, baseline.properties[0xD199], $0.data) }
        let writes = encoded.writes.filter {
            (wbChanges && [0xD19A, 0xD19B].contains($0.property)) || !RecipeWireCodec.equivalent(property: $0.property, baseline.properties[$0.property], $0.data)
        }
        if let required = writes.first(where: { $0.property == 0xD190 }).flatMap({ Self.minimumISO(dynamicRange: $0.data) }) {
            warnings.append("\(recipe.settings[.dynamicRange] ?? "This dynamic range") needs ISO \(required) or higher. Set the camera’s ISO, or its AUTO range, to at least that before loading, or the camera may refuse this write.")
        }
        try await validateRecovery(writes: writes, name: name, before: baseline)
        for write in writes {
            guard info.properties.contains(write.property), RecipeWireCodec.writableProperties.contains(write.property), baseline.properties[write.property] != nil else { throw PTPError.unsupported("\(write.label) is not available from this camera. Remove it from the recipe before writing.") }
            do { try await validate(write.property, write.data) }
            catch PTPError.unsupported(let reason) { throw PTPError.unsupported("\(recipe.name) on C\(slot): \(reason)") }
        }
        try await validate(0xD18D, PTP.string(name))
        if capabilityProfile != nil { warnings.append("Using the researched X-M5_0100 value profile because this camera does not provide property descriptors. Camera-side limits still apply; any rejection stops the write.") }
        return RecipeWritePlan(slot:slot,name:name,writes:writes,before:baseline,warnings:warnings,device:info)
    }

    func plan(recipe: Recipe, slot: Int) async throws -> RecipeWritePlan {
        let info = try begin(); defer { busy = false; connection.releaseOperation() }
        return try await preservingSelector {
            try await makePlan(recipe: recipe, baseline: try await readSlot(slot,info:info), info: info)
        }
    }

    /// Plans a whole catalog against one read of the camera. Writes nothing except the bank selector.
    func planCatalog(id: UUID, name: String, recipes: [Int: Recipe]) async throws -> CatalogWritePlan {
        guard Set(recipes.keys) == Set(1...4) else { throw PTPError.unsupported("A catalog needs a recipe for each of C1, C2, C3 and C4 before it can be loaded.") }
        let info = try begin(); defer { busy = false; connection.releaseOperation() }
        return try await preservingSelector {
            var plans: [RecipeWritePlan] = []
            for slot in 1...4 {
                plans.append(try await makePlan(recipe: recipes[slot]!, baseline: try await readSlot(slot,info:info), info: info))
            }
            return CatalogWritePlan(catalogID: id, catalogName: name, plans: plans)
        }
    }

    /// Restores a saved bank's raw values. Values its modes weren't using are left alone, because the camera may refuse them.
    func plan(snapshot: CameraSlotSnapshot, slot: Int) async throws -> RecipeWritePlan {
        let info = try begin(); defer { busy = false; connection.releaseOperation() }
        return try await preservingSelector {
            let baseline = try await readSlot(slot,info:info)
            guard baseline.readErrors.isEmpty else { throw PTPError.unsupported("C\(slot) could not be fully read. Retry its backup before preparing a write.") }
            guard snapshot.readErrors.isEmpty else { throw PTPError.unsupported("This backup could not read every value of C\(snapshot.slot), so it can't be restored safely. Use a complete backup or Fujifilm Tether App.") }
            let wbChanges = snapshot.properties[0xD199].map { !RecipeWireCodec.equivalent(property: 0xD199, baseline.properties[0xD199], $0) } ?? false
            func active(_ code: UInt16) -> Bool {
                switch code {
                case 0xD19C: return snapshot.properties[0xD199].map { $0 == PTP.u16(0x8007) } ?? true
                case 0xD190, 0xD19D, 0xD19E: return snapshot.properties[0xD191].map { $0 == PTP.u16(0) } ?? true
                case 0xD193, 0xD194:
                    guard let film = snapshot.properties[0xD192], let number = try? PTP.scalar(film) else { return true }
                    return RecipeWireCodec.monochromeCodes.contains(number)
                default: return true
                }
            }
            var writes: [PTPPropertyWrite] = []
            var missing = 0
            for code in RecipeWireCodec.writeOrder {
                guard let saved = snapshot.properties[code] else { missing += 1; continue }
                guard active(code) else { continue }
                let value = RecipeWireCodec.writableValue(property: code, value: saved)
                let shiftAfterModeChange = wbChanges && (code == 0xD19A || code == 0xD19B)
                if !shiftAfterModeChange, RecipeWireCodec.equivalent(property: code, baseline.properties[code], value) { continue }
                do { try await validate(code, value) }
                catch PTPError.unsupported { throw PTPError.unsupported(String(format: "This backup contains a value for 0x%04X that cannot be restored exactly. Use Fujifilm Tether App for a full camera restore.", code)) }
                writes.append(PTPPropertyWrite(property: code, data: value, label: RecipeWireCodec.label(for: code), displayValue: code == 0xD190 && value == PTP.u16(0xFFFF) ? "DR-Auto" : String(try PTP.scalar(value, signed: true))))
            }
            guard snapshot.name.isEmpty || PTP.safeName(snapshot.name) == snapshot.name else { throw PTPError.unsupported("The backup's original bank name cannot be restored exactly.") }
            try await validateRecovery(writes: writes, name: snapshot.name, before: baseline)
            var warnings = ["Restore applies saved recipe values the bank was using, and its original name. Image size, image quality, lens modulation and color space remain unchanged. Use FUJIFILM TETHER APP for a whole camera restore."]
            if missing > 0 { warnings.append("This backup is missing \(missing) recipe values. Those settings will stay as they are on the camera.") }
            if capabilityProfile != nil { warnings.append("Using the researched X-M5_0100 value profile because this camera does not provide property descriptors. Camera-side limits still apply; any rejection stops the write.") }
            return RecipeWritePlan(slot:slot,name:snapshot.name,writes:writes,before:baseline,warnings:warnings,device:info)
        }
    }

    func apply(_ plan: RecipeWritePlan, persistBackup: ([CameraSlotSnapshot], PTPDeviceInfo) throws -> Void) async throws -> RecipeWriteReport {
        try await applyAll([plan], persistBackup: persistBackup)[0]
    }

    /// Backs up all four banks once, writes each plan in order, then verifies every bank by reading it back.
    func applyAll(_ plans: [RecipeWritePlan], persistBackup: ([CameraSlotSnapshot], PTPDeviceInfo) throws -> Void) async throws -> [RecipeWriteReport] {
        let info = try begin(); defer { busy = false; connection.releaseOperation() }
        guard !plans.isEmpty, Set(plans.map(\.slot)).count == plans.count else { throw PTPError.unsupported("Each bank can be written only once per load.") }
        guard plans.allSatisfy({ $0.device == info }) else { throw PTPError.changed("The connected camera changed. Prepare the write again.") }
        guard plans.allSatisfy({ $0.writes.allSatisfy { RecipeWireCodec.writableProperties.contains($0.property) } }) else { throw PTPError.unsupported("Unknown or live-state write refused.") }
        return try await preservingSelector {
            let all = try await readAll(info)
            guard all.count == 4, all.allSatisfy({ $0.readErrors.isEmpty }),
                  plans.allSatisfy({ plan in all.first(where: { $0.slot == plan.slot }) == plan.before }) else {
                throw PTPError.changed("Camera settings changed or a bank could not be read. No recipe was written. Read the camera and prepare the change again.")
            }
            for plan in plans {
                try await validateRecovery(writes: plan.writes, name: plan.name, before: plan.before)
                for write in plan.writes { try await validate(write.property, write.data) }
                try await validate(0xD18D, PTP.string(plan.name))
            }
            // Persistence and disk read-back must succeed before changing saved recipe settings.
            try persistBackup(all,info)
            var finished: [Int] = []
            for plan in plans {
                var applied: [UInt16] = []
                var writing: PTPPropertyWrite?
                do {
                    try await select(plan.slot)
                    let refreshed = try PTPDeviceInfo.parse(await connection.command(0x1001))
                    guard refreshed == info else { throw PTPError.changed("Camera capabilities changed before writing.") }
                    if capabilityProfile != nil { capabilityProfile = nil; _ = try await profile() }
                    for write in plan.writes {
                        guard RecipeWireCodec.writableProperties.contains(write.property), write.property != 0xD1A5 else { throw PTPError.unsupported("Unknown or live-state write refused.") }
                        try await validate(write.property, write.data)
                        writing = write
                        try await set(write.property,write.data)
                        applied.append(write.property)
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                    if plan.name != plan.before.name {
                        let nameData = try PTP.string(plan.name)
                        try await validate(0xD18D, nameData)
                        try await set(0xD18D,nameData); applied.append(0xD18D)
                    }
                    if !plan.writes.isEmpty || plan.name != plan.before.name { finished.append(plan.slot) }
                } catch {
                    throw writeStopped(slot: plan.slot, applied: applied, finished: finished, writing: writing, error: error)
                }
            }
            do {
                let afterBanks = try await readAll(info)
                guard afterBanks.allSatisfy({ $0.readErrors.isEmpty }) else { throw PTPError.changed("Post-write bank verification was incomplete.") }
                for untouched in all where !plans.contains(where: { $0.slot == untouched.slot }) {
                    guard afterBanks.first(where: { $0.slot == untouched.slot }) == untouched else {
                        throw PTPError.changed("C\(untouched.slot) changed unexpectedly during verification.")
                    }
                }
                return try plans.map { plan in
                    guard let after = afterBanks.first(where: { $0.slot == plan.slot }) else { throw PTPError.changed("Post-write bank verification was incomplete.") }
                    guard after.name == plan.name else { throw PTPError.changed("Camera preset name did not match after writing.") }
                    for write in plan.writes {
                        guard RecipeWireCodec.equivalent(property: write.property, after.properties[write.property], write.data) else { throw PTPError.changed("\(write.label) failed read-back verification on C\(plan.slot).") }
                    }
                    return RecipeWriteReport(slot:plan.slot,verifiedProperties:plan.writes.count,snapshot:after,warnings:plan.warnings,unexpected:collateralChanges(plan,after: after))
                }
            } catch {
                let slots = plans.map { "C\($0.slot)" }.joined(separator: ", ")
                throw PTPError.changed("Write verification stopped for \(slots). \(error.localizedDescription) The pre-write backup is saved; do not assume the entire recipe was applied.")
            }
        }
    }

    /// Anything that moved without being written, other than values that follow a mode that did change.
    private func collateralChanges(_ plan: RecipeWritePlan, after: CameraSlotSnapshot) -> [String] {
        let written = Set(plan.writes.map(\.property))
        var followers: Set<UInt16> = []
        if written.contains(0xD199) { followers.formUnion([0xD19A, 0xD19B, 0xD19C]) }
        if written.contains(0xD191) { followers.formUnion([0xD190, 0xD19D, 0xD19E]) }
        if written.contains(0xD192) { followers.formUnion([0xD193, 0xD194, 0xD196, 0xD197, 0xD19A, 0xD19B, 0xD19F]) }
        return plan.before.properties.keys.sorted().compactMap { code in
            guard !written.contains(code), !followers.contains(code),
                  !RecipeWireCodec.equivalent(property: code, plan.before.properties[code], after.properties[code]) else { return nil }
            return "C\(plan.slot): \(RecipeWireCodec.label(for: code))"
        }
    }

    /// From the manual. The camera refused DR400 with AUTO capped at ISO 400, then accepted it with AUTO at 640–6400.
    private static func minimumISO(dynamicRange value: Data) -> Int? {
        switch value {
        case PTP.u16(200): return 320
        case PTP.u16(400): return 640
        default: return nil
        }
    }

    private func writeStopped(slot: Int, applied: [UInt16], finished: [Int], writing: PTPPropertyWrite?, error: Error) -> PTPError {
        let codes = applied.map { String(format:"0x%04X",$0) }.joined(separator:", ")
        let done = finished.isEmpty ? " No other banks were changed." : " Banks already changed: \(finished.map { "C\($0)" }.joined(separator: ", "))."
        var hint = ""
        if let writing, writing.property == 0xD190, case PTPError.response(0x201C) = error {
            let required = Self.minimumISO(dynamicRange: writing.data).map { " \(writing.displayValue) needs ISO \($0) or higher, so check the camera’s ISO and its AUTO range, then try again." } ?? " Check the camera’s ISO and its AUTO range, then try again."
            hint = " The camera refused \(writing.displayValue).\(required)"
        }
        return PTPError.changed("C\(slot) write stopped. \(error.localizedDescription)\(hint) Accepted properties: \(codes.isEmpty ? "none" : codes).\(done) The pre-write backup is saved; do not assume the entire recipe was applied.")
    }

    /// Fetches the whole settings object, the same file Tether App saves as a backup.
    func readFullBackup() async throws -> Data {
        let info = try begin(); defer { busy = false; connection.releaseOperation() }
        return try await fetchSettingsObject(info)
    }

    private func fetchSettingsObject(_ info: PTPDeviceInfo) async throws -> Data {
        guard !connection.selectorWritten else { throw PTPError.unsupported("The bank selector was used in this USB session. Turn the camera off, reconnect it, then try again.") }
        guard info.properties.contains(0xD16E), info.operations.contains(0x1008), info.operations.contains(0x1009), try await PTP.scalar(get(0xD16E)) == 6 else { throw PTPError.unsupported("Whole camera download requires the advertised RAW CONV./BACKUP RESTORE protocol. Use FUJIFILM TETHER APP if it is unavailable.") }
        let objectInfo = try await connection.command(0x1008,parameters:[0])
        var reader = PTPReader(objectInfo)
        _ = try reader.u32(); let format = try reader.u16(); _ = try reader.u16(); let size = try reader.u32()
        guard format == 0x5000, size > 0, size <= 100_000 else { throw PTPError.unsupported("Object 0 is not a recognized settings backup. No file was downloaded.") }
        let blob = try await connection.command(0x1009,parameters:[0])
        guard blob.count == size else { throw PTPError.malformed("settings backup size mismatch") }
        return blob
    }
}
