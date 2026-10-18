import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FujiCore

struct RecipeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var recipe: Recipe
    let onSave: (Recipe) throws -> Void
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            RecipeSheetHeader(title: "Edit recipe", symbol: "slider.horizontal.3",
                              subtitle: "Leave a setting blank to keep the destination bank's value.")
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    RecipeSheetSection(title: "Recipe details") {
                        metadataRow("Name", text: $recipe.name)
                        Divider()
                        metadataRow("Creator", text: Binding(get: { recipe.author ?? "" }, set: { recipe.author = $0.isEmpty ? nil : $0 }))
                        Divider()
                        metadataRow("Source URL", text: Binding(get: { recipe.sourceURL ?? "" }, set: { recipe.sourceURL = $0.isEmpty ? nil : $0 }))
                    }
                    ForEach(RecipeSettingGroup.all, id: \.title) { group in
                        RecipeSheetSection(title: group.title) {
                            ForEach(Array(group.fields.enumerated()), id: \.element.id) { index, field in
                                if index > 0 { Divider() }
                                settingRow(field)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notes, ISO and exposure advice").font(.system(size: 13, weight: .semibold))
                        TextField("Add shooting notes…", text: $recipe.notes, axis: .vertical)
                            .lineLimit(3...6).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Notes, ISO and exposure advice")
                    }
                }.padding(24)
            }
            RecipeSheetFooter {
                if let error { sheetError(error) }
                HStack {
                    Text("\(recipe.settings.count) settings specified").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save recipe", action: save)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || recipe.settings.isEmpty)
                }
            }
        }
        .frame(width: 700, height: 660).background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.green)
    }

    private func metadataRow(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 16) {
            Text(label).frame(width: 120, alignment: .leading)
            TextField(label == "Name" ? "Recipe name" : "Optional", text: text)
                .textFieldStyle(.roundedBorder).accessibilityLabel(label)
        }.font(.system(size: 13)).padding(.vertical, 4)
    }

    private func settingRow(_ field: RecipeField) -> some View {
        let binding = Binding<String>(get: { recipe.settings[field] ?? "" }, set: { recipe.settings[field] = $0.isEmpty ? nil : $0 })
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.label).font(.system(size: 13))
                if let range = field.numericRange {
                    Text("\(range.lowerBound.formatted()) to \(range.upperBound.formatted())")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.secondary)
                }
            }
            Spacer(minLength: 12)
            if !field.options.isEmpty {
                Picker(field.label, selection: binding) {
                    Text("Not specified").tag("")
                    ForEach(field.options, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 256).accessibilityLabel(field.label)
            } else {
                TextField("Not specified", text: binding).textFieldStyle(.roundedBorder)
                    .monospacedDigit().frame(width: 128).accessibilityLabel(field.label)
            }
        }.padding(.vertical, 5)
    }

    private func save() {
        do {
            let encoded = try RecipeExporter.json(recipes: [recipe])
            let validated = try RecipeImporter.parse(encoded)
            guard let saved = validated.recipes.first else { return }
            try onSave(saved)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ImportView: View {
    @Environment(\.dismiss) private var dismiss
    let onImport: (ImportResult) throws -> Void
    @State private var text = ""
    @State private var pageURL = ""
    @State private var result: ImportResult?
    @State private var busy = false
    @State private var error: String?
    @State private var status = ""

    var body: some View {
        VStack(spacing: 0) {
            RecipeSheetHeader(title: result == nil ? "Import recipes" : "Review import", symbol: "square.and.arrow.down",
                              subtitle: result == nil ? "Paste settings, a Simu code, or JSON. Load a screenshot for local text recognition." : "Review these values before adding them to your library.")
            VStack(alignment: .leading, spacing: 16) {
                if result == nil {
                    sourceControls
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recipe text").font(.system(size: 13, weight: .semibold))
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $text).font(.system(size: 12, design: .monospaced))
                                .padding(8).scrollContentBackground(.hidden)
                                .accessibilityLabel("Recipe text").disabled(busy)
                            if text.isEmpty {
                                Text("Film Simulation: Classic Chrome\nDynamic Range: DR200\nWhite Balance: Daylight\nHighlight: -1\nShadow: +1")
                                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.secondary)
                                    .padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line))
                        Text("Files: JSON, OFR, plain text, or a recipe screenshot.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                } else if let result {
                    review(result)
                    Text("Missing settings remain unchanged on the camera. You can edit after importing.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }.padding(24).frame(maxHeight: .infinity)
            RecipeSheetFooter {
                if !status.isEmpty {
                    HStack(spacing: 8) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(status).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                }
                if let error { sheetError(error) }
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                    Spacer()
                    if result != nil { Button("Back to text") { result = nil; error = nil } }
                    Button(result == nil ? "Review import" : "Add to library", action: reviewOrImport)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(width: 760, height: 660).background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.green)
    }

    private var sourceControls: some View {
        HStack(spacing: 8) {
            TextField("https://… public recipe page", text: $pageURL)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Public recipe page URL")
                .disabled(busy)
            Button("Read page") {
                load {
                    guard let url = URL(string: pageURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw VaultError.message("Enter a complete page URL.")
                    }
                    return try await RecipeInput.fetchPage(url)
                }
            }.disabled(busy || pageURL.isEmpty)
            Button("Choose file…") { chooseFile() }.disabled(busy)
        }
    }

    private func review(_ result: ImportResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !result.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(result.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12)).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                ForEach(Array(result.recipes.enumerated()), id: \.element.id) { index, recipe in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(recipe.name).font(.system(size: 20, weight: .semibold))
                            Spacer()
                            Text("\(recipe.settings.count) settings").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }
                        if let slot = recipe.suggestedSlot {
                            Text("Source kit bank: C\(slot). Choose an X-M5 bank explicitly when writing.")
                                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }
                        SettingsGrid(recipe: recipe)
                        if !recipe.notes.isEmpty {
                            Text(recipe.notes).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reviewOrImport() {
        do {
            if let result { try onImport(result); dismiss() }
            else {
                var parsed = try RecipeImporter.parse(text)
                if let source = URL(string: pageURL), ["https", "http"].contains(source.scheme ?? "") {
                    for i in parsed.recipes.indices where parsed.recipes[i].sourceURL == nil {
                        parsed.recipes[i].sourceURL = source.absoluteString
                    }
                }
                result = parsed
                error = nil
                status = ""
            }
        } catch { self.error = error.localizedDescription }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .image, UTType(filenameExtension: "ofr") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            pageURL = ""
            load { try await RecipeInput.text(from: url) }
        }
    }

    private func load(_ operation: @escaping () async throws -> String) {
        busy = true; error = nil; result = nil; status = "Reading recipe content…"
        Task { @MainActor in
            defer { busy = false }
            do { text = try await operation(); status = "Content loaded. Review the imported settings." }
            catch { self.error = error.localizedDescription; status = "" }
        }
    }
}

struct WriteReviewView: View {
    let plan: RecipeWritePlan
    let recipeName: String
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            RecipeSheetHeader(title: "Review C\(plan.slot)", symbol: "camera",
                              subtitle: "\(plan.writes.count) changes ready for your X-M5")
            VStack(alignment: .leading, spacing: 16) {
                Text(recipeName).font(.system(size: 22, weight: .semibold))
                Text("Replacing recipe settings in “\(plan.before.name)”. The app will save your current banks before it writes, then check each change by reading it back.")
                    .font(.system(size: 13)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    HStack {
                        Text("Setting")
                        Spacer()
                        Text("New value")
                    }.font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 10).background(Palette.paper)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(plan.writes.enumerated()), id: \.offset) { index, write in
                                if index > 0 { Divider() }
                                HStack(alignment: .firstTextBaseline, spacing: 18) {
                                    Text(write.label)
                                    Spacer(minLength: 8)
                                    Text(write.displayValue).fontWeight(.medium).multilineTextAlignment(.trailing).monospacedDigit()
                                }.font(.system(size: 13)).padding(.vertical, 10)
                            }
                            if !plan.warnings.isEmpty {
                                Divider().padding(.vertical, 8)
                                ForEach(plan.warnings, id: \.self) { warning in
                                    Label(warning, systemImage: "exclamationmark.triangle")
                                        .font(.system(size: 12)).foregroundStyle(Palette.amber)
                                        .padding(.vertical, 5).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }.padding(.horizontal, 14)
                    }
                }.background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line))
                Text("Keep the camera connected until verification finishes. A failure can leave a partial change; the saved backup will remain available.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(24)
            RecipeSheetFooter {
                HStack {
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Back up & write C\(plan.slot)", action: onApply).buttonStyle(.borderedProminent)
                }
            }
        }.frame(width: 620, height: 650).background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.green)
    }
}

private struct RecipeSheetHeader: View {
    let title: String
    let symbol: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                Text(title).font(.system(size: 21, weight: .semibold))
            }.foregroundStyle(Palette.sidebarText)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.sidebarMuted)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 20)
            .background(Palette.graphite)
    }
}

private struct RecipeSheetSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            VStack(spacing: 0, content: content).padding(.horizontal, 12).padding(.vertical, 6)
                .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line))
        }
    }
}

private struct RecipeSheetFooter<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }.padding(.horizontal, 24).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface).overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

private func sheetError(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.circle")
        .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
}
