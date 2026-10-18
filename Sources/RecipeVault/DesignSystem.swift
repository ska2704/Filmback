import SwiftUI
import FujiCore

enum Palette {
    static let green = Color(red: 0.08, green: 0.36, blue: 0.27)
    static let paper = Color(red: 0.94, green: 0.95, blue: 0.94)
    static let surface = Color(red: 0.985, green: 0.985, blue: 0.975)
    static let graphite = Color(red: 0.12, green: 0.14, blue: 0.14)
    static let ink = Color(red: 0.12, green: 0.15, blue: 0.14)
    static let secondary = Color(red: 0.37, green: 0.40, blue: 0.39)
    static let sidebarText = Color(red: 0.95, green: 0.96, blue: 0.94)
    static let sidebarMuted = Color(red: 0.65, green: 0.70, blue: 0.67)
    static let line = Color(red: 0.81, green: 0.83, blue: 0.81)
    static let amber = Color(red: 0.53, green: 0.30, blue: 0.08)
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
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: { Image(systemName: symbol) }
        .font(.system(size: 12)).foregroundStyle(warning ? Palette.amber : Palette.secondary)
        .lineSpacing(3)
    }
}
