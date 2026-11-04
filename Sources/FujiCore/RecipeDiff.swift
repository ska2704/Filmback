import Foundation

public struct RecipeSettingChange: Identifiable, Equatable, Sendable {
    public var id: RecipeField { field }
    public let field: RecipeField
    public let current: String?
    public let target: String
    public init(field: RecipeField, current: String?, target: String) {
        self.field = field; self.current = current; self.target = target
    }
}

public enum RecipeDiff {
    /// What would change if `target` replaced `current`. Fields `target` leaves out stay as they are.
    public static func changes(from current: Recipe?, to target: Recipe) -> [RecipeSettingChange] {
        RecipeField.allCases.compactMap { field in
            guard let wanted = target.settings[field] else { return nil }
            if field == .kelvin, target.settings[.whiteBalance] != "Kelvin" { return nil }
            if field == .grainSize, target.settings[.grainRoughness] == "Off" { return nil }
            let existing = current?.settings[field]
            return same(existing, wanted) ? nil : RecipeSettingChange(field: field, current: existing, target: wanted)
        }
    }

    private static func same(_ first: String?, _ second: String) -> Bool {
        guard let first else { return false }
        if first == second { return true }
        if let a = Double(first), let b = Double(second) { return a == b }
        return false
    }
}
