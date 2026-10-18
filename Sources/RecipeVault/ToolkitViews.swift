import SwiftUI
import AppKit
import FujiCore

struct KitsView: View {
    @ObservedObject var store: VaultStore
    @ObservedObject var organization: LibraryOrganization
    let canWrite: Bool
    let onWrite: (Recipe, Int) -> Void
    let onActivity: (String) -> Void
    @State private var creating = false
    @State private var editing: RecipeKit?
    @State private var deleting: RecipeKit?
    @State private var inspecting: Recipe?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A set for every outing").font(.system(size: 25, weight: .semibold))
                        Text("Save C1–C4 together for travel, portraits or everyday shooting.")
                            .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    Button("New kit") { creating = true }.buttonStyle(.borderedProminent).disabled(store.recipes.isEmpty)
                }
                StatusNote(text: "Kits keep a copy of each recipe. Editing or deleting the library recipe won’t change a saved kit. Review and write each bank individually when connected.")
                if organization.kits.isEmpty {
                    Divider()
                    Text("No kits saved").font(.system(size: 17, weight: .medium))
                    Text(store.recipes.isEmpty ? "Add recipes to your library first, then arrange them into a kit." : "Choose up to four recipes and give the set a name. You can leave banks unassigned.")
                        .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                }
                ForEach(organization.kits) { kit in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(kit.name).font(.system(size: 18, weight: .semibold)).textSelection(.enabled)
                            Spacer()
                            Button("Edit") { editing = kit }
                            Menu {
                                Button("Add copies to library") {
                                    attempt { try store.add(kit.slots.map(\.recipe)); onActivity("Added \(kit.slots.count) recipes from \(kit.name).") }
                                }
                                Button("Export kit recipes JSON…") { export(kit) }
                                Divider()
                                Button("Delete kit", role: .destructive) { deleting = kit }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                                .accessibilityLabel("Actions for \(kit.name)")
                        }.padding(.bottom, 14)
                        Rectangle().fill(Palette.ink).frame(height: 1)
                        ForEach(1...4, id: \.self) { number in
                            let entry = kit.slots.first { $0.slot == number }
                            HStack(spacing: 18) {
                                Text("C\(number)").font(.system(size: 19, weight: .medium, design: .monospaced)).frame(width: 44)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry?.recipe.name ?? "Unassigned").font(.system(size: 13, weight: .medium))
                                    Text(entry?.recipe.settings[.filmSimulation] ?? "Keep the camera bank as it is")
                                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                }
                                Spacer()
                                if let entry {
                                    Text("\(entry.recipe.settings.count) settings").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                    Button("Inspect") { inspecting = entry.recipe }
                                    Button("Review C\(number)…") { onWrite(entry.recipe, number) }.disabled(!canWrite)
                                }
                            }.padding(.vertical, 15)
                            Divider()
                        }
                        Text("Saved \(kit.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.top, 10)
                    }.padding(.bottom, 12)
                }
            }.padding(28)
        }
        .sheet(isPresented: $creating) { KitEditorView(recipes: store.recipes, kit: nil) { name, slots in
            _ = try organization.saveKit(name: name, slots: slots); onActivity("Saved kit \(name).")
        } }
        .sheet(item: $editing) { kit in KitEditorView(recipes: store.recipes, kit: kit) { name, slots in
            try organization.updateKit(kit.id, name: name, slots: slots); onActivity("Updated kit \(name).")
        } }
        .sheet(item: $inspecting) { recipe in
            VStack(alignment: .leading, spacing: 0) {
                Text(recipe.name).font(.system(size: 22, weight: .semibold)).padding(24)
                Divider()
                ScrollView { VStack(alignment: .leading, spacing: 20) { SettingsGrid(recipe: recipe); Text(recipe.notes).font(.system(size: 12)).textSelection(.enabled) }.padding(24) }
                Divider()
                HStack { Text("Saved kit copy").font(.system(size: 12)).foregroundStyle(Palette.secondary); Spacer(); Button("Close") { inspecting = nil }.keyboardShortcut(.cancelAction) }.padding(20)
            }.frame(width: 580, height: 640).background(Palette.surface)
        }
        .alert("Kit could not be saved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .confirmationDialog("Delete this saved kit?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete kit", role: .destructive) { if let kit = deleting { attempt { try organization.deleteKit(kit.id) } }; deleting = nil }
        }
    }

    private func attempt(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    private func export(_ kit: RecipeKit) {
        attempt {
            let recipes = kit.slots.map { entry -> Recipe in var recipe = entry.recipe; recipe.suggestedSlot = entry.slot; return recipe }
            let panel = NSSavePanel(); panel.nameFieldStringValue = kit.name.replacingOccurrences(of: "/", with: "-") + ".json"
            if panel.runModal() == .OK, let url = panel.url { try Data(RecipeExporter.json(recipes: recipes).utf8).write(to: url, options: .atomic) }
        }
    }
}

struct KitEditorView: View {
    let recipes: [Recipe]
    let kit: RecipeKit?
    let onSave: (String, [RecipeKitSlot]) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var assignments: [Int: Recipe] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(kit == nil ? "New camera kit" : "Edit camera kit").font(.system(size: 22, weight: .semibold))
                Text("Arrange a saved set for your X-M5’s four custom banks.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }.padding(24)
            Divider()
            Form {
                TextField("Kit name", text: $name)
                ForEach(1...4, id: \.self) { slot in
                    HStack {
                        Text("C\(slot)").font(.system(size: 15, weight: .medium, design: .monospaced)).frame(width: 38)
                        Menu {
                            Button("Unassigned") { assignments[slot] = nil }
                            Divider()
                            ForEach(recipes) { recipe in Button(recipe.name) { assignments[slot] = recipe } }
                        } label: { Text(assignments[slot]?.name ?? "Choose recipe…").frame(maxWidth: .infinity, alignment: .leading) }
                        if assignments[slot] != nil {
                            Button { assignments[slot] = nil } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).accessibilityLabel("Clear C\(slot)")
                        }
                    }.padding(.vertical, 9)
                }
            }.formStyle(.grouped)
            StatusNote(text: "Saving a kit stores recipe copies on this Mac. Camera changes are reviewed separately.").padding(.horizontal, 24).padding(.bottom, 16)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.horizontal, 24).padding(.bottom, 12) }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save kit") {
                    do { try onSave(name, assignments.map { RecipeKitSlot(slot: $0.key, recipe: $0.value) }); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assignments.isEmpty)
            }.padding(20)
        }.frame(width: 560, height: 480).background(Palette.surface).tint(Palette.green)
        .onAppear { name = kit?.name ?? ""; assignments = Dictionary(uniqueKeysWithValues: (kit?.slots ?? []).map { ($0.slot, $0.recipe) }) }
    }
}

struct RecipeComparisonView: View {
    let recipes: [Recipe]
    @State private var leftID: UUID?
    @State private var rightID: UUID?
    @State private var differencesOnly = true
    private var left: Recipe? { recipes.first { $0.id == leftID } }
    private var right: Recipe? { recipes.first { $0.id == rightID } }
    private var changed: [RecipeField] { RecipeField.allCases.filter { left?.settings[$0] != right?.settings[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("See what changes").font(.system(size: 25, weight: .semibold))
                HStack(spacing: 20) {
                    recipePicker("First recipe", selection: $leftID)
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(Palette.secondary)
                    recipePicker("Second recipe", selection: $rightID)
                }
                HStack {
                    Toggle("Only differences", isOn: $differencesOnly).toggleStyle(.checkbox)
                    Spacer()
                    Text("\(changed.count) different settings").foregroundStyle(Palette.secondary)
                }.font(.system(size: 12))
            }.padding(28)
            Divider()
            if let left, let right {
                ScrollView {
                    VStack(spacing: 0) {
                        HStack { Text("Setting").frame(maxWidth: .infinity, alignment: .leading); Text(left.name).frame(maxWidth: .infinity, alignment: .trailing); Text(right.name).frame(maxWidth: .infinity, alignment: .trailing) }
                            .font(.system(size: 13, weight: .semibold)).padding(.bottom, 12)
                        Rectangle().fill(Palette.ink).frame(height: 1)
                        ForEach(RecipeField.allCases.filter { !differencesOnly || changed.contains($0) }) { field in
                            HStack(alignment: .firstTextBaseline, spacing: 18) {
                                HStack(spacing: 6) {
                                    if changed.contains(field) { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(Palette.green).accessibilityLabel("Different") }
                                    Text(field.label)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(left.settings[field] ?? "Not specified").frame(maxWidth: .infinity, alignment: .trailing)
                                Text(right.settings[field] ?? "Not specified").frame(maxWidth: .infinity, alignment: .trailing)
                            }.font(.system(size: 12)).monospacedDigit().padding(.vertical, 10)
                                .foregroundStyle(changed.contains(field) ? Palette.ink : Palette.secondary).textSelection(.enabled)
                            Divider()
                        }
                        if differencesOnly && changed.isEmpty { Text("These recipes have the same saved settings.").font(.system(size: 13)).foregroundStyle(Palette.secondary).padding(.vertical, 30) }
                        StatusNote(text: "Not specified means the recipe leaves that setting open. This compares saved values; it does not predict the rendered photograph.")
                            .padding(.top, 24).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(28)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose two recipes").font(.system(size: 17, weight: .medium))
                    Text("Add at least two recipes to your library to compare their settings.").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                }.padding(28)
                Spacer()
            }
        }.onAppear { reconcile() }.onChange(of: recipes.map(\.id)) { _ in reconcile() }
    }
    private func recipePicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("Choose recipe").tag(nil as UUID?)
            ForEach(recipes) { Text($0.name).tag(Optional($0.id)) }
        }.frame(maxWidth: .infinity)
    }
    private func reconcile() {
        if !recipes.contains(where: { $0.id == leftID }) { leftID = recipes.first?.id }
        if !recipes.contains(where: { $0.id == rightID }) { rightID = recipes.dropFirst().first?.id }
    }
}

struct CollectionManagerView: View {
    @ObservedObject var organization: LibraryOrganization
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Collections").font(.system(size: 22, weight: .semibold))
            Text("Group recipes for a subject, trip or mood. Removing a collection keeps its recipes in your library.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            HStack {
                TextField("New collection name", text: $newName)
                Button("Add") { attempt { _ = try organization.createCollection(name: newName); newName = "" } }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List {
                ForEach(organization.collections) { collection in
                    CollectionRow(collection: collection, onRename: { name in attempt { try organization.renameCollection(collection.id, to: name) } }, onDelete: { attempt { try organization.deleteCollection(collection.id) } })
                }
            }.listStyle(.plain)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 530, height: 460).background(Palette.surface).tint(Palette.green)
    }
    private func attempt(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
}

private struct CollectionRow: View {
    let collection: RecipeCollection
    let onRename: (String) -> Void
    let onDelete: () -> Void
    @State private var name = ""
    var body: some View {
        HStack {
            TextField("Collection name", text: $name).onSubmit { onRename(name) }
            Text("\(collection.recipeIDs.count)").monospacedDigit().foregroundStyle(Palette.secondary)
            Button("Rename") { onRename(name) }.disabled(name == collection.name)
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.accessibilityLabel("Delete \(collection.name) collection")
        }.padding(.vertical, 6).onAppear { name = collection.name }.onChange(of: collection.name) { name = $0 }
    }
}
