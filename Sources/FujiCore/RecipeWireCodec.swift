import Foundation

public enum RecipeWireCodec {
    public static let filmCodes: [String: Int] = ["Provia":1,"Velvia":2,"Astia":3,"Pro Neg. Hi":4,"Pro Neg. Std":5,"Monochrome STD":6,"Monochrome Yellow":7,"Monochrome Red":8,"Monochrome Green":9,"Sepia":10,"Classic Chrome":11,"Acros STD":12,"Acros Yellow":13,"Acros Red":14,"Acros Green":15,"Eterna":16,"Classic Negative":17,"Eterna Bleach Bypass":18,"Nostalgic Negative":19,"Reala Ace":20]
    public static let whiteBalanceCodes: [String: Int] = ["Auto":2,"Auto (white priority)":32800,"Auto (ambience priority)":32801,"Daylight":4,"Incandescent":6,"Underwater":8,"Fluorescent 1":32769,"Fluorescent 2":32770,"Fluorescent 3":32771,"Shade":32774,"Kelvin":32775,"Custom 1":32776,"Custom 2":32777,"Custom 3":32778]
    public static let nrCodes: [Int: Int] = [-4:32768,-3:28672,-2:16384,-1:12288,0:8192,1:4096,2:0,3:24576,4:20480]
    public static let fieldCodes: [RecipeField: UInt16] = [.dynamicRange:0xD190,.dRangePriority:0xD191,.filmSimulation:0xD192,.monoWC:0xD193,.monoMG:0xD194,.grainRoughness:0xD195,.grainSize:0xD195,.colorChromeEffect:0xD196,.colorChromeFXBlue:0xD197,.smoothSkin:0xD198,.whiteBalance:0xD199,.wbShiftR:0xD19A,.wbShiftB:0xD19B,.kelvin:0xD19C,.highlight:0xD19D,.shadow:0xD19E,.color:0xD19F,.sharpness:0xD1A0,.highISONR:0xD1A1,.clarity:0xD1A2]
    public static let monochromeCodes: Set<Int> = [6,7,8,9,10,12,13,14,15]
    public static let writeOrder: [UInt16] = [0xD192,0xD191,0xD190,0xD193,0xD194,0xD195,0xD196,0xD197,0xD199,0xD19C,0xD19A,0xD19B,0xD19D,0xD19E,0xD19F,0xD1A0,0xD1A1,0xD1A2]
    public static var writableProperties: Set<UInt16> { Set(writeOrder) }

    public static func encode(_ recipe: Recipe, baseline: CameraSlotSnapshot) throws -> (writes: [PTPPropertyWrite], warnings: [String]) {
        var values: [UInt16: PTPPropertyWrite] = [:]; var warnings: [String] = []
        func lookup(_ field: RecipeField, _ value: String, _ mapping: [String: Int]) throws -> Int {
            guard let number = mapping[value] else { throw PTPError.unsupported("Invalid \(field.label): \(value)") }; return number
        }
        func base(_ property: UInt16) throws -> Int {
            guard let data = baseline.properties[property] else { throw PTPError.unsupported(String(format: "Read camera property 0x%04X before preparing this recipe.", property)) }
            return try PTP.scalar(data)
        }
        let simulation = try recipe.settings[.filmSimulation].map { try lookup(.filmSimulation, $0, filmCodes) } ?? base(0xD192)
        let mono = monochromeCodes.contains(simulation)
        let priority = try recipe.settings[.dRangePriority].map { try lookup(.dRangePriority, $0, ["Off":0,"Weak":1,"Strong":2,"Auto":32768]) } ?? base(0xD191)
        let wb = try recipe.settings[.whiteBalance].map { try lookup(.whiteBalance, $0, whiteBalanceCodes) } ?? base(0xD199)
        for (field, value) in recipe.settings {
            if field == .portraitEnhancer {
                warnings.append("Portrait enhancer is not mapped for X-M5 USB writing. Set it to \(value) on the camera.")
                continue
            }
            guard let code = fieldCodes[field] else { continue }
            if field == .grainSize || field == .grainRoughness { continue }
            if field == .smoothSkin { warnings.append("Smooth skin is not mapped for X-M5. It will remain unchanged."); continue }
            if mono && [.colorChromeEffect,.colorChromeFXBlue,.color,.wbShiftR,.wbShiftB].contains(field) {
                warnings.append("\(field.label) is inactive under monochrome and will remain unchanged."); continue
            }
            if !mono && [.monoWC,.monoMG].contains(field) { warnings.append("\(field.label) applies only to monochrome and will remain unchanged."); continue }
            if priority != 0 && [.dynamicRange,.highlight,.shadow].contains(field) { warnings.append("\(field.label) is controlled by D range priority and will remain unchanged."); continue }
            if field == .kelvin && wb != 0x8007 { warnings.append("Kelvin is inactive under this white balance and will remain unchanged."); continue }
            let number: Int
            switch field {
            case .filmSimulation: number = try lookup(field,value,filmCodes)
            case .whiteBalance: number = try lookup(field,value,whiteBalanceCodes)
            case .dynamicRange: number = try lookup(field,value,["DR-Auto":0,"DR100":100,"DR200":200,"DR400":400])
            case .dRangePriority: number = try lookup(field,value,["Off":0,"Weak":1,"Strong":2,"Auto":32768])
            case .colorChromeEffect,.colorChromeFXBlue: number = try lookup(field,value,["Off":1,"Weak":2,"Strong":3])
            default:
                guard let n = Double(value), n.isFinite, let range = field.numericRange, range.contains(n), abs(n / field.step - (n / field.step).rounded()) < 0.0001 else { throw PTPError.unsupported("\(field.label) is outside the supported range or step: \(value)") }
                if field == .highISONR { number = nrCodes[Int(n)]! }
                else if [.wbShiftR,.wbShiftB,.kelvin].contains(field) { number = Int(n) }
                else { number = Int((n * 10).rounded()) }
            }
            values[code] = PTPPropertyWrite(property: code, data: PTP.u16(UInt16(truncatingIfNeeded: number)), label: field.label, displayValue: value)
        }
        if recipe.settings[.grainRoughness] != nil || recipe.settings[.grainSize] != nil {
            let old = try base(0xD195)
            let roughness = recipe.settings[.grainRoughness] ?? ([1:"Off",6:"Off",2:"Weak",3:"Strong",4:"Weak",5:"Strong"][old])
            let size = recipe.settings[.grainSize] ?? ([2:"Small",3:"Small",4:"Large",5:"Large"][old])
            let grain: Int
            if roughness == "Off" { grain = 1 }
            else {
                guard ["Weak","Strong"].contains(roughness), ["Small","Large"].contains(size) else { throw PTPError.unsupported("Specify both grain roughness and size when enabling grain.") }
                grain = (roughness == "Weak" ? 2 : 3) + (size == "Large" ? 2 : 0)
            }
            values[0xD195] = PTPPropertyWrite(property: 0xD195, data: PTP.u16(UInt16(grain)), label: "Grain", displayValue: grain == 1 ? "Off" : "\(roughness!) \(size!)")
        }
        return (writeOrder.compactMap { values[$0] }, warnings.sorted())
    }

    public static func decode(_ snapshot: CameraSlotSnapshot) -> Recipe {
        var settings: [RecipeField:String] = [:]
        func enumValue(_ mapping: [String:Int], _ n: Int) -> String? { mapping.first { $0.value == n }?.key }
        let signed: Set<RecipeField> = [.monoWC,.monoMG,.wbShiftR,.wbShiftB,.highlight,.shadow,.color,.sharpness,.clarity]
        for field in RecipeField.allCases {
            guard field != .grainSize, field != .grainRoughness, field != .smoothSkin, let code = fieldCodes[field], let data = snapshot.properties[code], let n = try? PTP.scalar(data,signed:signed.contains(field)), n != -32768, n != 65535 else { continue }
            switch field {
            case .filmSimulation: settings[field] = enumValue(filmCodes,n)
            case .whiteBalance: settings[field] = enumValue(whiteBalanceCodes,n)
            case .dynamicRange: settings[field] = enumValue(["DR-Auto":0,"DR100":100,"DR200":200,"DR400":400],n)
            case .dRangePriority: settings[field] = enumValue(["Off":0,"Weak":1,"Strong":2,"Auto":32768],n)
            case .colorChromeEffect,.colorChromeFXBlue: settings[field] = enumValue(["Off":1,"Weak":2,"Strong":3],n)
            case .highISONR: settings[field] = nrCodes.first { $0.value == n }.map { String($0.key) }
            case .kelvin,.wbShiftR,.wbShiftB: settings[field] = String(n)
            default: settings[field] = n % 10 == 0 ? String(n / 10) : String(Double(n) / 10)
            }
        }
        if let data = snapshot.properties[0xD195], let grain = try? PTP.scalar(data) {
            settings[.grainRoughness] = [1:"Off",6:"Off",2:"Weak",3:"Strong",4:"Weak",5:"Strong"][grain]
            settings[.grainSize] = [2:"Small",3:"Small",4:"Large",5:"Large"][grain]
        }
        return Recipe(name: snapshot.name, notes: "Read from camera C\(snapshot.slot). Only understood recipe settings are included. Exposure, image format and other camera settings are not part of this recipe.", settings: settings, suggestedSlot: snapshot.slot)
    }
}
