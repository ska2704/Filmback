import Foundation
import CoreFoundation

public enum RecipeImporter {
    public static func parse(_ text: String) throws -> ImportResult {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw RecipeImportError.invalid("Paste a recipe, JSON document, or Simu code first.") }
        guard input.utf8.count <= 2_000_000 else { throw RecipeImportError.invalid("The import is too large. Import a recipe file smaller than 2 MB.") }
        if input.hasPrefix("{") || input.hasPrefix("[") { return try parseJSON(input) }
        if let code = matches(#"(?i)SIMU[0-9][0-9A-Z]{8,}"#, input).first { return try parseSimu(code, surrounding: input) }
        if input.lowercased().contains("simu://") { throw RecipeImportError.invalid("This Simu link does not contain a complete supported recipe code.") }
        if let url = URL(string: input), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !input.contains("\n") {
            throw RecipeImportError.invalid("This is a page URL. Use the URL import option to load the page, or copy its recipe settings and paste them here.")
        }
        return try parseText(input)
    }

    public static func normalizedValue(_ value: String, for field: RecipeField) throws -> String {
        var clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "–", with: "-")
        if field == .kelvin { clean = clean.replacingOccurrences(of: "K", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces) }
        if let range = field.numericRange {
            guard let number = Double(clean), number.isFinite, range.contains(number),
                  abs(number / field.step - (number / field.step).rounded()) < 0.000001 else {
                throw RecipeImportError.invalid("\(field.label): ‘\(value)’ is not valid. Use \(numberString(range.lowerBound)) to \(numberString(range.upperBound)) in steps of \(numberString(field.step)).")
            }
            return numberString(number)
        }
        let key = normalizedKey(clean)
        if let exact = field.options.first(where: { normalizedKey($0) == key }) { return exact }
        let aliases: [String: String]
        switch field {
        case .filmSimulation:
            aliases = ["standard":"Provia", "proviastandard":"Provia", "velviavivid":"Velvia", "vivid":"Velvia",
                       "astiasoft":"Astia", "soft":"Astia", "classicneg":"Classic Negative", "nostalgicneg":"Nostalgic Negative",
                       "eternacinema":"Eterna", "cinema":"Eterna", "acros":"Acros STD", "acrosy":"Acros Yellow",
                       "acrosr":"Acros Red", "acrosg":"Acros Green", "monochrome":"Monochrome STD",
                       "monochromey":"Monochrome Yellow", "monochromer":"Monochrome Red", "monochromeg":"Monochrome Green",
                       "pronh":"Pro Neg. Hi", "prons":"Pro Neg. Std"]
        case .dynamicRange:
            aliases = ["100":"DR100", "100percent":"DR100", "200":"DR200", "200percent":"DR200", "400":"DR400", "400percent":"DR400", "auto":"DR-Auto"]
        case .whiteBalance:
            aliases = ["autowhitepriority":"Auto (white priority)", "whitepriority":"Auto (white priority)",
                       "autoambiencepriority":"Auto (ambience priority)", "ambiencepriority":"Auto (ambience priority)",
                       "sunny":"Daylight", "sunlight":"Daylight", "fine":"Daylight",
                       "tungsten":"Incandescent", "colortemperature":"Kelvin", "temperature":"Kelvin",
                       "fluorescentlight1":"Fluorescent 1", "fluorescentlight2":"Fluorescent 2", "fluorescentlight3":"Fluorescent 3"]
        default: aliases = [:]
        }
        if let alias = aliases[key] { return alias }
        throw RecipeImportError.invalid("\(field.label): ‘\(value)’ is not recognized. Choose one of: \(field.options.joined(separator: ", ")).")
    }

    public static func validate(_ recipe: Recipe) throws -> [String] {
        guard !recipe.settings.isEmpty else { throw RecipeImportError.invalid("The recipe has no recognized camera settings.") }
        try recipe.cover?.validate()
        for (field, value) in recipe.settings { _ = try normalizedValue(value, for: field) }
        var warnings: [String] = []
        if let priority = recipe.settings[.dRangePriority], priority != "Off",
           [.dynamicRange, .highlight, .shadow].contains(where: { recipe.settings[$0] != nil }) {
            warnings.append("\(recipe.name): D range priority overrides dynamic range and tone settings. Review these fields before applying.")
        }
        if recipe.settings[.whiteBalance] == "Kelvin", recipe.settings[.kelvin] == nil {
            warnings.append("\(recipe.name): Kelvin white balance has no temperature. Add a temperature before applying it.")
        }
        if recipe.settings[.kelvin] != nil, recipe.settings[.whiteBalance] != "Kelvin" {
            warnings.append("\(recipe.name): A temperature is present without Kelvin white balance. Review the white balance mode.")
        }
        if recipe.settings[.grainRoughness] == "Off", recipe.settings[.grainSize] != nil {
            warnings.append("\(recipe.name): Grain size has no visible effect while grain is off.")
        }
        if let slot = recipe.suggestedSlot, slot > 4 {
            warnings.append("\(recipe.name): This kit suggests C\(slot). The X-M5 has four recipe banks; select C1–C4 manually.")
        }
        return warnings
    }

    private static func parseJSON(_ input: String) throws -> ImportResult {
        let document: Any
        do { document = try JSONSerialization.jsonObject(with: Data(input.utf8)) }
        catch { throw RecipeImportError.invalid("The JSON is malformed: \(error.localizedDescription)") }
        let objects: [[String: Any]]
        if let array = document as? [[String: Any]] { objects = array }
        else if let object = document as? [String: Any] {
            if let version = object["schemaVersion"] {
                guard isInteger(version, equalTo: 1) else { throw RecipeImportError.invalid("Unsupported RecipeVault schema version. This app understands version 1.") }
            }
            if let recipes = object["recipes"] {
                guard let array = recipes as? [[String: Any]] else { throw RecipeImportError.invalid("‘recipes’ must contain a JSON array of recipe objects.") }
                objects = array
            } else { objects = [object] }
        } else { throw RecipeImportError.invalid("Use a recipe object or an array of recipe objects.") }
        guard !objects.isEmpty, objects.count <= 500 else { throw RecipeImportError.invalid("Import between 1 and 500 recipes at a time.") }
        var warnings: [String] = []
        var recipes: [Recipe] = []
        for (index, object) in objects.enumerated() {
            let ofr = object["v"] != nil
            if ofr, !isInteger(object["v"]!, equalTo: 1) {
                throw RecipeImportError.invalid("Recipe \(index + 1) uses an unsupported OFR version. This app understands OFR version 1.")
            }
            let settingObject: [String: Any]
            if let raw = object["settings"] {
                guard let parsed = raw as? [String: Any] else { throw RecipeImportError.invalid("Recipe \(index + 1): ‘settings’ must be a JSON object with named fields.") }
                settingObject = parsed
            } else { settingObject = object }
            var recipe = Recipe(name: try optionalString(object, "name") ?? "Imported recipe \(index + 1)")
            recipe.sourceURL = try optionalString(object, "sourceURL") ?? optionalString(object, "source_url")
            recipe.author = try optionalString(object, "author") ?? optionalString(object, "source_attribution")
            recipe.notes = try optionalString(object, "notes") ?? ""
            if let cover = object["cover"], !(cover is NSNull) {
                guard let coverObject = cover as? [String: Any] else {
                    throw RecipeImportError.invalid("Recipe \(index + 1): ‘cover’ must be an object containing a local filename, credit, and rendering note.")
                }
                do {
                    recipe.cover = try JSONDecoder().decode(RecipeCover.self, from: JSONSerialization.data(withJSONObject: coverObject))
                } catch {
                    throw RecipeImportError.invalid("Recipe \(index + 1): Invalid cover metadata. \(error.localizedDescription)")
                }
            }
            if let rawID = try optionalString(object, "id") {
                guard let id = UUID(uuidString: rawID) else { throw RecipeImportError.invalid("Recipe \(index + 1): ‘id’ must be a UUID.") }
                recipe.id = id
            }
            if let date = try optionalString(object, "createdAt") {
                let formatter = ISO8601DateFormatter()
                guard let parsed = formatter.date(from: date) else { throw RecipeImportError.invalid("Recipe \(index + 1): ‘createdAt’ must be an ISO 8601 date.") }
                recipe.createdAt = parsed
            }
            if let sensors = object["sensors"] {
                guard let strings = sensors as? [String] else { throw RecipeImportError.invalid("‘sensors’ must be an array of strings.") }
                recipe.sensors = strings
            }
            if let slot = object["suggestedSlot"] {
                guard let number = slot as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      (1...7).contains(number.intValue), Double(number.intValue) == number.doubleValue else {
                    throw RecipeImportError.invalid("‘suggestedSlot’ must be a whole number from 1 to 7.")
                }
                recipe.suggestedSlot = number.intValue
            }
            for key in settingObject.keys.sorted() {
                if metadataKeys.contains(key) { continue }
                guard let field = fieldForKey(key) else {
                    warnings.append("\(recipe.name): Unrecognized field ‘\(key)’ was not imported.")
                    continue
                }
                let raw = settingObject[key]!
                guard !(raw is NSNull) else {
                    warnings.append("\(recipe.name): ‘\(key)’ is null and was left unspecified.")
                    continue
                }
                let value: String
                if let string = raw as? String { value = string }
                else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { value = number.stringValue }
                else { throw RecipeImportError.invalid("\(recipe.name): ‘\(key)’ must be a string or number, not a nested object, array, or boolean.") }
                try set(field, value, recipe: &recipe)
            }
            warnings += try validate(recipe)
            if ofr, object["hash"] != nil { warnings.append("\(recipe.name): The OFR hash is not an authenticity signature and was not verified.") }
            recipes.append(recipe)
        }
        return ImportResult(recipes: recipes, warnings: warnings)
    }

    private static func parseText(_ input: String) throws -> ImportResult {
        var recipe = Recipe(name: "Imported recipe")
        var warnings: [String] = []
        var extraLines: [String] = []
        for original in input.components(separatedBy: .newlines) {
            let line = original.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "•*# "))
            if line.isEmpty { continue }
            guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
                if recipe.name == "Imported recipe", recipe.settings.isEmpty, !line.contains("http") { recipe.name = line }
                else { extraLines.append(line) }
                continue
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            let normalized = normalizedKey(key)
            if ["name", "recipename", "title"].contains(normalized) { recipe.name = value; continue }
            if ["author", "creator", "sourceattribution"].contains(normalized) { recipe.author = value; continue }
            if ["source", "url", "sourceurl"].contains(normalized) { recipe.sourceURL = value; continue }
            if ["notes", "note"].contains(normalized) { extraLines.append(value); continue }
            if ["grain", "graineffect"].contains(normalized) {
                let parts = value.components(separatedBy: CharacterSet(charactersIn: ",/"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard let roughness = parts.first, parts.count <= 2 else { throw RecipeImportError.invalid("Grain effect should be Off, Weak / Small, or Strong / Large.") }
                try set(.grainRoughness, roughness, recipe: &recipe)
                if parts.count == 2 { try set(.grainSize, parts[1], recipe: &recipe) }
                continue
            }
            if ["wbshift", "whitebalanceshift"].contains(normalized) {
                guard try parseShifts(value, recipe: &recipe) else { throw RecipeImportError.invalid("White balance shift should name both channels, for example Red +2, Blue -4.") }
                continue
            }
            guard let field = fieldForKey(key) else {
                extraLines.append(line)
                warnings.append("‘\(key)’ was preserved in notes; it is not a recognized transferable camera setting.")
                continue
            }
            if field == .whiteBalance {
                let mode = value.components(separatedBy: ",").first!.trimmingCharacters(in: .whitespaces)
                if mode.range(of: #"^\d{4,5}\s*[kK]$"#, options: .regularExpression) != nil {
                    try set(.whiteBalance, "Kelvin", recipe: &recipe)
                    try set(.kelvin, mode, recipe: &recipe)
                } else { try set(field, mode, recipe: &recipe) }
                if value.contains(",") {
                    let tail = String(value.dropFirst(mode.count + 1))
                    guard try parseShifts(tail, recipe: &recipe) else { throw RecipeImportError.invalid("The white balance suffix was not understood. Use White Balance: Auto and WB Shift: Red +2, Blue -4 on separate lines.") }
                }
            } else { try set(field, value, recipe: &recipe) }
        }
        recipe.notes = extraLines.joined(separator: "\n")
        warnings += try validate(recipe)
        return ImportResult(recipes: [recipe], warnings: warnings)
    }

    private static func parseShifts(_ value: String, recipe: inout Recipe) throws -> Bool {
        let input = value.replacingOccurrences(of: "−", with: "-")
        var found: [RecipeField: String] = [:]
        for (field, channel) in [(RecipeField.wbShiftR, "r(?:ed)?"), (RecipeField.wbShiftB, "b(?:lue)?")] {
            for pattern in ["(?i)\\b\(channel)\\s*[:=]?\\s*([+-]?\\d+)(?![\\d.])", "(?i)(?<![\\d.])([+-]?\\d+)\\s*\(channel)\\b"] {
                if let result = capture(pattern, input) { found[field] = result; break }
            }
        }
        guard found.count == 2 else { return false }
        for (field, text) in found { try set(field, text, recipe: &recipe) }
        return true
    }

    private static func set(_ field: RecipeField, _ raw: String, recipe: inout Recipe) throws {
        let normalized = try normalizedValue(raw, for: field)
        if let existing = recipe.settings[field], existing != normalized {
            throw RecipeImportError.invalid("\(recipe.name): \(field.label) appears more than once with conflicting values (‘\(existing)’ and ‘\(normalized)’). Import one recipe at a time or use a JSON array.")
        }
        recipe.settings[field] = normalized
    }

    private static let metadataKeys: Set<String> = ["v", "hash", "name", "sensors", "source_url", "source_attribution", "sourceURL", "author", "notes", "id", "createdAt", "suggestedSlot", "cover", "schemaVersion", "format"]

    private static let keyAliases: [String: RecipeField] = [
        "basesimulation": .filmSimulation, "basefilmsimulation": .filmSimulation, "simulation": .filmSimulation,
        "wbkelvin": .kelvin, "whitebalancetemperature": .kelvin, "colortemperature": .kelvin,
        "whitebalancered": .wbShiftR, "whitebalanceblue": .wbShiftB, "wbred": .wbShiftR, "wbblue": .wbShiftB,
        "wbshiftred": .wbShiftR, "wbshiftblue": .wbShiftB,
        "highlighttone": .highlight, "shadowtone": .shadow, "noisereduction": .highISONR,
        "highisonoisereduction": .highISONR, "colorchromeblue": .colorChromeFXBlue,
        "monochromaticcolorwarmcool": .monoWC, "monochromaticcolormagentagreen": .monoMG,
        "monochromewarmcool": .monoWC, "monochromemagentagreen": .monoMG, "smoothskineffect": .smoothSkin,
        "portraitenhancerlv": .portraitEnhancer
    ]

    private static func fieldForKey(_ key: String) -> RecipeField? {
        let normalized = normalizedKey(key)
        return RecipeField.allCases.first { normalizedKey($0.rawValue) == normalized || normalizedKey($0.label) == normalized } ?? keyAliases[normalized]
    }

    private static func optionalString(_ object: [String: Any], _ key: String) throws -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let string = value as? String else { throw RecipeImportError.invalid("‘\(key)’ must be text.") }
        return string.isEmpty ? nil : string
    }

    private static func isInteger(_ value: Any, equalTo expected: Int) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == Double(expected)
    }

    private static func normalizedKey(_ input: String) -> String {
        input.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func matches(_ pattern: String, _ input: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).compactMap { result in
            Range(result.range, in: input).map { String(input[$0]) }
        }
    }

    private static func capture(_ pattern: String, _ input: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let range = Range(match.range(at: 1), in: input) else { return nil }
        return String(input[range])
    }

    fileprivate static func numberString(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }

    private static func parseSimu(_ code: String, surrounding: String) throws -> ImportResult {
        guard code.uppercased().hasPrefix("SIMU1") else { throw RecipeImportError.invalid("This Simu code uses an unsupported version. RecipeVault supports SIMU1.") }
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var bits: [UInt8] = []
        for raw in code.dropFirst(5).uppercased() {
            let letter: Character = raw == "O" ? "0" : (raw == "I" || raw == "L" ? "1" : raw)
            guard let value = alphabet.firstIndex(of: letter) else { throw RecipeImportError.invalid("The Simu code contains an invalid character: \(raw).") }
            bits += (0..<5).reversed().map { UInt8((value >> $0) & 1) }
        }
        let trailing = bits.count % 8
        guard trailing <= 4, bits.suffix(trailing).allSatisfy({ $0 == 0 }) else { throw RecipeImportError.invalid("The Simu code has invalid Base32 padding or is truncated.") }
        if trailing > 0 { bits.removeLast(trailing) }
        var bytes: [UInt8] = []
        for offset in stride(from: 0, to: bits.count, by: 8) {
            bytes.append(bits[offset..<(offset + 8)].reduce(0) { ($0 << 1) | $1 })
        }
        guard bytes.count >= 5, let checksum = bytes.last,
              crc8(Array(bytes.dropLast())) == checksum else { throw RecipeImportError.invalid("The Simu checksum does not match. Copy the complete code again; no settings were imported.") }
        var reader = BitReader(bytes: Array(bytes.dropLast()))
        let flags = try reader.read(8)
        guard flags == 0 || flags == 1 else { throw RecipeImportError.invalid("The Simu code has unsupported flags.") }
        let count = flags == 1 ? try reader.read(3) + 1 : 1
        guard count <= 7 else { throw RecipeImportError.invalid("A Simu kit can contain at most seven slots.") }
        var names: [String] = []
        var kitName: String?
        var sourceURL: String?
        if let token = surrounding.components(separatedBy: .whitespacesAndNewlines).first(where: { $0.contains(code) && $0.contains("://") }),
           let url = URLComponents(string: token) {
            let query = url.percentEncodedFragment.map { fragment -> String in
                fragment.split(separator: "&").dropFirst().joined(separator: "&")
            } ?? url.percentEncodedQuery ?? ""
            var queryComponents = URLComponents()
            queryComponents.percentEncodedQuery = query
            names = queryComponents.queryItems?.filter { $0.name == "r" }.compactMap(\.value) ?? []
            kitName = queryComponents.queryItems?.first { $0.name == "n" }?.value
            sourceURL = token
        }
        if kitName == nil, let heading = surrounding.components(separatedBy: .newlines).first,
           !heading.uppercased().contains("SIMU"), !heading.contains("://") {
            kitName = heading.components(separatedBy: "·").first?.trimmingCharacters(in: .whitespaces)
        }
        var recipes: [Recipe] = []
        var warnings: [String] = []
        var slots = Set<Int>()
        for index in 0..<count {
            let slot: Int? = flags == 1 ? try reader.read(3) + 1 : nil
            if let slot {
                guard slot <= 7, slots.insert(slot).inserted else { throw RecipeImportError.invalid("The Simu kit contains an invalid or duplicate slot.") }
            }
            let title = names.indices.contains(index) ? names[index] : (flags == 0 ? kitName ?? "Imported Simu recipe" : "\(kitName ?? "Simu kit") C\(slot!)")
            var recipe = Recipe(name: title, sourceURL: sourceURL, suggestedSlot: slot)
            let mask = try reader.read(18)
            for fieldIndex in 0..<18 where mask & (1 << (17 - fieldIndex)) != 0 {
                try readSimuField(fieldIndex, reader: &reader, recipe: &recipe)
            }
            warnings += try validate(recipe)
            recipes.append(recipe)
        }
        guard reader.remaining < 8, try reader.remaining == 0 || reader.read(reader.remaining) == 0 else {
            throw RecipeImportError.invalid("The Simu code contains unexpected trailing data.")
        }
        return ImportResult(recipes: recipes, warnings: warnings)
    }

    private static func readSimuField(_ index: Int, reader: inout BitReader, recipe: inout Recipe) throws {
        let film = ["Provia", "Velvia", "Astia", "Pro Neg. Hi", "Pro Neg. Std", "Monochrome STD", "Monochrome Yellow", "Monochrome Red", "Monochrome Green", "Sepia", "Classic Chrome", "Acros STD", "Acros Yellow", "Acros Red", "Acros Green", "Eterna", "Classic Negative", "Eterna Bleach Bypass", "Nostalgic Negative", "Reala Ace"]
        let wb = ["Auto", "Daylight", "Incandescent", "Underwater", "Fluorescent 1", "Fluorescent 2", "Fluorescent 3", "Shade", "Custom 1", "Custom 2", "Custom 3", "Auto (white priority)", "Auto (ambience priority)", "Kelvin"]
        func enumValue(_ value: Int, _ options: [String]) throws -> String {
            guard options.indices.contains(value) else { throw RecipeImportError.invalid("The Simu code has an invalid field index (field \(index)).") }
            return options[value]
        }
        switch index {
        case 0: try set(.filmSimulation, enumValue(reader.read(5), film), recipe: &recipe)
        case 1: try set(.dRangePriority, enumValue(reader.read(2), ["Off", "Weak", "Strong", "Auto"]), recipe: &recipe)
        case 2: try set(.dynamicRange, enumValue(reader.read(2), ["DR100", "DR200", "DR400", "DR-Auto"]), recipe: &recipe)
        case 3, 4: try set(index == 3 ? .monoWC : .monoMG, String(reader.read(6) - 18), recipe: &recipe)
        case 5:
            let grain = try reader.read(3)
            guard grain <= 4 else { throw RecipeImportError.invalid("The Simu grain setting is invalid.") }
            recipe.settings[.grainRoughness] = grain == 0 ? "Off" : (grain % 2 == 1 ? "Weak" : "Strong")
            if grain != 0 { recipe.settings[.grainSize] = grain <= 2 ? "Small" : "Large" }
        case 6, 7, 8:
            let field: RecipeField = index == 6 ? .colorChromeEffect : (index == 7 ? .colorChromeFXBlue : .smoothSkin)
            try set(field, enumValue(reader.read(2), ["Off", "Weak", "Strong"]), recipe: &recipe)
        case 9:
            let mode = try reader.read(4)
            try set(.whiteBalance, enumValue(mode, wb), recipe: &recipe)
            if mode == 13 { try set(.kelvin, String(reader.read(11) * 10 + 2000), recipe: &recipe) }
        case 10, 11: try set(index == 10 ? .wbShiftR : .wbShiftB, String(reader.read(5) - 9), recipe: &recipe)
        case 12, 13: try set(index == 12 ? .highlight : .shadow, numberString(Double(reader.read(4)) / 2 - 2), recipe: &recipe)
        case 14, 15, 16:
            let field: RecipeField = index == 14 ? .color : (index == 15 ? .sharpness : .highISONR)
            try set(field, String(reader.read(4) - 4), recipe: &recipe)
        case 17: try set(.clarity, String(reader.read(4) - 5), recipe: &recipe)
        default: throw RecipeImportError.invalid("Unknown Simu field.")
        }
    }

    private static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc &<< 1) ^ 0x07 : crc &<< 1 }
        }
        return crc
    }

    private struct BitReader {
        let bytes: [UInt8]
        var cursor = 0
        var remaining: Int { bytes.count * 8 - cursor }
        mutating func read(_ count: Int) throws -> Int {
            guard count >= 0, count <= remaining else { throw RecipeImportError.invalid("The Simu code is truncated. Copy the entire code again.") }
            var value = 0
            for _ in 0..<count {
                value = (value << 1) | Int((bytes[cursor / 8] >> (7 - cursor % 8)) & 1)
                cursor += 1
            }
            return value
        }
    }
}

public enum RecipeExporter {
    public static func json(recipes: [Recipe]) throws -> String {
        struct Document: Encodable { let format = "RecipeVault"; let schemaVersion = 1; let recipes: [Recipe] }
        for recipe in recipes { _ = try RecipeImporter.validate(recipe) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(Document(recipes: recipes)), as: UTF8.self)
    }

    public static func ofr(recipe: Recipe) throws -> String {
        _ = try RecipeImporter.validate(recipe)
        let isMono = recipe.settings[.filmSimulation].map { $0.hasPrefix("Acros") || $0.hasPrefix("Monochrome") || $0 == "Sepia" } ?? false
        let required: [RecipeField] = [.filmSimulation, .dRangePriority, .grainRoughness, .whiteBalance, .wbShiftR, .wbShiftB, .sharpness, .highISONR, .clarity]
        var missing = required.filter { recipe.settings[$0] == nil }
        if !isMono { missing += [.color, .colorChromeEffect, .colorChromeFXBlue].filter { recipe.settings[$0] == nil } }
        if recipe.settings[.dRangePriority] == "Off" { missing += [.dynamicRange, .highlight, .shadow].filter { recipe.settings[$0] == nil } }
        if recipe.settings[.grainRoughness] != "Off", recipe.settings[.grainSize] == nil { missing.append(.grainSize) }
        if recipe.settings[.whiteBalance] == "Kelvin", recipe.settings[.kelvin] == nil { missing.append(.kelvin) }
        guard missing.isEmpty else { throw RecipeImportError.invalid("OFR requires \(missing.map(\.label).joined(separator: ", ")). Export RecipeVault JSON to preserve this partial recipe.") }
        guard recipe.name.utf8.count <= 25, recipe.name.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw RecipeImportError.invalid("OFR names must contain at most 25 ASCII characters. Shorten the name or export RecipeVault JSON.")
        }
        var object: [String: Any] = ["v": 1, "name": recipe.name, "sensors": recipe.sensors]
        if let url = recipe.sourceURL { object["source_url"] = url }
        if let author = recipe.author { object["source_attribution"] = author }
        let priorityActive = recipe.settings[.dRangePriority] != "Off"
        for (field, raw) in recipe.settings {
            if priorityActive && [.dynamicRange, .highlight, .shadow].contains(field) { continue }
            if isMono && [.color, .colorChromeEffect, .colorChromeFXBlue].contains(field) { continue }
            if !isMono && [.monoWC, .monoMG].contains(field) { continue }
            if field == .grainSize && recipe.settings[.grainRoughness] == "Off" { continue }
            if field == .kelvin && recipe.settings[.whiteBalance] != "Kelvin" { continue }
            guard let key = ofrKeys[field] else { throw RecipeImportError.invalid("OFR version 1 cannot carry \(field.label). Export RecipeVault JSON to retain every setting.") }
            let value = try RecipeImporter.normalizedValue(raw, for: field)
            if field.numericRange != nil {
                let number = Double(value)!
                if [.monoWC, .monoMG].contains(field), !(-9...9).contains(number) { throw RecipeImportError.invalid("OFR version 1 only permits monochrome toning from -9 to +9. Export RecipeVault JSON to retain this value.") }
                if field == .kelvin, number < 2500 { throw RecipeImportError.invalid("OFR version 1 requires Kelvin temperatures of at least 2500 K. Export RecipeVault JSON to retain this value.") }
                object[key] = number
            } else { object[key] = value }
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static let ofrKeys: [RecipeField: String] = [
        .filmSimulation: "film_simulation", .dynamicRange: "dynamic_range", .dRangePriority: "d_range_priority",
        .grainRoughness: "grain_roughness", .grainSize: "grain_size", .colorChromeEffect: "color_chrome_effect",
        .colorChromeFXBlue: "color_chrome_fx_blue", .whiteBalance: "white_balance", .kelvin: "wb_kelvin",
        .wbShiftR: "white_balance_red", .wbShiftB: "white_balance_blue", .highlight: "highlight", .shadow: "shadow",
        .color: "color", .sharpness: "sharpness", .highISONR: "high_iso_nr", .clarity: "clarity",
        .monoWC: "monochromatic_color_warm_cool", .monoMG: "monochromatic_color_magenta_green"
    ]
}
