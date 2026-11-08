import Foundation

/// A read-only description of a connected camera, for contributors adding support for a new model.
/// It holds no serial number and is built only from GetDeviceInfo and GetDevicePropValue.
public enum CameraDiagnostics {
    private static let recipeProperties: [UInt16] = [0xD16E, 0xD186, 0xD187, 0xD18C, 0xD18D] + Array(UInt16(0xD18E)...UInt16(0xD1A5))
    private static let maximumValueBytes = 64

    /// The properties worth reading: the known recipe range, limited to what this camera advertises.
    public static func propertiesToRead(for device: PTPDeviceInfo) -> [UInt16] {
        guard device.operations.contains(0x1015) else { return [] }
        return recipeProperties.filter(device.properties.contains)
    }

    public static func report(device: PTPDeviceInfo, values: [UInt16: Data], errors: [UInt16: String], appVersion: String) -> String {
        func hex(_ codes: [UInt16]) -> String {
            codes.sorted().map { String(format: "0x%04X", $0) }.joined(separator: " ")
        }
        var lines = [
            "## Camera report",
            "",
            "- App: Filmback \(appVersion)",
            "- Manufacturer: \(device.manufacturer)",
            "- Model: \(device.model)",
            "- Firmware: \(device.deviceVersion)",
            "- Support: \(CameraProfile.matching(device) == nil ? "not supported yet" : "supported")",
            "",
            "### Operations (\(device.operations.count))",
            "",
            hex(device.operations),
            "",
            "### Properties (\(device.properties.count))",
            "",
            hex(device.properties),
            "",
            "### Current values",
            "",
            "Bank properties show whichever bank is currently selected.",
            ""
        ]
        for code in (Set(values.keys).union(errors.keys)).sorted() {
            let label = String(format: "0x%04X", code)
            if let value = values[code] { lines.append("- \(label): \(describe(value, serial: device.serialNumber))") }
            else if let error = errors[code] { lines.append("- \(label): error, \(error)") }
        }
        if values.isEmpty && errors.isEmpty { lines.append("No values could be read. Check the camera's USB mode.") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func describe(_ value: Data, serial: String) -> String {
        let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, [Data(trimmed.utf8), trimmed.data(using: .utf16LittleEndian) ?? Data()].contains(where: { value.range(of: $0) != nil }) {
            return "removed, it contains the serial number"
        }
        let bytes = value.prefix(maximumValueBytes).map { String(format: "%02X", $0) }.joined(separator: " ")
        let more = value.count > maximumValueBytes ? " … (\(value.count) bytes)" : ""
        var reader = PTPReader(value)
        if value.count > 2, let text = try? reader.string(), reader.offset == value.count, !text.isEmpty { return "\(bytes)\(more) “\(text)”" }
        return bytes + more
    }
}
