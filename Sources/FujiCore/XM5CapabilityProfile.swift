import Foundation

/// A researched value allowlist, not a camera-reported promise of writability.
/// Sources: fujifilm-ptp-recipes daba2d97d6b37bd1d5dbc68ca974f6b22f433071,
/// docs/properties.md and docs/reverse-engineering/{xrfc-capability-database,xrfc-value-tables}.md.
/// X-M5_0100 selects X-M5Config1 in XRFC.DAT. Mode dependencies, backups and read-back
/// verification must still be enforced by the caller. Unknown generations fail closed.
public struct XM5CapabilityProfile: Equatable {
    public static let generation = "X-M5_0100"
    private let advertisedProperties: Set<UInt16>

    private init(advertisedProperties: Set<UInt16>) {
        self.advertisedProperties = advertisedProperties
    }

    public static func resolve(device: PTPDeviceInfo, usbMode: Data, condition: Data, compatibility: Data) throws -> Self {
        let manufacturer = device.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ["FUJIFILM", "FUJIFILM CORPORATION"].contains(manufacturer), device.isXM5,
              !device.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PTPError.unsupported("The researched capability profile requires an identified Fujifilm X-M5 with a serial number.")
        }
        let advertised = Set(device.properties)
        let required: Set<UInt16> = [0xD16E, 0xD186, 0xD187, 0xD18C, 0xD18D]
        guard required.isSubset(of: advertised), try PTP.scalar(usbMode) == 6 else {
            throw PTPError.unsupported("The X-M5 must advertise its backup/restore and recipe properties in USB RAW CONV./BACKUP RESTORE mode.")
        }
        guard try string(condition) == generation, try string(compatibility) == generation else {
            throw PTPError.unsupported("This X-M5 capability generation has not been verified. No fallback write validation is available.")
        }
        return Self(advertisedProperties: advertised)
    }

    public func validate(property: UInt16, value: Data) throws {
        guard advertisedProperties.contains(property) else {
            throw PTPError.unsupported(String(format: "The camera does not advertise property 0x%04X.", property))
        }
        if property == 0xD18D {
            let name = try Self.string(value)
            let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 !\"#$%&'()*+,-./:;<=>?@[\\]^_{|}~")
            guard name.count <= 25, name.allSatisfy({ allowed.contains($0) }) else {
                throw PTPError.unsupported("Camera names must use at most 25 safe ASCII characters.")
            }
            return
        }
        guard property == 0xD18C || RecipeWireCodec.writableProperties.contains(property) else {
            throw PTPError.unsupported(String(format: "No researched X-M5 write mapping exists for 0x%04X.", property))
        }
        let unsigned = try PTP.scalar(value)
        let signed = Int(Int16(bitPattern: UInt16(unsigned)))
        func stepped(_ number: Int, _ lower: Int, _ upper: Int, _ step: Int) -> Bool {
            (lower...upper).contains(number) && (number - lower) % step == 0
        }
        let valid: Bool
        switch property {
        case 0xD18C: valid = (1...4).contains(unsigned)
        case 0xD190: valid = [100, 200, 400, 0xFFFF].contains(unsigned) // 0xFFFF is DR Auto; 0 was refused
        case 0xD191: valid = [0, 1, 2, 32768].contains(unsigned)
        case 0xD192: valid = (1...20).contains(unsigned)
        case 0xD193, 0xD194: valid = stepped(signed, -180, 180, 10)
        case 0xD195: valid = (1...5).contains(unsigned)
        case 0xD196, 0xD197: valid = (1...3).contains(unsigned)
        case 0xD199: valid = [2, 4, 6, 8, 0x8001, 0x8002, 0x8003, 0x8006, 0x8007, 0x8008, 0x8009, 0x800A, 0x8020, 0x8021].contains(unsigned)
        case 0xD19A, 0xD19B: valid = (-9...9).contains(signed)
        case 0xD19C: valid = stepped(unsigned, 2500, 10000, 10)
        case 0xD19D, 0xD19E: valid = stepped(signed, -20, 40, 5)
        case 0xD19F, 0xD1A0: valid = stepped(signed, -40, 40, 10)
        case 0xD1A1: valid = [32768, 28672, 16384, 12288, 8192, 4096, 0, 24576, 20480].contains(unsigned)
        case 0xD1A2: valid = stepped(signed, -50, 50, 10)
        default: valid = false
        }
        guard valid else {
            throw PTPError.unsupported(String(format: "Value is outside the researched X-M5 range for 0x%04X.", property))
        }
    }

    private static func string(_ data: Data) throws -> String {
        var reader = PTPReader(data)
        let value = try reader.string()
        guard reader.offset == data.count else { throw PTPError.malformed("trailing PTP string bytes") }
        return value
    }
}
