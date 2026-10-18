import Foundation

public struct PhotoMetadataItem: Equatable, Sendable {
    public let label: String
    public let value: String
}

public struct PhotoInspection: Sendable {
    public let cameraModel: String
    public let metadata: [PhotoMetadataItem]
    public let result: ImportResult
    public let missingFields: [RecipeField]
    public let unrecognized: [String]
}

/// Reads metadata only. Mappings are documented at https://exiftool.org/TagNames/FujiFilm.html.
/// No picture decoding, file rewriting, or external process is involved.
public enum FujifilmPhotoInspector {
    public static let maximumFileBytes = 80 * 1_024 * 1_024

    public static func inspectJPEG(_ data: Data, filename: String) throws -> PhotoInspection {
        guard data.count <= maximumFileBytes else { throw failure("Choose an original JPEG smaller than 80 MB.") }
        let tiffData = try jpegEXIF(data)
        let tiff = try TIFFReader(tiffData)
        let root = try tiff.directory(at: Int(tiff.u32(4)))
        let make = root[0x010f]?.text ?? ""
        guard make.uppercased().contains("FUJIFILM") else {
            throw failure("This file does not identify a Fujifilm camera. Choose an original camera JPEG with its EXIF metadata intact.")
        }
        let model = root[0x0110]?.text ?? "Unknown Fujifilm model"
        guard let exifOffset = root[0x8769]?.integers.first else {
            throw failure("This JPEG has no EXIF camera-settings directory. Use the original file from your camera or memory card.")
        }
        let exif = try tiff.directory(at: Int(exifOffset))
        guard let maker = exif[0x927c], maker.bytes.starts(with: Array("FUJIFILM".utf8)) else {
            throw failure("Fujifilm MakerNote settings are missing. Edited, shared, and downloaded images often remove them. Try the original camera JPEG.")
        }
        let makerReader = TIFFReader(makerNote: maker.bytes)
        guard maker.bytes.count >= 12 else { throw failure("The Fujifilm metadata header is incomplete.") }
        let tags = try makerReader.directory(at: Int(makerReader.u32(8)))
        var settings: [RecipeField: String] = [:]
        var warnings = ["Photo metadata can recover only recorded settings. Recipe names, custom-bank assignments, Auto ISO limits, and missing values are not reconstructed."]
        var unknown: [String] = []
        var handled: Set<Int> = []
        var metadata = [PhotoMetadataItem(label: "Camera", value: "\(make) \(model)")]

        func first(_ tag: Int) -> Int64? {
            handled.insert(tag)
            guard let entry = tags[tag] else { return nil }
            guard entry.integers.count == 1 else {
                unknown.append(String(format: "Tag 0x%04X: unsupported value format", tag)); return nil
            }
            return entry.integers[0]
        }
        func set(_ field: RecipeField, _ value: String, tag: Int) {
            if let normalized = try? RecipeImporter.normalizedValue(value, for: field) {
                settings[field] = normalized
            } else { unknown.append(String(format: "Tag 0x%04X", tag) + ": \(field.label) value \(value) is unsupported") }
        }
        func mapped(_ tag: Int, _ field: RecipeField, _ map: [Int64: String]) {
            guard let value = first(tag) else { return }
            if let label = map[value] { set(field, label, tag: tag) }
            else { unknown.append(String(format: "Tag 0x%04X", tag) + ": \(field.label) code \(value) is unsupported") }
        }
        func scaled(_ tag: Int, _ field: RecipeField, _ divisor: Double) {
            guard let value = first(tag) else { return }
            set(field, number(Double(value) / divisor), tag: tag)
        }

        mapped(0x1401, .filmSimulation, [0: "Provia", 0x120: "Astia", 0x200: "Velvia", 0x400: "Velvia",
            0x500: "Pro Neg. Std", 0x501: "Pro Neg. Hi", 0x600: "Classic Chrome", 0x700: "Eterna",
            0x800: "Classic Negative", 0x900: "Eterna Bleach Bypass", 0xa00: "Nostalgic Negative", 0xb00: "Reala Ace"])
        if let saturation = first(0x1003) {
            let monochrome: [Int64: String] = [0x300: "Monochrome STD", 0x301: "Monochrome Red",
                0x302: "Monochrome Yellow", 0x303: "Monochrome Green", 0x310: "Sepia",
                0x500: "Acros STD", 0x501: "Acros Red", 0x502: "Acros Yellow", 0x503: "Acros Green"]
            if let film = monochrome[saturation] { set(.filmSimulation, film, tag: 0x1003) }
            else {
                let color: [Int64: String] = [0: "0", 0x80: "1", 0x100: "2", 0xc0: "3", 0xe0: "4",
                    0x180: "-1", 0x400: "-2", 0x4c0: "-3", 0x4e0: "-4"]
                if let value = color[saturation] { set(.color, value, tag: 0x1003) }
                else { unknown.append("Saturation code \(saturation) is unsupported; color was not inferred.") }
            }
        }
        mapped(0x1001, .sharpness, [0: "-4", 1: "-3", 2: "-2", 3: "0", 4: "2", 5: "3", 6: "4", 0x82: "-1", 0x84: "1"])
        mapped(0x1002, .whiteBalance, [0: "Auto", 1: "Auto (white priority)", 2: "Auto (ambience priority)",
            0x100: "Daylight", 0x200: "Shade", 0x300: "Fluorescent 1", 0x301: "Fluorescent 2",
            0x302: "Fluorescent 3", 0x400: "Incandescent", 0x600: "Underwater", 0xf00: "Custom 1",
            0xf01: "Custom 2", 0xf02: "Custom 3", 0xff0: "Kelvin"])
        if let kelvin = first(0x1005), settings[.whiteBalance] == "Kelvin" { set(.kelvin, String(kelvin), tag: 0x1005) }
        handled.insert(0x100a)
        if let fineTune = tags[0x100a] {
            let modernModel = model.uppercased().hasPrefix("X-") || model.uppercased().hasPrefix("X100")
                || model.uppercased().hasPrefix("GFX") || ["X70", "XF10"].contains(model.uppercased())
            if modernModel, fineTune.type == 9, fineTune.integers.count == 2,
               fineTune.integers.allSatisfy({ $0 % 20 == 0 && (-180...180).contains($0) }) {
                set(.wbShiftR, String(fineTune.integers[0] / 20), tag: 0x100a)
                set(.wbShiftB, String(fineTune.integers[1] / 20), tag: 0x100a)
            } else { unknown.append("White balance fine tune uses an unverified model or encoding; red and blue shifts were not inferred.") }
        }
        mapped(0x100e, .highISONR, [0: "0", 0x100: "2", 0x180: "1", 0x1c0: "3", 0x1e0: "4",
            0x200: "-2", 0x280: "-1", 0x2c0: "-3", 0x2e0: "-4"])
        scaled(0x100f, .clarity, 1000)
        scaled(0x1040, .shadow, -16)
        scaled(0x1041, .highlight, -16)
        mapped(0x1047, .grainRoughness, [0: "Off", 32: "Weak", 64: "Strong"])
        mapped(0x1048, .colorChromeEffect, [0: "Off", 32: "Weak", 64: "Strong"])
        mapped(0x104e, .colorChromeFXBlue, [0: "Off", 32: "Weak", 64: "Strong"])
        if let size = first(0x104c), size != 0 {
            if let value = [16: "Small", 32: "Large"][size] { set(.grainSize, value, tag: 0x104c) }
            else { unknown.append("Grain size code \(size) is unsupported.") }
        }
        // These two tags are signed bytes even when the stored TIFF type is undefined.
        for (tag, field) in [(0x1049, RecipeField.monoWC), (0x104b, .monoMG)] {
            handled.insert(tag)
            if let entry = tags[tag], entry.bytes.count == 1 {
                set(field, String(Int8(bitPattern: entry.bytes[0])), tag: tag)
            } else if tags[tag] != nil { unknown.append(String(format: "Tag 0x%04X", tag) + ": monochrome adjustment format is unsupported") }
        }
        let developmentDR = first(0x1403)
        if let dr = first(0x1402) {
            if dr == 0 { set(.dynamicRange, "DR-Auto", tag: 0x1402) }
            else if dr == 0x100 { set(.dynamicRange, "DR100", tag: 0x1402) }
            else if dr == 0x201 { set(.dynamicRange, "DR400", tag: 0x1402) }
            else if dr == 1, let developmentDR, [100, 200, 400].contains(developmentDR) {
                set(.dynamicRange, "DR\(developmentDR)", tag: 0x1403)
            } else { unknown.append("Dynamic range selection \(dr) could not be recovered as a supported setting.") }
        }
        if let developmentDR { metadata.append(.init(label: "Development dynamic range", value: "\(developmentDR)%")) }
        let priorityFixed = first(0x1445)
        let priorityAuto = first(0x1444)
        if let priority = first(0x1443) {
            if priority == 0 { set(.dRangePriority, "Auto", tag: 0x1443) }
            else if priority == 1, let priorityFixed, let label = [1: "Weak", 2: "Strong"][priorityFixed] {
                set(.dRangePriority, label, tag: 0x1445)
            } else { unknown.append("D range priority encoding is unsupported; Off was not assumed.") }
        }
        if let priorityAuto { metadata.append(.init(label: "D range priority result", value: [1: "Weak", 2: "Strong", 3: "Plus"][priorityAuto] ?? "Code \(priorityAuto)")) }
        if let generation = first(0x1436) {
            metadata.append(.init(label: "Image generation", value: [0: "Original image", 1: "Re-developed from RAW"][generation] ?? "Code \(generation)"))
        }
        func metaText(_ label: String, _ tag: Int, in directory: [Int: TIFFEntry]) {
            if let text = directory[tag]?.text, !text.isEmpty { metadata.append(.init(label: label, value: text)) }
        }
        metaText("Lens", 0xa434, in: exif)
        metaText("Captured", 0x9003, in: exif)
        metaText("Software", 0x0131, in: root)
        if let iso = exif[0x8827]?.integers.first { metadata.append(.init(label: "ISO used", value: String(iso))) }
        for (tag, label, suffix) in [(0x829a, "Exposure time", " s"), (0x829d, "Aperture", ""),
                                    (0x920a, "Focal length", " mm"), (0x9204, "Exposure compensation", " EV")] {
            if let value = exif[tag]?.rational {
                let rendered = tag == 0x829d ? "f/\(number(value))" : number(value) + suffix
                metadata.append(.init(label: label, value: rendered))
            }
        }
        if settings[.whiteBalance]?.hasPrefix("Custom") == true {
            warnings.append("Custom white balance reference measurements cannot be reproduced from the mode alone. Set your own reference on the camera.")
        }
        let missing = RecipeField.allCases.filter { settings[$0] == nil && ($0 != .kelvin || settings[.whiteBalance] == "Kelvin") }
        if !missing.isEmpty { warnings.append("Not recovered: " + missing.map(\.label).joined(separator: ", ") + ". These values remain unspecified.") }
        for tag in tags.keys.sorted() where !handled.contains(tag) {
            unknown.append(String(format: "MakerNote tag 0x%04X was not interpreted", tag))
        }
        let safeName = String(URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent.prefix(120))
        var notes = "Settings read from \(safeName.isEmpty ? "an original JPEG" : safeName + ".jpg").\n"
        notes += metadata.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        notes += "\nOnly recorded, recognized settings were recovered. Exposure metadata describes this photograph, not Auto ISO limits or a suggested exposure."
        var recipe = Recipe(name: safeName.isEmpty ? "From photo" : "From \(safeName)", notes: notes, settings: settings)
        // Parsing settings never changes sensor compatibility or suggests a camera bank.
        if !settings.isEmpty { warnings += try RecipeImporter.validate(recipe) }
        if !unknown.isEmpty { recipe.notes += "\nUninterpreted metadata: " + unknown.joined(separator: "; ") }
        return PhotoInspection(cameraModel: model, metadata: metadata, result: ImportResult(recipes: [recipe], warnings: warnings),
                               missingFields: missing, unrecognized: unknown)
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private static func failure(_ message: String) -> RecipeImportError { .invalid(message) }

    private static func jpegEXIF(_ data: Data) throws -> [UInt8] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else {
            throw failure("Choose an original Fujifilm JPEG. RAF, HEIF, screenshots, and edited exports are not supported by photo inspection; screenshots can use recipe import instead.")
        }
        var position = 2
        var segments = 0
        while position < bytes.count, segments < 4096 {
            guard bytes[position] == 0xff else { throw failure("The JPEG marker structure is damaged.") }
            while position < bytes.count, bytes[position] == 0xff { position += 1 }
            guard position < bytes.count else { break }
            let marker = bytes[position]; position += 1; segments += 1
            if marker == 0xda || marker == 0xd9 { break }
            if marker == 0x01 || (0xd0...0xd8).contains(marker) { continue }
            guard position + 2 <= bytes.count else { throw failure("The JPEG metadata is truncated.") }
            let length = Int(bytes[position]) * 256 + Int(bytes[position + 1])
            guard length >= 2, length <= bytes.count - position else { throw failure("The JPEG metadata length is invalid.") }
            let start = position + 2
            if marker == 0xe1, length >= 8, Array(bytes[start..<(start + 6)]) == [69, 120, 105, 102, 0, 0] {
                return Array(bytes[(start + 6)..<(position + length)])
            }
            position += length
        }
        throw failure("This JPEG has no EXIF metadata. Use the original file from your camera or memory card.")
    }
}

private struct TIFFEntry {
    let type: Int
    let count: Int
    let bytes: [UInt8]
    let littleEndian: Bool
    var text: String? {
        guard type == 2 else { return nil }
        return String(bytes: bytes.prefix(4096).prefix { $0 != 0 }, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var integers: [Int64] {
        let sizes = [1: 1, 3: 2, 4: 4, 6: 1, 8: 2, 9: 4]
        guard let size = sizes[type], count <= 64 else { return [] }
        return (0..<count).map { index in
            let raw = unsigned(at: index * size, size: size)
            switch type {
            case 6: return Int64(Int8(bitPattern: UInt8(raw)))
            case 8: return Int64(Int16(bitPattern: UInt16(raw)))
            case 9: return Int64(Int32(bitPattern: UInt32(raw)))
            default: return Int64(raw)
            }
        }
    }
    var rational: Double? {
        guard [5, 10].contains(type), count == 1 else { return nil }
        let a = unsigned(at: 0, size: 4), b = unsigned(at: 4, size: 4)
        let numerator = type == 10 ? Double(Int32(bitPattern: UInt32(a))) : Double(a)
        let denominator = type == 10 ? Double(Int32(bitPattern: UInt32(b))) : Double(b)
        guard denominator != 0 else { return nil }
        return numerator / denominator
    }
    private func unsigned(at offset: Int, size: Int) -> UInt64 {
        (0..<size).reduce(UInt64(0)) { result, index in
            result | (UInt64(bytes[offset + index]) << ((littleEndian ? index : size - index - 1) * 8))
        }
    }
}

private struct TIFFReader {
    let bytes: [UInt8]
    let littleEndian: Bool
    init(_ bytes: [UInt8]) throws {
        guard bytes.count >= 8, (Array(bytes[0..<2]) == [73, 73] || Array(bytes[0..<2]) == [77, 77]) else {
            throw RecipeImportError.invalid("The EXIF byte-order header is invalid.")
        }
        self.bytes = bytes; littleEndian = bytes[0] == 73
        guard u16(2) == 42 else { throw RecipeImportError.invalid("This EXIF format is not supported.") }
    }
    init(makerNote: [UInt8]) { bytes = makerNote; littleEndian = true }
    func u16(_ offset: Int) -> UInt16 {
        UInt16(bytes[offset + (littleEndian ? 0 : 1)]) | UInt16(bytes[offset + (littleEndian ? 1 : 0)]) << 8
    }
    func u32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ((littleEndian ? $1 : 3 - $1) * 8) }
    }
    func directory(at offset: Int) throws -> [Int: TIFFEntry] {
        guard offset >= 8, offset <= bytes.count - 2 else { throw malformed() }
        let count = Int(u16(offset))
        guard count <= 4096, count <= (bytes.count - offset - 2) / 12 else { throw malformed() }
        let typeSizes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]
        var entries: [Int: TIFFEntry] = [:]
        for index in 0..<count {
            let position = offset + 2 + index * 12
            let tag = Int(u16(position)), type = Int(u16(position + 2)), values = Int(u32(position + 4))
            guard entries[tag] == nil else { throw malformed() }
            guard let size = typeSizes[type] else {
                entries[tag] = TIFFEntry(type: type, count: values, bytes: [], littleEndian: littleEndian); continue
            }
            guard values <= bytes.count / size else { throw malformed() }
            let length = values * size
            let start = length <= 4 ? position + 8 : Int(u32(position + 8))
            guard start >= 0, start <= bytes.count, length <= bytes.count - start else { throw malformed() }
            entries[tag] = TIFFEntry(type: type, count: values, bytes: Array(bytes[start..<(start + length)]), littleEndian: littleEndian)
        }
        return entries
    }
    private func malformed() -> RecipeImportError { .invalid("The camera metadata contains an invalid directory, count, or offset. No settings were imported.") }
}
