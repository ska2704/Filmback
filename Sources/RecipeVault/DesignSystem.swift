import SwiftUI
import FujiCore

/// Fujifilm X-M5 Silver. Every colour in the interface comes from these seven values.
enum Palette {
    static let silverHighlight = Color(hex: 0xE4E5E1)
    static let satinSilver = Color(hex: 0xC8CAC8)
    static let brushedAluminum = Color(hex: 0xA6A9A7)
    static let darkMetal = Color(hex: 0x777C7C)
    static let graphite = Color(hex: 0x343638)
    static let leatheretteBlack = Color(hex: 0x151515)
    static let fujifilmRed = Color(hex: 0xC92832)

    static let accent = fujifilmRed
    static let paper = satinSilver
    static let surface = silverHighlight
    static let sidebar = leatheretteBlack
    static let ink = leatheretteBlack
    static let secondary = graphite
    static let sidebarText = silverHighlight
    static let sidebarMuted = brushedAluminum
    static let line = brushedAluminum
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Red fails small-text contrast on silver (4.3:1), so cautions pair a red symbol with black text.
struct CautionLabel: View {
    let text: String
    var symbol = "exclamationmark.triangle"
    var size: CGFloat = 12
    var body: some View {
        Label {
            Text(text).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
        } icon: { Image(systemName: symbol).foregroundStyle(Palette.accent) }
        .font(.system(size: size)).lineSpacing(3)
    }
}

struct RecipeSettingGroup: Identifiable {
    let title: String
    let fields: [RecipeField]
    var id: String { title }
    static let all: [RecipeSettingGroup] = [
        .init(title: "Film & tone", fields: [.filmSimulation, .dynamicRange, .dRangePriority, .highlight, .shadow]),
        .init(title: "Color & white balance", fields: [.whiteBalance, .kelvin, .wbShiftR, .wbShiftB, .color, .colorChromeEffect, .colorChromeFXBlue, .monoWC, .monoMG]),
        .init(title: "Detail & grain", fields: [.grainRoughness, .grainSize, .sharpness, .highISONR, .clarity, .portraitEnhancer, .smoothSkin])
    ]
}

struct SettingsGrid: View {
    let recipe: Recipe
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(RecipeSettingGroup.all) { group in
                let fields = group.fields.filter { recipe.settings[$0] != nil }
                if !fields.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.title).font(.system(size: 13, weight: .semibold))
                            .padding(.bottom, 8)
                        Rectangle().fill(Palette.ink).frame(height: 1)
                        ForEach(fields) { field in
                            HStack(alignment: .firstTextBaseline, spacing: 20) {
                                Text(field.label).foregroundStyle(Palette.secondary)
                                Spacer(minLength: 12)
                                Text(recipe.settings[field] ?? "")
                                    .fontWeight(.medium).multilineTextAlignment(.trailing)
                                    .monospacedDigit().textSelection(.enabled)
                            }.font(.system(size: 12)).padding(.vertical, 7)
                            Rectangle().fill(Palette.line.opacity(0.65)).frame(height: 0.5)
                        }
                    }
                }
            }
        }.foregroundStyle(Palette.ink)
    }
}

struct StatusNote: View {
    let text: String
    var symbol = "info.circle"
    var warning = false
    var body: some View {
        if warning { CautionLabel(text: text, symbol: symbol) }
        else {
            Label {
                Text(text).fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: symbol) }
            .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(3)
        }
    }
}
