import Foundation
import FujiCore

@MainActor
protocol RecipeCameraTransport: AnyObject {
    var isConnected: Bool { get }
    var deviceInfo: PTPDeviceInfo? { get }
    func acquireOperation() throws
    func releaseOperation()
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

struct RecipeWriteReport {
    let slot: Int
    let verifiedProperties: Int
    let snapshot: CameraSlotSnapshot
    let warnings: [String]
}

@MainActor
final class RecipeCameraService {
    let connection: any RecipeCameraTransport
    private var busy = false
    init(connection: any RecipeCameraTransport) { self.connection = connection }

    private func begin() throws -> PTPDeviceInfo {
        guard !busy else { throw PTPError.unsupported("Wait for the current camera operation to finish.") }
        guard connection.isConnected, let info = connection.deviceInfo, info.isXM5 else { throw PTPError.unsupported("Connect your X-M5 first.") }
        try connection.acquireOperation()
        busy = true; return info
    }
    private func get(_ code: UInt16) async throws -> Data { try await connection.command(0x1015, parameters: [UInt32(code)]) }
    private func set(_ code: UInt16, _ data: Data) async throws { _ = try await connection.command(0x1016, parameters: [UInt32(code)], outData: data) }
    private func descriptor(_ code: UInt16) async throws -> PTPPropertyDescriptor {
        let d = try PTPPropertyDescriptor.parse(await connection.command(0x1014, parameters: [UInt32(code)]))
        guard d.code == code else { throw PTPError.malformed("descriptor property mismatch") }; return d
    }
    private func select(_ slot: Int) async throws {
        guard (1...4).contains(slot) else { throw PTPError.unsupported("X-M5 has C1–C4. No other slot will be accessed.") }
        let payload = PTP.u16(UInt16(slot))
        try await descriptor(0xD18C).validate(payload)
        try await set(0xD18C, payload)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard try await get(0xD18C) == payload else { throw PTPError.changed("Camera did not confirm the selected custom bank.") }
    }
    private func preservingSelector<T>(_ operation: () async throws -> T) async throws -> T {
        let original = try await get(0xD18C)
        let old = try PTP.scalar(original)
        guard (1...4).contains(old) else { throw PTPError.unsupported("Camera returned an unknown slot selector (\(old)); no bank will be changed.") }
        let result: T
        do { result = try await operation() }
        catch {
            if connection.isConnected { try? await set(0xD18C, original) }
            throw error
        }
        try await set(0xD18C, original)
        return result
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
        return CameraSlotSnapshot(slot: slot, name: name, properties: properties, readErrors: errors)
    }
    private func readAll(_ info: PTPDeviceInfo) async throws -> [CameraSlotSnapshot] {
        var slots: [CameraSlotSnapshot] = []
        for slot in 1...4 { slots.append(try await readSlot(slot,info:info)) }; return slots
    }

    func readSlots() async throws -> [CameraSlotSnapshot] {
        let info = try begin(); defer { busy = false; connection.releaseOperation() }
        return try await preservingSelector { try await readAll(info) }
    }

    func plan(recipe: Recipe, slot: Int) async throws -> RecipeWritePlan {
        let info = try begin(); defer { busy = false; connection.releaseOperation() }
        return try await preservingSelector {
            let baseline = try await readSlot(slot,info:info)
            guard baseline.readErrors.isEmpty else { throw PTPError.unsupported("C\(slot) could not be fully read. Retry its backup before preparing a write.") }
            let encoded = try RecipeWireCodec.encode(recipe,baseline:baseline)
            var warnings = encoded.warnings
            let name = PTP.safeName(recipe.name)
            if name != recipe.name { warnings.append("Camera name will be “\(name)” (25 safe ASCII characters maximum).") }
            let writes = encoded.writes
            for write in writes {
                guard info.properties.contains(write.property), RecipeWireCodec.writableProperties.contains(write.property), baseline.properties[write.property] != nil else { throw PTPError.unsupported("\(write.label) is not available from this camera. Remove it from the recipe before writing.") }
                // Values and ranges are re-queried after their parent mode is applied.
                guard try await descriptor(write.property).writable else { throw PTPError.unsupported("The camera marks \(write.label) read-only.") }
            }
            try await descriptor(0xD18D).validate(PTP.string(name))
            return RecipeWritePlan(slot:slot,name:name,writes:writes,before:baseline,warnings:warnings,device:info)
        }
    }

    func plan(snapshot: CameraSlotSnapshot, slot: Int) async throws -> RecipeWritePlan {
        let draft = try await plan(recipe:snapshot.recipe,slot:slot)
        return RecipeWritePlan(slot:draft.slot,name:draft.name,writes:draft.writes,before:draft.before,
            warnings:draft.warnings + ["Restore applies only understood recipe fields and the name. Image size, image quality, lens modulation, color space, unknown and inactive fields remain unchanged. Use FUJIFILM TETHER APP for a whole camera restore."],device:draft.device)
    }

    func apply(_ plan: RecipeWritePlan, persistBackup: ([CameraSlotSnapshot], PTPDeviceInfo) throws -> Void) async throws -> RecipeWriteReport {
        let info = try begin(); defer { busy = false; connection.releaseOperation() }
        guard info == plan.device else { throw PTPError.changed("The connected camera changed. Prepare the write again.") }
        return try await preservingSelector {
            let all = try await readAll(info)
            guard all.count == 4, all.allSatisfy({ $0.readErrors.isEmpty }), let current = all.first(where: { $0.slot == plan.slot }), current == plan.before else { throw PTPError.changed("Camera settings changed or a bank could not be read. No recipe was written. Read the camera and prepare the change again.") }
            // Persistence must succeed before changing any saved recipe setting.
            try persistBackup(all,info)
            try await select(plan.slot)
            let refreshed = try PTPDeviceInfo.parse(await connection.command(0x1001))
            guard refreshed == info else { throw PTPError.changed("Camera capabilities changed before writing.") }
            var applied: [UInt16] = []
            do {
                for write in plan.writes {
                    guard RecipeWireCodec.writableProperties.contains(write.property), write.property != 0xD1A5 else { throw PTPError.unsupported("Unknown or live-state write refused.") }
                    try await descriptor(write.property).validate(write.data)
                    try await set(write.property,write.data)
                    applied.append(write.property)
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                if plan.name != plan.before.name {
                    let nameData = try PTP.string(plan.name)
                    try await descriptor(0xD18D).validate(nameData)
                    try await set(0xD18D,nameData); applied.append(0xD18D)
                }
                let after = try await readSlot(plan.slot,info:info)
                guard after.name == plan.name else { throw PTPError.changed("Camera preset name did not match after writing.") }
                for write in plan.writes {
                    guard after.properties[write.property] == write.data else { throw PTPError.changed("\(write.label) failed read-back verification.") }
                }
                return RecipeWriteReport(slot:plan.slot,verifiedProperties:plan.writes.count,snapshot:after,warnings:plan.warnings)
            } catch {
                let codes = applied.map { String(format:"0x%04X",$0) }.joined(separator:", ")
                throw PTPError.changed("C\(plan.slot) write stopped. \(error.localizedDescription) Accepted properties: \(codes.isEmpty ? "none" : codes). The pre-write backup is saved; do not assume the entire recipe was applied.")
            }
        }
    }

    func readFullBackup() async throws -> Data {
        let info = try begin(); defer { busy = false; connection.releaseOperation() }
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
