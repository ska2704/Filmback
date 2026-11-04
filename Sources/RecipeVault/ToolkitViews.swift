import SwiftUI
import AppKit
import FujiCore

struct CatalogsView: View {
    @ObservedObject var store: VaultStore
    @ObservedObject var organization: LibraryOrganization
    let canWrite: Bool
    let lastRead: [CameraSlotSnapshot]
    let onLoad: (RecipeKit) -> Void
    let onCapture: () -> Void
    let onWrite: (Recipe, Int) -> Void
    let onActivity: (String) -> Void
    @State private var selection: UUID?
    @State private var creating = false
    @State private var editing: RecipeKit?
    @State private var deleting: RecipeKit?
    @State private var inspecting: Recipe?
    @State private var editingBank: EditingBank?
    @State private var comparing: RecipeKit?
    @State private var error: String?

    private struct EditingBank: Identifiable {
        let kitID: UUID
        let slot: Int
        let recipe: Recipe
        var id: String { "\(kitID)-\(slot)" }
    }

    private var selected: RecipeKit? { organization.kits.first { $0.id == selection } ?? organization.kits.first }

    var body: some View {
        HStack(spacing: 0) {
            folderList.frame(width: 248).background(Palette.paper)
            Divider()
            if let kit = selected { detail(kit) } else { emptyState }
        }
        .sheet(isPresented: $creating) { KitEditorView(recipes: store.recipes, kit: nil) { name, slots in
            selection = try organization.saveKit(name: name, slots: slots).id; onActivity("Saved catalog \(name).")
        } }
        .sheet(item: $editing) { kit in KitEditorView(recipes: store.recipes, kit: kit) { name, slots in
            try organization.updateKit(kit.id, name: name, slots: slots); onActivity("Updated catalog \(name).")
        } }
        .sheet(item: $editingBank) { bank in
            RecipeEditor(recipe: bank.recipe) { saved in
                guard let kit = organization.kits.first(where: { $0.id == bank.kitID }) else { return }
                var slots = kit.slots
                if let index = slots.firstIndex(where: { $0.slot == bank.slot }) { slots[index].recipe = saved }
                try organization.updateKit(kit.id, name: kit.name, slots: slots)
                onActivity("Updated C\(bank.slot) in \(kit.name). The camera changes only when you load the catalog.")
            }
        }
        .sheet(item: $comparing) { kit in
            if let source = comparisonSource { CatalogDiffView(kit: kit, source: source.label, banks: source.banks) }
        }
        .sheet(item: $inspecting) { recipe in
            VStack(alignment: .leading, spacing: 0) {
                Text(recipe.name).font(.system(size: 22, weight: .semibold)).padding(24)
                Divider()
                ScrollView { VStack(alignment: .leading, spacing: 20) { SettingsGrid(recipe: recipe); Text(recipe.notes).font(.system(size: 12)).textSelection(.enabled) }.padding(24) }
                Divider()
                HStack { Text("Saved in this catalog").font(.system(size: 12)).foregroundStyle(Palette.secondary); Spacer(); Button("Close") { inspecting = nil }.keyboardShortcut(.cancelAction) }.padding(20)
            }.frame(width: 580, height: 640).background(Palette.surface)
        }
        .alert("Catalog could not be saved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .confirmationDialog("Delete this catalog?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete catalog", role: .destructive) { if let kit = deleting { attempt { try organization.deleteKit(kit.id) } }; deleting = nil }
        } message: { Text("This removes its saved copies from this Mac. Recipes on the camera stay as they are.") }
    }

    private var folderList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { creating = true } label: { Label("New", systemImage: "folder.badge.plus") }.disabled(store.recipes.isEmpty)
                Menu("More") {
                    Button("Save camera banks as a catalog…", action: onCapture).disabled(!canWrite)
                    Button("Import catalog file…") { importCatalog() }
                }.menuStyle(.borderlessButton).fixedSize()
            }.padding(14)
            Divider()
            if organization.kits.isEmpty {
                Text("No catalogs yet").font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(16)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(organization.kits) { kit in
                            Button { selection = kit.id } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selected?.id == kit.id ? "folder.fill" : "folder").font(.system(size: 15))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(kit.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                        Text(organization.isLoaded(kit) ? "On camera" : "\(kit.slots.count) of 4 recipes")
                                            .font(.system(size: 11)).foregroundStyle(selected?.id == kit.id ? Palette.sidebarMuted : Palette.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if organization.isLoaded(kit) { Circle().fill(Palette.accent).frame(width: 7, height: 7).accessibilityHidden(true) }
                                }.padding(.horizontal, 12).padding(.vertical, 10)
                                    .foregroundStyle(selected?.id == kit.id ? Palette.sidebarText : Palette.ink)
                                    .background(selected?.id == kit.id ? Palette.graphite : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityAddTraits(selected?.id == kit.id ? .isSelected : [])
                        }
                    }.padding(8)
                }
            }
        }
    }

    private func detail(_ kit: RecipeKit) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(kit.name).font(.system(size: 25, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                        Text(status(kit)).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    Button("Edit") { editing = kit }
                    Button("Compare") { comparing = kit }.disabled(comparisonSource == nil)
                        .help(comparisonSource == nil ? "Read the camera or save a backup first" : "See what loading would change, without touching the camera")
                    Menu {
                        Button("Duplicate catalog") { attempt { selection = try organization.saveKit(name: kit.name + " copy", slots: kit.slots).id } }
                        Button("Add copies to library") {
                            attempt { try store.add(kit.slots.map(\.recipe)); onActivity("Added \(kit.slots.count) recipes from \(kit.name).") }
                        }
                        Button("Export catalog file…") { export(kit) }
                        Divider()
                        Button("Delete catalog", role: .destructive) { deleting = kit }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                        .accessibilityLabel("Actions for \(kit.name)")
                    Button { onLoad(kit) } label: { Label("Load to camera…", systemImage: "square.and.arrow.down.on.square") }
                        .buttonStyle(.borderedProminent).tint(Palette.accent).disabled(!canWrite || kit.slots.count != 4)
                        .help(kit.slots.count != 4 ? "Assign a recipe to all four banks first" : (canWrite ? "Review the changes before anything is written" : "Connect your X-M5 to load"))
                }
                Rectangle().fill(Palette.ink).frame(height: 1)
                VStack(spacing: 0) {
                    ForEach(1...4, id: \.self) { number in
                        let entry = kit.slots.first { $0.slot == number }
                        HStack(spacing: 18) {
                            Text("C\(number)").font(.system(size: 19, weight: .medium, design: .monospaced)).frame(width: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry?.recipe.name ?? "Empty").font(.system(size: 13, weight: .medium))
                                Text(summary(entry?.recipe)).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let entry {
                                Button("Inspect") { inspecting = entry.recipe }
                                Button("Edit copy") { editingBank = EditingBank(kitID: kit.id, slot: number, recipe: entry.recipe) }
                                Button("Review C\(number)…") { onWrite(entry.recipe, number) }.disabled(!canWrite)
                            }
                        }.padding(.vertical, 15)
                        Divider()
                    }
                }
                StatusNote(text: "A catalog keeps its own copy of each recipe, so editing the library won’t change it. Loading replaces the named recipe settings in C1–C4 and leaves other camera settings alone.")
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "folder").font(.system(size: 30, weight: .light)).foregroundStyle(Palette.secondary)
            Text("Build a catalog for every outing").font(.system(size: 24, weight: .semibold))
            Text("A catalog is a folder of four recipes, one for each custom bank. Load the one you need before you shoot.")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary).frame(maxWidth: 420, alignment: .leading)
            Button("New catalog") { creating = true }.buttonStyle(.borderedProminent).tint(Palette.accent).disabled(store.recipes.isEmpty)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The freshest saved view of the camera: this session's read, otherwise the newest readable backup.
    private var comparisonSource: (label: String, banks: [CameraSlotSnapshot])? {
        if !lastRead.isEmpty { return ("your last read of the camera", lastRead) }
        for backup in store.backups {
            if let banks = store.banks(in: backup) { return ("“\(backup.title)”, saved \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))", banks) }
        }
        return nil
    }

    private func status(_ kit: RecipeKit) -> String {
        if organization.isLoaded(kit), let loaded = organization.loadedCatalog {
            return "On camera · loaded and verified \(loaded.loadedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return kit.slots.count == 4 ? "Saved \(kit.updatedAt.formatted(date: .abbreviated, time: .shortened))" : "Needs \(4 - kit.slots.count) more recipes before it can be loaded"
    }

    private func summary(_ recipe: Recipe?) -> String {
        guard let recipe else { return "Choose a recipe with Edit" }
        return [recipe.settings[.filmSimulation], recipe.settings[.dynamicRange], recipe.settings[.whiteBalance]].compactMap { $0 }.joined(separator: " · ")
    }

    private func attempt(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }

    private func export(_ kit: RecipeKit) {
        attempt {
            let recipes = kit.slots.map { entry -> Recipe in var recipe = entry.recipe; recipe.suggestedSlot = entry.slot; return recipe }
            let panel = NSSavePanel(); panel.nameFieldStringValue = kit.name.replacingOccurrences(of: "/", with: "-") + ".json"
            if panel.runModal() == .OK, let url = panel.url { try Data(RecipeExporter.json(recipes: recipes).utf8).write(to: url, options: .atomic) }
        }
    }

    private func importCatalog() {
        let panel = NSOpenPanel(); panel.title = "Choose a catalog file"; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt {
            let parsed = try RecipeImporter.parse(String(contentsOf: url, encoding: .utf8))
            let slots = try CatalogFile.slots(from: parsed.recipes)
            selection = try organization.saveKit(name: url.deletingPathExtension().lastPathComponent, slots: slots).id
            onActivity("Imported a catalog. Review it before loading.")
        }
    }
}

enum CatalogFile {
    /// Uses each recipe's bank when all four are numbered, otherwise the file's order.
    static func slots(from recipes: [Recipe]) throws -> [RecipeKitSlot] {
        guard recipes.count == 4 else { throw LibraryOrganizationError.message("A catalog file must contain exactly four recipes. This one has \(recipes.count).") }
        let numbered = recipes.compactMap(\.suggestedSlot)
        if Set(numbered) == Set(1...4) { return recipes.map { RecipeKitSlot(slot: $0.suggestedSlot!, recipe: $0) } }
        return recipes.enumerated().map { RecipeKitSlot(slot: $0.offset + 1, recipe: $0.element) }
    }
}

/// Compares a catalog with saved banks. This never touches the camera.
struct CatalogDiffView: View {
    let kit: RecipeKit
    let source: String
    let banks: [CameraSlotSnapshot]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(kit.name) against the camera").font(.system(size: 22, weight: .semibold))
                Text("Compared with \(source). The camera may have changed since then.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }.padding(24)
            Divider()
            ScrollView { VStack(alignment: .leading, spacing: 22) {
                ForEach(kit.slots) { entry in
                    let bank = banks.first { $0.slot == entry.slot }
                    let changes = RecipeDiff.changes(from: bank?.recipe, to: entry.recipe)
                    BankDiffSection(title: "C\(entry.slot) · \(bank?.name ?? "Not read") → \(entry.recipe.name)", changes: changes, fromLabel: "On camera", toLabel: "Catalog")
                }
            }.padding(24) }
            Divider()
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(20)
        }.frame(width: 620, height: 660).background(Palette.surface).tint(Palette.graphite)
    }
}

struct BankDiffSection: View {
    let title: String
    let changes: [RecipeSettingChange]
    let fromLabel: String
    let toLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.bottom, 8)
            Rectangle().fill(Palette.ink).frame(height: 1)
            if changes.isEmpty {
                Text("No differences in the settings that could be compared").font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.vertical, 8)
            } else {
                HStack {
                    Text("Setting").frame(maxWidth: .infinity, alignment: .leading)
                    Text(fromLabel).frame(width: 150, alignment: .trailing)
                    Text(toLabel).frame(width: 150, alignment: .trailing)
                }.font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary).padding(.vertical, 6)
                ForEach(changes) { change in
                    HStack(alignment: .firstTextBaseline) {
                        Text(change.field.label).frame(maxWidth: .infinity, alignment: .leading)
                        Text(change.current ?? "Not read").foregroundStyle(Palette.secondary).frame(width: 150, alignment: .trailing)
                        Text(change.target).fontWeight(.medium).frame(width: 150, alignment: .trailing)
                    }.font(.system(size: 12)).monospacedDigit().padding(.vertical, 6)
                    Rectangle().fill(Palette.line).frame(height: 0.5)
                }
            }
        }
    }
}

/// Shows C1–C4 stored in a backup file and compares them with another backup.
struct BackupBanksView: View {
    let title: String
    let banks: [CameraSlotSnapshot]
    let others: [(id: UUID, title: String, banks: [CameraSlotSnapshot])]
    let onSaveCatalog: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var compareID: UUID?
    @State private var error: String?
    private var other: (id: UUID, title: String, banks: [CameraSlotSnapshot])? { others.first { $0.id == compareID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 22, weight: .semibold))
                if !others.isEmpty {
                    Picker("Compare with", selection: $compareID) {
                        Text("Nothing, show settings").tag(nil as UUID?)
                        ForEach(others, id: \.id) { Text($0.title).tag(Optional($0.id)) }
                    }.frame(maxWidth: 420)
                }
            }.padding(24)
            Divider()
            ScrollView { VStack(alignment: .leading, spacing: 24) {
                ForEach(banks) { bank in
                    if let other {
                        let earlier = other.banks.first { $0.slot == bank.slot }
                        BankDiffSection(title: "C\(bank.slot) · \(bank.name)", changes: RecipeDiff.changes(from: earlier?.recipe, to: bank.recipe), fromLabel: "Other backup", toLabel: "This backup")
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("C\(bank.slot) · \(bank.name.isEmpty ? "Unnamed" : bank.name)").font(.system(size: 17, weight: .semibold))
                            SettingsGrid(recipe: bank.recipe)
                            if !bank.readErrors.isEmpty { CautionLabel(text: "\(bank.readErrors.count) values not recognised yet. They are left out, not guessed.") }
                            if bank.holdsPlaceholders { CautionLabel(text: "This backup holds placeholder values, not this bank’s recipe.") }
                        }
                    }
                }
            }.padding(24) }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Palette.ink).padding(.horizontal, 24).padding(.top, 10) }
            Divider()
            HStack {
                Button("Save as catalog") { do { try onSaveCatalog(); dismiss() } catch { self.error = error.localizedDescription } }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
        }.frame(width: 640, height: 680).background(Palette.surface).tint(Palette.graphite)
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
                Text(kit == nil ? "New catalog" : "Edit catalog").font(.system(size: 22, weight: .semibold))
                Text("Choose a recipe for each of your X-M5’s four custom banks.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }.padding(24)
            Divider()
            Form {
                TextField("Catalog name", text: $name)
                ForEach(1...4, id: \.self) { slot in
                    HStack {
                        Text("C\(slot)").font(.system(size: 15, weight: .medium, design: .monospaced)).frame(width: 38)
                        Menu {
                            if let current = assignments[slot], !recipes.contains(where: { $0.id == current.id }) {
                                Button("Keep “\(current.name)”") {}
                                Divider()
                            }
                            ForEach(recipes) { recipe in Button(recipe.name) { assignments[slot] = recipe } }
                        } label: { Text(assignments[slot]?.name ?? "Choose recipe…").frame(maxWidth: .infinity, alignment: .leading) }
                        if assignments[slot] != nil {
                            Button { assignments[slot] = nil } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).accessibilityLabel("Clear C\(slot)")
                        }
                    }.padding(.vertical, 9)
                }
            }.formStyle(.grouped)
            StatusNote(text: "Saving stores copies on this Mac. Nothing reaches the camera until you load the catalog and review the changes.").padding(.horizontal, 24).padding(.bottom, 16)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Palette.ink).padding(.horizontal, 24).padding(.bottom, 12) }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if assignments.count < 4 { Text("Choose \(4 - assignments.count) more").font(.system(size: 12)).foregroundStyle(Palette.secondary) }
                Button("Save catalog") {
                    do { try onSave(name, assignments.map { RecipeKitSlot(slot: $0.key, recipe: $0.value) }); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(Palette.accent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assignments.count != 4)
            }.padding(20)
        }.frame(width: 560, height: 480).background(Palette.surface).tint(Palette.graphite)
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
                                    if changed.contains(field) { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(Palette.accent).accessibilityLabel("Different") }
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
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Palette.ink) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 530, height: 460).background(Palette.surface).tint(Palette.graphite)
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
