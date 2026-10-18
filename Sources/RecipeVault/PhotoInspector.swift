import AppKit
import FujiCore
import SwiftUI
import UniformTypeIdentifiers

struct PhotoInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    let onImport: (ImportResult) throws -> Void
    @State private var inspection: PhotoInspection?
    @State private var recipeName = ""
    @State private var filename = ""
    @State private var error: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var showUnrecognized = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Label("Inspect a photograph", systemImage: "photo")
                    .font(.system(size: 21, weight: .semibold)).foregroundStyle(Palette.sidebarText)
                Text("Recover recorded Fujifilm settings from an original camera JPEG.")
                    .font(.system(size: 12)).foregroundStyle(Palette.sidebarMuted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24).background(Palette.graphite)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(filename.isEmpty ? "Choose a camera original" : filename).font(.system(size: 14, weight: .semibold))
                            Text("JPEG · read locally · source file stays unchanged")
                                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }
                        Spacer()
                        Button(filename.isEmpty ? "Choose JPEG…" : "Choose another…", action: choosePhoto).disabled(busy)
                    }
                    if let inspection {
                        if !inspection.result.recipes[0].settings.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Save recovered settings as").font(.system(size: 13, weight: .semibold))
                                TextField("Recipe name", text: $recipeName).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Recovered recipe name")
                            }
                            SettingsGrid(recipe: inspection.result.recipes[0])
                        } else {
                            StatusNote(text: "This photograph has camera metadata, but no supported recipe values could be recovered.", warning: true)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Photograph details").font(.system(size: 13, weight: .semibold))
                            Divider()
                            ForEach(Array(inspection.metadata.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.label).foregroundStyle(Palette.secondary)
                                    Spacer(minLength: 18)
                                    Text(item.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                                }.font(.system(size: 12)).monospacedDigit()
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(inspection.result.warnings, id: \.self) { warning in
                                StatusNote(text: warning, warning: true)
                            }
                        }
                        if !inspection.unrecognized.isEmpty {
                            DisclosureGroup("Uninterpreted metadata (\(inspection.unrecognized.count))", isExpanded: $showUnrecognized) {
                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(inspection.unrecognized, id: \.self) { item in
                                        Text(item).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.top, 8)
                            }.font(.system(size: 12, weight: .medium))
                        }
                    } else if !busy {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Find the settings behind a photograph.").font(.system(size: 20, weight: .semibold))
                            Text("Choose a JPEG copied directly from a Fujifilm camera or memory card. Review the recorded film simulation, tone, white balance, and other supported settings, then save them as an editable recipe.")
                                .font(.system(size: 13)).lineSpacing(4).foregroundStyle(Palette.secondary)
                            StatusNote(text: "Edited exports and social media downloads may remove camera metadata. RAF and HEIF inspection is not available yet. To read a screenshot of recipe settings, use Import recipes.")
                            StatusNote(text: "Missing settings stay unspecified. A photograph does not reliably preserve a recipe name, its C1–C4 slot, or Auto ISO limits.")
                        }.padding(.top, 18)
                    }
                }.padding(24)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if busy {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading camera metadata…").font(.system(size: 12)) }
                }
                if let error { StatusNote(text: error, symbol: "exclamationmark.triangle", warning: true) }
                HStack {
                    Button("Close") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Add recovered recipe", action: save)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(busy || inspection?.result.recipes.first?.settings.isEmpty != false
                                  || recipeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(.horizontal, 24).padding(.vertical, 16).background(Palette.surface)
        }.frame(width: 760, height: 680).background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.green)
            .onDisappear { task?.cancel() }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an original Fujifilm camera JPEG. Settings are read locally."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; error = nil; inspection = nil; filename = url.lastPathComponent; showUnrecognized = false
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let result = try await PhotoInspectionInput.inspect(url)
                try Task.checkCancellation()
                inspection = result
                recipeName = result.result.recipes.first?.name ?? "From photo"
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard var result = inspection?.result, !result.recipes[0].settings.isEmpty else { return }
        result.recipes[0].name = recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try onImport(result); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

enum PhotoInspectionInput {
    static func inspect(_ url: URL) async throws -> PhotoInspection {
        let worker = Task.detached(priority: .userInitiated) {
            guard url.isFileURL else { throw RecipeImportError.invalid("Choose a local original JPEG file.") }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try Task.checkCancellation()
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attributes.isRegularFile == true else { throw RecipeImportError.invalid("Choose a regular JPEG file.") }
            guard (attributes.fileSize ?? Int.max) <= FujifilmPhotoInspector.maximumFileBytes else {
                throw RecipeImportError.invalid("Choose an original JPEG smaller than 80 MB.")
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try Task.checkCancellation()
            return try FujifilmPhotoInspector.inspectJPEG(data, filename: url.lastPathComponent)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
