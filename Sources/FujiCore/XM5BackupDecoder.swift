import Foundation

/// Reads C1–C4 from the X-M5 settings object (PTP GetObject handle 0, also Tether App's .dat file).
///
/// The layout was mapped on firmware 1.30 against live D18C...D1A4 reads of all four banks.
/// Enum tables hold only values seen on hardware, so anything else is reported, never guessed.
/// Dynamic range, D range priority, monochrome tone and smooth skin have not been located because
/// all four mapped banks hold the same values for them. Grain is read only when Off: "on" doesn't
/// say which size, so reporting it would be a guess that could later be written to a bank.
public enum XM5BackupDecoder {
    public static let size = 67_452
    public static let magic = Data("FUJIFILMX-BACKUP0100X-M5".utf8)
    private static let nameOffsets = [63_985, 65_009, 66_033, 67_057]
    private static let nameLimit = 25

    private static let films: [UInt8: UInt16] = [2: 3, 15: 11, 17: 19, 18: 20]
    private static let whiteBalances: [UInt8: UInt16] = [0: 2, 1: 0x8020, 10: 0x8007]
    private static let shiftOffsets: [UInt8: Int] = [0: -509, 1: -505, 10: -485]
    private static let grainOffByte: UInt8 = 2
    private static let grainOnByte: UInt8 = 1

    /// Recipe properties this decoder cannot read yet.
    public static let undecodedFields: [RecipeField] = [.dynamicRange, .dRangePriority, .monoWC, .monoMG, .smoothSkin, .grainRoughness, .grainSize]

    public static func isSettingsObject(_ data: Data) -> Bool {
        data.count == size && data.prefix(magic.count) == magic
    }

    public static func decode(_ data: Data) throws -> [CameraSlotSnapshot] {
        guard isSettingsObject(data) else {
            throw PTPError.unsupported("This is not an X-M5 settings backup in a format RecipeVault can read.")
        }
        let bytes = [UInt8](data)
        return try nameOffsets.enumerated().map { index, offset in
            try bank(index + 1, bytes: bytes, nameOffset: offset)
        }
    }

    private static func bank(_ slot: Int, bytes: [UInt8], nameOffset: Int) throws -> CameraSlotSnapshot {
        func at(_ relative: Int) -> UInt8 { bytes[nameOffset + relative] }
        let nameEnd = min(nameOffset + nameLimit + 1, bytes.count)
        guard let terminator = bytes[nameOffset..<nameEnd].firstIndex(of: 0),
              let name = String(bytes: bytes[nameOffset..<terminator], encoding: .ascii) else {
            throw PTPError.malformed("settings backup name for C\(slot)")
        }
        var values: [UInt16: Data] = [:]
        var unknown: [String: String] = [:]
        func mapped(_ code: UInt16, _ table: [UInt8: UInt16], _ raw: UInt8, _ label: String) {
            if let value = table[raw] { values[code] = PTP.u16(value) }
            else { unknown[String(format: "0x%04X", code)] = "\(label) index \(raw) has not been mapped yet." }
        }
        func tone(_ raw: UInt8) -> Data { PTP.i16((Int16(raw) - 4) * 5) }

        mapped(0xD192, films, at(-394), "Film simulation")
        if at(-364) == grainOffByte { values[0xD195] = PTP.u16(6) }
        else if at(-364) != grainOnByte { unknown["0xD195"] = "Grain index \(at(-364)) has not been mapped yet." }
        mapped(0xD199, whiteBalances, at(-511), "White balance")
        values[0xD196] = PTP.u16(UInt16(at(-366)) + 1)
        values[0xD197] = PTP.u16(UInt16(at(-365)) + 1)
        values[0xD19C] = PTP.u16(UInt16(at(-613)) | UInt16(at(-612)) << 8)
        values[0xD19D] = tone(at(-370))
        values[0xD19E] = tone(at(-368))
        values[0xD19F] = PTP.i16((7 - Int16(at(-374))) * 10)
        values[0xD1A0] = PTP.i16((4 - Int16(at(-372))) * 10)
        values[0xD1A2] = PTP.i16((Int16(at(-448)) - 6) * 10)
        if let shift = shiftOffsets[at(-511)] {
            values[0xD19A] = PTP.i16(9 - Int16(at(shift)))
            values[0xD19B] = PTP.i16(9 - Int16(at(shift + 2)))
        } else {
            unknown["0xD19A"] = "White balance shift depends on an unmapped white balance."
        }
        let noise = Int(at(-453)) - 4
        if let wire = RecipeWireCodec.nrCodes[noise] { values[0xD1A1] = PTP.u16(UInt16(wire)) }
        else { unknown["0xD1A1"] = "High ISO noise reduction value \(noise) is out of range." }
        return CameraSlotSnapshot(slot: slot, name: name, properties: values, readErrors: unknown)
    }
}
