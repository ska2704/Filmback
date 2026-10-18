import Foundation

public enum RecipeField: String, CaseIterable, Codable, Identifiable, Sendable {
    case filmSimulation, dynamicRange, dRangePriority, grainRoughness, grainSize
    case colorChromeEffect, colorChromeFXBlue, whiteBalance, kelvin, wbShiftR, wbShiftB
    case highlight, shadow, color, sharpness, highISONR, clarity, monoWC, monoMG, smoothSkin, portraitEnhancer

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .filmSimulation: return "Film simulation"
        case .dynamicRange: return "Dynamic range"
        case .dRangePriority: return "D range priority"
        case .grainRoughness: return "Grain roughness"
        case .grainSize: return "Grain size"
        case .colorChromeEffect: return "Color Chrome effect"
        case .colorChromeFXBlue: return "Color Chrome FX Blue"
        case .whiteBalance: return "White balance"
        case .kelvin: return "White balance temperature (K)"
        case .wbShiftR: return "WB shift red"
        case .wbShiftB: return "WB shift blue"
        case .highlight: return "Highlight"
        case .shadow: return "Shadow"
        case .color: return "Color"
        case .sharpness: return "Sharpness"
        case .highISONR: return "High ISO noise reduction"
        case .clarity: return "Clarity"
        case .monoWC: return "Monochrome warm/cool"
        case .monoMG: return "Monochrome magenta/green"
        case .smoothSkin: return "Smooth skin effect"
        case .portraitEnhancer: return "Portrait enhancer"
        }
    }

    public var options: [String] {
        switch self {
        case .filmSimulation:
            return ["Provia", "Velvia", "Astia", "Classic Chrome", "Pro Neg. Hi", "Pro Neg. Std",
                    "Classic Negative", "Eterna", "Eterna Bleach Bypass", "Nostalgic Negative", "Reala Ace",
                    "Acros STD", "Acros Yellow", "Acros Red", "Acros Green", "Monochrome STD",
                    "Monochrome Yellow", "Monochrome Red", "Monochrome Green", "Sepia"]
        case .dynamicRange: return ["DR100", "DR200", "DR400", "DR-Auto"]
        case .dRangePriority: return ["Off", "Auto", "Weak", "Strong"]
        case .grainRoughness, .colorChromeEffect, .colorChromeFXBlue, .smoothSkin: return ["Off", "Weak", "Strong"]
        case .portraitEnhancer: return ["Off", "Weak", "Medium", "Strong"]
        case .grainSize: return ["Small", "Large"]
        case .whiteBalance:
            return ["Auto", "Auto (white priority)", "Auto (ambience priority)", "Daylight", "Shade",
                    "Incandescent", "Fluorescent 1", "Fluorescent 2", "Fluorescent 3", "Kelvin",
                    "Underwater", "Custom 1", "Custom 2", "Custom 3"]
        default: return []
        }
    }

    public var numericRange: ClosedRange<Double>? {
        switch self {
        case .kelvin: return 2000...10000
        case .wbShiftR, .wbShiftB: return -9...9
        case .highlight, .shadow: return -2...4
        case .color, .sharpness, .highISONR: return -4...4
        case .clarity: return -5...5
        case .monoWC, .monoMG: return -18...18
        default: return nil
        }
    }

    public var step: Double { self == .highlight || self == .shadow ? 0.5 : 1 }
}

public struct RecipeCover: Codable, Equatable, Sendable {
    public var filename: String
    public var credit: String
    public var sourceURL: String?
    public var renderingNote: String

    public init(filename: String, credit: String, sourceURL: String? = nil, renderingNote: String) {
        self.filename = filename
        self.credit = credit
        self.sourceURL = sourceURL
        self.renderingNote = renderingNote
    }

    public var hasSafeFilename: Bool {
        filename.utf8.count <= 255 && filename.range(
            of: #"\A[A-Za-z0-9][A-Za-z0-9._ -]*\.(?i:jpg|jpeg|png)\z"#,
            options: .regularExpression) != nil
    }

    public func validate() throws {
        guard hasSafeFilename else {
            throw RecipeImportError.invalid("The cover filename must be a local JPG or PNG basename using letters, numbers, spaces, periods, hyphens, or underscores.")
        }
        guard !credit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !renderingNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecipeImportError.invalid("A recipe cover must include its credit and rendering note.")
        }
        if let sourceURL {
            guard let url = URLComponents(string: sourceURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty else {
                throw RecipeImportError.invalid("The cover source URL must use HTTP or HTTPS.")
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case filename, credit, sourceURL, renderingNote }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        filename = try values.decode(String.self, forKey: .filename)
        credit = try values.decode(String.self, forKey: .credit)
        sourceURL = try values.decodeIfPresent(String.self, forKey: .sourceURL)
        renderingNote = try values.decode(String.self, forKey: .renderingNote)
        try validate()
    }
}

public struct Recipe: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var sourceURL: String?
    public var author: String?
    public var notes: String
    public var settings: [RecipeField: String]
    public var createdAt: Date
    public var sensors: [String]
    public var suggestedSlot: Int?
    public var cover: RecipeCover?

    public init(id: UUID = UUID(), name: String, sourceURL: String? = nil, author: String? = nil,
                notes: String = "", settings: [RecipeField: String] = [:], createdAt: Date = Date(),
                sensors: [String] = [], suggestedSlot: Int? = nil, cover: RecipeCover? = nil) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.author = author
        self.notes = notes
        self.settings = settings
        self.createdAt = createdAt
        self.sensors = sensors
        self.suggestedSlot = suggestedSlot
        self.cover = cover
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sourceURL, author, notes, settings, createdAt, sensors, suggestedSlot, cover
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        sourceURL = try values.decodeIfPresent(String.self, forKey: .sourceURL)
        author = try values.decodeIfPresent(String.self, forKey: .author)
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        sensors = try values.decodeIfPresent([String].self, forKey: .sensors) ?? []
        suggestedSlot = try values.decodeIfPresent(Int.self, forKey: .suggestedSlot)
        cover = try values.decodeIfPresent(RecipeCover.self, forKey: .cover)
        let raw = try values.decode([String: String].self, forKey: .settings)
        settings = [:]
        for (key, value) in raw {
            guard let field = RecipeField(rawValue: key) else {
                throw DecodingError.dataCorruptedError(forKey: .settings, in: values,
                    debugDescription: "Unknown recipe field: \(key). Update RecipeVault before opening this file.")
            }
            settings[field] = value
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try values.encodeIfPresent(author, forKey: .author)
        try values.encode(notes, forKey: .notes)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(sensors, forKey: .sensors)
        try values.encodeIfPresent(suggestedSlot, forKey: .suggestedSlot)
        try values.encodeIfPresent(cover, forKey: .cover)
        try values.encode(Dictionary(uniqueKeysWithValues: settings.map { ($0.key.rawValue, $0.value) }), forKey: .settings)
    }
}

public struct ImportResult: Sendable {
    public var recipes: [Recipe]
    public var warnings: [String]
    public init(recipes: [Recipe], warnings: [String] = []) {
        self.recipes = recipes
        self.warnings = warnings
    }
}

public enum RecipeImportError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
