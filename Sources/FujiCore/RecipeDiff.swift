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

    public enum BankStatus: Equatable, Sendable { case unknown, noChange, changed, notRead }

    /// The changes loading this recipe would actually make. Portrait Enhancer and smooth skin are never written,
    /// and a monochrome recipe leaves chrome, color and WB shift alone.
    public static func loadableChanges(from current: Recipe?, to target: Recipe) -> [RecipeSettingChange] {
        var ignored: Set<RecipeField> = [.portraitEnhancer, .smoothSkin]
        if let film = target.settings[.filmSimulation], let code = RecipeWireCodec.filmCodes[film], RecipeWireCodec.monochromeCodes.contains(code) {
            ignored.formUnion([.colorChromeEffect, .colorChromeFXBlue, .color, .wbShiftR, .wbShiftB])
        }
        return changes(from: current, to: target).filter { !ignored.contains($0.field) }
    }

    /// Compares what's known about a bank with a recipe. A setting the read couldn't see is never called changed.
    public static func status(bankName: String?, bank: Recipe?, target: Recipe) -> BankStatus {
        guard let bank else { return .unknown }
        let changes = loadableChanges(from: bank, to: target)
        if bankName != PTP.safeName(target.name) || changes.contains(where: { $0.current != nil }) { return .changed }
        return changes.isEmpty ? .noChange : .notRead
    }

    private static func same(_ first: String?, _ second: String) -> Bool {
        guard let first else { return false }
        if first == second { return true }
        if let a = Double(first), let b = Double(second) { return a == b }
        return false
    }
}
