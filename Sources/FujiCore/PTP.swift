import Foundation

public enum PTPError: LocalizedError {
    case malformed(String)
    case response(UInt16)
    case unsupported(String)
    case changed(String)
    public var errorDescription: String? {
        switch self {
        case .malformed(let s): return "Invalid camera response: \(s)"
        case .response(let code): return String(format: "Camera returned PTP error 0x%04X.", code)
        case .unsupported(let s), .changed(let s): return s
        }
    }
}

public struct PTPReader {
    public let data: Data
    public private(set) var offset = 0
    public init(_ data: Data) { self.data = data }
    public mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else { throw PTPError.malformed("truncated payload") }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    public mutating func u8() throws -> UInt8 { try bytes(1)[0] }
    public mutating func u16() throws -> UInt16 { let b = try bytes(2); return UInt16(b[0]) | UInt16(b[1]) << 8 }
    public mutating func u32() throws -> UInt32 { let b = try bytes(4); return b.enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) } }
    public mutating func string() throws -> String {
        let count = Int(try u8())
        if count == 0 { return "" }
        let raw = try bytes(count * 2)
        guard raw.suffix(2) == Data([0, 0]), let text = String(data: raw.dropLast(2), encoding: .utf16LittleEndian) else { throw PTPError.malformed("invalid PTP string") }
        return text
    }
    public mutating func u16Array() throws -> [UInt16] {
        let count = Int(try u32())
        guard count <= 65_536, count <= (data.count - offset) / 2 else { throw PTPError.malformed("invalid array length") }
        return try (0..<count).map { _ in try u16() }
    }
}

public enum PTP {
    public static func u16(_ value: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
    public static func i16(_ value: Int16) -> Data { u16(UInt16(bitPattern: value)) }
    public static func u32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    public static func string(_ value: String) throws -> Data {
        let units = Array(value.utf16)
        guard units.count < 255 else { throw PTPError.unsupported("PTP text is too long.") }
        var result = Data([UInt8(units.count + 1)])
        for unit in units { result.append(u16(unit)) }
        result.append(u16(0)); return result
    }
    public static func command(_ operation: UInt16, transaction: UInt32, parameters: [UInt32]) -> Data {
        var d = u32(UInt32(12 + parameters.count * 4)); d.append(u16(1)); d.append(u16(operation)); d.append(u32(transaction))
        parameters.forEach { d.append(u32($0)) }; return d
    }
    public static func validateResponse(_ data: Data, transaction: UInt32) throws {
        let (code, received) = try responseHeader(data)
        guard received == transaction else { throw PTPError.malformed("PTP response transaction mismatch") }
        guard code == 0x2001 else { throw PTPError.response(code) }
    }
    @discardableResult
    public static func validateImageCaptureCoreResponse(_ data: Data) throws -> UInt32 {
        // ImageCaptureCore assigns the wire transaction ID. Its per-request callback correlates the response.
        // Apple PTPPassThrough sample, PTPProtocolHelpers.h: transactionID documentation.
        let (code, received) = try responseHeader(data)
        guard code == 0x2001 else { throw PTPError.response(code) }
        return received
    }
    private static func responseHeader(_ data: Data) throws -> (code: UInt16, transaction: UInt32) {
        guard (12...32).contains(data.count), (data.count - 12) % 4 == 0 else { throw PTPError.malformed("invalid PTP response length") }
        var r = PTPReader(data)
        let length = try r.u32(), kind = try r.u16(), code = try r.u16(), received = try r.u32()
        guard length == data.count, kind == 3 else { throw PTPError.malformed("invalid PTP response header") }
        return (code, received)
    }
    public static func scalar(_ data: Data, signed: Bool = false) throws -> Int {
        guard data.count == 2 else { throw PTPError.malformed("expected a 16-bit property") }
        var r = PTPReader(data); let value = try r.u16()
        return signed ? Int(Int16(bitPattern: value)) : Int(value)
    }
    public static func safeName(_ name: String) -> String {
        let folded = name.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'").folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 !\"#$%&'()*+,-./:;<=>?@[\\]^_{|}~")
        let clean = String(folded.map { allowed.contains($0) ? $0 : " " }).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let limited = String(clean.prefix(25)).trimmingCharacters(in: .whitespaces)
        return limited.isEmpty ? "Untitled" : limited
    }
}

public struct PTPDeviceInfo: Codable, Equatable {
    public let manufacturer: String
    public let model: String
    public let deviceVersion: String
    public let serialNumber: String
    public let operations: [UInt16]
    public let properties: [UInt16]
    public init(manufacturer: String, model: String, deviceVersion: String, serialNumber: String, operations: [UInt16], properties: [UInt16]) {
        self.manufacturer = manufacturer; self.model = model; self.deviceVersion = deviceVersion; self.serialNumber = serialNumber; self.operations = operations; self.properties = properties
    }
    public static func parse(_ data: Data) throws -> Self {
        var r = PTPReader(data)
        _ = try r.u16(); _ = try r.u32(); _ = try r.u16(); _ = try r.string(); _ = try r.u16()
        let operations = try r.u16Array(); _ = try r.u16Array(); let properties = try r.u16Array(); _ = try r.u16Array(); _ = try r.u16Array()
        return try Self(manufacturer: r.string(), model: r.string(), deviceVersion: r.string(), serialNumber: r.string(), operations: operations, properties: properties)
    }
    public var isXM5: Bool { model.uppercased().replacingOccurrences(of: "FUJIFILM", with: "").trimmingCharacters(in: .whitespaces) == "X-M5" }
}

public struct PTPPropertyDescriptor {
    public let code: UInt16
    public let type: UInt16
    public let writable: Bool
    public let current: Data
    public let allowed: [Data]?
    public let range: [Int]?
    public static func parse(_ data: Data) throws -> Self {
        var r = PTPReader(data)
        let code = try r.u16(), type = try r.u16(), writable = try r.u8() == 1
        func value(_ r: inout PTPReader) throws -> Data {
            if type == 0xFFFF { let start = r.offset; _ = try r.string(); return data.subdata(in: start..<r.offset) }
            guard type == 3 || type == 4 else { throw PTPError.unsupported("Only 16-bit and string recipe descriptors are supported.") }
            return try r.bytes(2)
        }
        _ = try value(&r); let current = try value(&r), form = try r.u8()
        var allowed: [Data]?; var range: [Int]?
        if form == 1 {
            guard type != 0xFFFF else { throw PTPError.malformed("string range descriptor") }
            range = try (0..<3).map { _ in try PTP.scalar(value(&r), signed: type == 3) }
        } else if form == 2 {
            let count = Int(try r.u16())
            guard count <= 4096 else { throw PTPError.malformed("oversized descriptor enumeration") }
            allowed = try (0..<count).map { _ in try value(&r) }
        } else if form != 0 { throw PTPError.malformed("unknown descriptor form") }
        return Self(code: code, type: type, writable: writable, current: current, allowed: allowed, range: range)
    }
    public func validate(_ value: Data) throws {
        guard writable else { throw PTPError.unsupported(String(format: "Camera marks property 0x%04X read-only.", code)) }
        if type == 0xFFFF { var reader = PTPReader(value); _ = try reader.string(); guard reader.offset == value.count else { throw PTPError.malformed("trailing string bytes") } }
        else { _ = try PTP.scalar(value, signed: type == 3) }
        if let allowed, !allowed.contains(value) { throw PTPError.unsupported(String(format: "Camera does not advertise this value for 0x%04X.", code)) }
        if let range {
            let number = try PTP.scalar(value, signed: type == 3)
            guard number >= range[0], number <= range[1], range[2] > 0, (number - range[0]) % range[2] == 0 else { throw PTPError.unsupported(String(format: "Value is outside the camera's range for 0x%04X.", code)) }
        }
    }
}

public struct CameraSlotSnapshot: Codable, Identifiable, Equatable {
    public var id: Int { slot }
    public let slot: Int
    public let name: String
    public let properties: [UInt16: Data]
    public let readErrors: [String: String]
    public init(slot: Int, name: String, properties: [UInt16: Data], readErrors: [String: String] = [:]) {
        self.slot = slot; self.name = name; self.properties = properties; self.readErrors = readErrors
    }
    public var recipe: Recipe { RecipeWireCodec.decode(self) }
    /// After a power cycle the live properties can hold these until the bank selector is written. They aren't a recipe.
    /// Only film counts: 0xD190 = 0xFFFF alone may be a real setting on this body, such as DR Auto.
    public var holdsPlaceholders: Bool {
        properties[0xD192] == PTP.u16(0x8000)
    }
}

public struct PTPPropertyWrite: Identifiable, Equatable {
    public var id: UInt16 { property }
    public let property: UInt16
    public let data: Data
    public let label: String
    public let displayValue: String
    public init(property: UInt16, data: Data, label: String, displayValue: String) { self.property = property; self.data = data; self.label = label; self.displayValue = displayValue }
}
