import SwiftUI
import AppKit
import FujiCore

@main
struct RecipeVaultApp: App {
    @StateObject private var store = VaultStore(root: ProcessInfo.processInfo.environment["RECIPEVAULT_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) })
    @StateObject private var camera = CameraConnection()
    var body: some Scene {
        Window("RecipeVault", id: "main") {
            WorkspaceView(store: store, camera: camera)
                .frame(minWidth: 1040, minHeight: 700)
                .tint(Palette.graphite)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); camera.startDiscovery() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1220, height: 820)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About RecipeVault") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "RecipeVault", .applicationVersion: "0.5.0 · X-M5 toolkit", .credits: NSAttributedString(string: "A local photography toolkit and camera backup vault.\nUSB support requires verification on your camera.")])
                }
            }
        }
    }
}

struct WorkspaceView: View {
    @ObservedObject var store: VaultStore
    @ObservedObject var camera: CameraConnection
    @StateObject private var organization: LibraryOrganization
    @State private var section = ProcessInfo.processInfo.environment["RECIPEVAULT_START_SECTION"] ?? "Library"
    @State private var selection: UUID?
    @State private var search = ""
    @State private var showImport = false
    @State private var editing: Recipe?
    @State private var slots: [CameraSlotSnapshot] = []
    @State private var busy = false
    @State private var activity = "Recipes and backups are saved on this Mac."
    @State private var plan: RecipeWritePlan?
    @State private var catalogPlan: CatalogWritePlan?
    @State private var inspectedSlot: CameraSlotSnapshot?
    @State private var viewingBackup: BackupRecord?
    @State private var otherCameraApps: [String] = []
    @State private var pendingRecipeName = ""
    @State private var error: String?
    @State private var deleting: Recipe?
    @State private var favoritesOnly = false
    @State private var collectionID: UUID?
    @State private var simulation = ""
    @State private var sortOrder = "Newest"
    @State private var showCollections = false
    @State private var showPhotoInspector = false
    @State private var restorePreview: VaultArchivePreview?
    @State private var restoreURL: URL?
    @FocusState private var searchFocused: Bool

    init(store: VaultStore, camera: CameraConnection) {
        self.store = store
        self.camera = camera
        _organization = StateObject(wrappedValue: LibraryOrganization(root: store.root))
    }

    private var service: RecipeCameraService { RecipeCameraService(connection: camera) }
    private var selectedRecipe: Recipe? { filteredRecipes.first { $0.id == selection } }
    private var filteredRecipes: [Recipe] {
        let collection = organization.collections.first { $0.id == collectionID }
        return store.recipes.filter {
            (search.isEmpty || "\($0.name) \($0.settings[.filmSimulation] ?? "") \($0.author ?? "") \($0.notes)".localizedCaseInsensitiveContains(search)) &&
            (!favoritesOnly || organization.isFavorite($0.id)) &&
            (collection == nil || collection!.recipeIDs.contains($0.id)) &&
            (simulation.isEmpty || $0.settings[.filmSimulation] == simulation)
        }.sorted {
            if sortOrder == "Name" { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if sortOrder == "Simulation" {
                let a = $0.settings[.filmSimulation] ?? "", b = $1.settings[.filmSimulation] ?? ""
                if a != b { return a.localizedStandardCompare(b) == .orderedAscending }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.createdAt > $1.createdAt
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                Divider()
                Group {
                    switch section {
                    case "Camera": cameraPage
                    case "Backups": backupsPage
                    case "Catalogs": CatalogsView(store: store, organization: organization, canWrite: camera.isConnected && !busy, lastRead: slots, onLoad: prepareCatalog, onCapture: captureCatalog, onWrite: prepare, onActivity: { activity = $0 })
                    case "Compare": RecipeComparisonView(recipes: store.recipes)
                    case "Photo tools": photoToolsPage
                    case "Guide": guidePage
                    default: libraryPage
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 7) {
                    if busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "internaldrive").foregroundStyle(Palette.secondary) }
                    Text(activity).lineLimit(2)
                    Spacer(minLength: 12)
                    Text("X-M5 / C1–C4").monospacedDigit().foregroundStyle(Palette.secondary)
                }.font(.system(size: 11)).padding(.horizontal, 22).padding(.vertical, 9).background(Palette.paper)
            }.background(Palette.surface)
        }
        .preferredColorScheme(.light)
        .onAppear { reconcileSelection(); refreshPreflight() }
        .onChange(of: section) { _ in refreshPreflight() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshPreflight() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshPreflight() }
        .onChange(of: search) { _ in reconcileSelection() }
        .onChange(of: store.recipes.map(\.id)) { _ in reconcileSelection() }
        .onChange(of: filteredRecipes.map(\.id)) { _ in reconcileSelection() }
        .background {
            Button("Find recipes") { section = "Library"; searchFocused = true }
                .keyboardShortcut("f").hidden()
        }
        .sheet(isPresented: $showImport) {
            ImportView { result in
                try store.add(result.recipes)
                clearFilters(); selection = store.recipes.first?.id; section = "Library"
                activity = "Imported \(result.recipes.count) recipe(s). Review the settings before writing to your camera."
            }
        }
        .sheet(item: $editing) { recipe in
            RecipeEditor(recipe: recipe) { saved in
                try store.save(saved)
                clearFilters(); selection = saved.id
                activity = "Saved \(saved.name)."
            }
        }
        .sheet(isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } })) {
            if let current = plan { WriteReviewView(plan: current, recipeName: pendingRecipeName, onCancel: { plan = nil }, onApply: { apply(current) }) }
        }
        .sheet(item: $catalogPlan) { current in
            CatalogReviewView(plan: current, onCancel: { catalogPlan = nil }, onApply: { applyCatalog(current) })
        }
        .sheet(item: $inspectedSlot) { slot in
            VStack(alignment: .leading, spacing: 0) {
                Text("C\(slot.slot) · \(slot.name)").font(.system(size: 22, weight: .semibold)).padding(24)
                Divider()
                ScrollView { SettingsGrid(recipe: slot.recipe).padding(24) }
                Divider()
                HStack { Spacer(); Button("Close") { inspectedSlot = nil }.keyboardShortcut(.cancelAction) }.padding(20)
            }.frame(width: 560, height: 620).background(Palette.surface)
        }
        .sheet(item: $viewingBackup) { backup in
            BackupBanksView(title: backup.title, banks: store.banks(in: backup) ?? [],
                            others: store.backups.filter { $0.id != backup.id }.compactMap { other in store.banks(in: other).map { (other.id, "\(other.title), \(other.createdAt.formatted(date: .abbreviated, time: .shortened))", $0) } }) {
                guard !(store.banks(in: backup) ?? []).contains(where: \.holdsPlaceholders) else { throw VaultError.message("This backup holds placeholder values instead of recipes, so it can't become a catalog.") }
                let copies = (store.banks(in: backup) ?? []).map { bank -> RecipeKitSlot in
                    var recipe = bank.recipe
                    if recipe.name.isEmpty { recipe.name = "C\(bank.slot)" }
                    recipe.suggestedSlot = bank.slot
                    return RecipeKitSlot(slot: bank.slot, recipe: recipe)
                }
                let kit = try organization.saveKit(name: backup.title, slots: copies)
                activity = "Saved \(kit.name) as a catalog. Settings missing from the backup stay as they are on the camera when loaded."
            }
        }
        .sheet(isPresented: $showCollections) { CollectionManagerView(organization: organization) }
        .sheet(isPresented: $showPhotoInspector) {
            PhotoInspectorView { result in
                try store.add(result.recipes); clearFilters(); selection = store.recipes.first?.id; section = "Library"
                activity = "Imported photo settings. Missing values stay unspecified; review before writing."
            }
        }
        .sheet(isPresented: Binding(get: { restorePreview != nil }, set: { if !$0 { restorePreview = nil; restoreURL = nil } })) {
            if let preview = restorePreview { vaultRestoreSheet(preview) }
        }
        .alert("RecipeVault", isPresented: Binding(get: { error != nil || store.errorMessage != nil || organization.errorMessage != nil }, set: { if !$0 { error = nil; store.errorMessage = nil; organization.errorMessage = nil } })) {
            Button("OK") { error = nil; store.errorMessage = nil; organization.errorMessage = nil }
        } message: { Text(error ?? store.errorMessage ?? organization.errorMessage ?? "") }
        .confirmationDialog("Delete this recipe from your library?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete recipe", role: .destructive) {
                if let recipe = deleting { do { try store.delete(recipe); try organization.removeRecipeReferences(recipe.id); reconcileSelection() } catch { self.error = error.localizedDescription } }
                deleting = nil
            }
        }
    }

    private func reconcileSelection() {
        if !filteredRecipes.contains(where: { $0.id == selection }) { selection = filteredRecipes.first?.id }
    }

    private func clearFilters() { search = ""; favoritesOnly = false; collectionID = nil; simulation = "" }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "camera.filters").font(.system(size: 20, weight: .medium))
                Text("RecipeVault").font(.system(size: 16, weight: .semibold)).tracking(-0.4)
            }.foregroundStyle(Palette.sidebarText).padding(.horizontal, 18).padding(.top, 40).padding(.bottom, 30)
            VStack(spacing: 4) {
                ForEach([("Library", "square.stack"), ("Catalogs", "folder"), ("Compare", "arrow.left.arrow.right"), ("Photo tools", "photo"), ("Camera", "camera"), ("Backups", "externaldrive"), ("Guide", "book.closed")], id: \.0) { name, icon in
                    Button { section = name } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon).font(.system(size: 14)).frame(width: 20)
                            Text(name).font(.system(size: 13, weight: section == name ? .semibold : .regular))
                            Spacer()
                            if name == "Library" { Text("\(store.recipes.count)").font(.system(size: 11)).monospacedDigit() }
                        }.padding(.horizontal, 12).padding(.vertical, 11)
                            .foregroundStyle(section == name ? Palette.sidebarText : Palette.sidebarMuted)
                            .background(section == name ? Palette.graphite : .clear)
                            .overlay(alignment: .leading) { if section == name { Rectangle().fill(Palette.accent).frame(width: 2) } }
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(section == name ? .isSelected : [])
                        .help("Show \(name.lowercased())")
                }
            }.padding(.horizontal, 10)
            Spacer()
            VStack(alignment: .leading, spacing: 13) {
                Rectangle().fill(Palette.darkMetal).frame(height: 1)
                HStack { Text("FUJIFILM").font(.system(size: 11, weight: .semibold)).tracking(0.7); Spacer(); Text("X-M5").font(.system(size: 14, weight: .semibold)) }
                Label(camera.isConnected ? "USB connected" : "Not connected", systemImage: camera.isConnected ? "checkmark.circle.fill" : "cable.connector")
                    .font(.system(size: 11)).foregroundStyle(Palette.sidebarMuted)
                HStack(spacing: 5) {
                    ForEach(1...4, id: \.self) { number in
                        Text("C\(number)").font(.system(size: 11, weight: .medium, design: .monospaced))
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(Palette.graphite).clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }.accessibilityElement(children: .ignore).accessibilityLabel("Four custom banks, C1 through C4")
                Text("0.5 · X-M5 toolkit").font(.system(size: 11)).foregroundStyle(Palette.sidebarMuted)
            }.foregroundStyle(Palette.sidebarText).padding(18)
        }.frame(width: 186).background(Palette.sidebar)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text(section).font(.system(size: 19, weight: .semibold))
            Spacer()
            if section == "Library" {
                Button("Collections") { showCollections = true }
                Button { showImport = true } label: { Label("Import", systemImage: "square.and.arrow.down") }.keyboardShortcut("i")
                Button { editing = Recipe(name: "Untitled recipe") } label: { Label("New recipe", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(Palette.accent).keyboardShortcut("n")
            } else if section == "Backups" {
                Button { importBackup() } label: { Label("Import backup", systemImage: "square.and.arrow.down") }
            }
        }.controlSize(.regular).padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 18)
            .background(Palette.paper)
    }

    private var libraryPage: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                    TextField("Search recipes", text: $search).textFieldStyle(.plain).focused($searchFocused)
                        .accessibilityLabel("Search recipes")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(Palette.secondary).help("Clear search").accessibilityLabel("Clear search")
                    }
                }.font(.system(size: 12)).padding(9).background(Palette.surface)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line, lineWidth: 1))
                    .padding(14)
                libraryFilters
                HStack {
                    Text(favoritesOnly ? "Favourites" : (search.isEmpty ? "Recipes" : "Search results")).fontWeight(.medium)
                    Spacer(); Text("\(filteredRecipes.count)").monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.horizontal, 16).padding(.bottom, 10)
                Divider()
                if filteredRecipes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.recipes.isEmpty ? "No recipes yet" : "No matching recipes").font(.system(size: 12, weight: .medium))
                        Text(store.recipes.isEmpty ? "Import a recipe or enter your own settings." : "Try another filter or clear them to see all recipes.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        if !store.recipes.isEmpty { Button("Clear filters") { clearFilters() } }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                } else {
                    List(selection: $selection) {
                        ForEach(filteredRecipes) { recipe in
                            HStack(alignment: .center, spacing: 10) {
                                if let coverURL = store.coverURL(for: recipe) {
                                    LocalCoverImage(url: coverURL, height: 54, compact: true).frame(width: 54)
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 5) {
                                        Text(recipe.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                        if organization.isFavorite(recipe.id) { Image(systemName: "star.fill").font(.system(size: 10)).accessibilityLabel("Favourite") }
                                    }
                                    Text(recipe.settings[.filmSimulation] ?? "Custom settings").font(.system(size: 11)).lineLimit(1)
                                        .opacity(recipe.id == selection ? 1 : 0.78)
                                    if let slot = recipe.suggestedSlot {
                                        Text("Suggested C\(slot)").font(.system(size: 11)).monospacedDigit()
                                            .opacity(recipe.id == selection ? 1 : 0.78)
                                    } else if let author = recipe.author, !author.isEmpty {
                                        Text(author).font(.system(size: 11)).lineLimit(1).opacity(recipe.id == selection ? 1 : 0.78)
                                    }
                                }
                            }.padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                                .tag(recipe.id).accessibilityElement(children: .combine)
                                .listRowSeparator(.visible)
                        }
                    }.listStyle(.plain).scrollContentBackground(.hidden).accentColor(Palette.graphite)
                }
                Divider()
                Text("Saved locally")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(12)
            }.frame(width: 248).background(Palette.paper.opacity(0.65))
            Divider()
            if let recipe = selectedRecipe { recipeDetail(recipe) }
            else { libraryEmptyState }
        }
    }

    private func recipeDetail(_ recipe: Recipe) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(recipe.name).font(.system(size: 26, weight: .semibold)).tracking(-0.5).lineLimit(2).help(recipe.name).textSelection(.enabled)
                    HStack(spacing: 10) {
                        if let author = recipe.author, !author.isEmpty { Text("by \(author)") }
                        Text("\(recipe.settings.count) settings")
                        if let slot = recipe.suggestedSlot { Text("Suggested C\(slot)").monospacedDigit() }
                        if let source = recipe.sourceURL, let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                            Link(destination: url) { Label("Source", systemImage: "arrow.up.right") }
                        }
                    }.font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 0)
                Button { do { try organization.toggleFavorite(recipe.id) } catch { self.error = error.localizedDescription } } label: {
                    Image(systemName: organization.isFavorite(recipe.id) ? "star.fill" : "star")
                }.buttonStyle(.plain).padding(.top, 7).accessibilityLabel(organization.isFavorite(recipe.id) ? "Remove favourite" : "Add favourite")
                Menu {
                    Button("Duplicate") { var copy = recipe; copy.id = UUID(); copy.name += " copy"; editing = copy }
                    Button("Export JSON") { exportRecipe(recipe, ofr: false) }
                    Button("Export Open Fuji Recipe") { exportRecipe(recipe, ofr: true) }
                    Button("Export recipe PDF…") { do { try saveData(RecipeShare.pdf(recipe), suggestedName: recipe.name + ".pdf") } catch { self.error = error.localizedDescription } }
                    Button("Copy settings as text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(RecipeShare.text(recipe), forType: .string); activity = "Copied \(recipe.name) settings with attribution." }
                    Menu("Collections") {
                        ForEach(organization.collections) { collection in
                            Button { do { try organization.toggleMembership(recipeID: recipe.id, collectionID: collection.id) } catch { self.error = error.localizedDescription } } label: {
                                Label(collection.name, systemImage: collection.recipeIDs.contains(recipe.id) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                        Divider()
                        Button("Manage collections…") { showCollections = true }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { deleting = recipe }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 22).padding(.top, 7)
                .accessibilityLabel("Recipe actions").help("Duplicate, export or delete recipe")
            }.padding(.horizontal, 24).padding(.top, 25).padding(.bottom, 20)
            HStack(spacing: 12) {
                Image(systemName: "camera.filters").font(.system(size: 21))
                VStack(alignment: .leading, spacing: 3) {
                    Text(recipe.settings[.filmSimulation] ?? "Custom settings").font(.system(size: 15, weight: .semibold))
                    Text("Film simulation").font(.system(size: 11)).foregroundStyle(Palette.sidebarMuted)
                }
                Spacer()
                Text("X-M5").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.sidebarMuted)
            }.padding(.horizontal, 16).padding(.vertical, 14).foregroundStyle(Palette.sidebarText)
                .background(Palette.graphite).clipShape(RoundedRectangle(cornerRadius: 5)).padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button("Edit settings") { editing = recipe }
                Menu("Write to camera…") {
                    ForEach(1...4, id: \.self) { slot in Button("Custom bank C\(slot)") { prepare(recipe, slot: slot) } }
                }.disabled(!camera.isConnected || busy)
                Spacer()
                if !camera.isConnected {
                    Label("Connect X-M5 to write", systemImage: "cable.connector")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let cover = recipe.cover, let coverURL = store.coverURL(for: recipe) {
                        RecipeCoverPanel(cover: cover, url: coverURL, recipeName: recipe.name)
                    }
                    SettingsGrid(recipe: recipe)
                    if !recipe.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Field notes").font(.system(size: 13, weight: .semibold))
                            Text(recipe.notes).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
                        }
                    }
                    StatusNote(text: "Only included settings are written. Check the camera’s still/movie bank assignment before applying a recipe.")
                }.padding(24)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var libraryFilters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Favourites", isOn: $favoritesOnly).toggleStyle(.checkbox)
                Spacer()
                if favoritesOnly || collectionID != nil || !simulation.isEmpty { Button("Clear") { clearFilters() }.buttonStyle(.plain).foregroundStyle(Palette.ink).underline() }
            }
            Picker("Collection", selection: $collectionID) {
                Text("All collections").tag(nil as UUID?)
                ForEach(organization.collections) { Text($0.name).tag(Optional($0.id)) }
            }.labelsHidden().accessibilityLabel("Filter by collection")
            Picker("Simulation", selection: $simulation) {
                Text("All simulations").tag("")
                ForEach(Array(Set(store.recipes.compactMap { $0.settings[.filmSimulation] })).sorted(), id: \.self) { Text($0).tag($0) }
            }.labelsHidden().accessibilityLabel("Filter by film simulation")
            Picker("Sort", selection: $sortOrder) { ForEach(["Newest", "Name", "Simulation"], id: \.self) { Text($0).tag($0) } }
        }.font(.system(size: 11)).controlSize(.small).padding(.horizontal, 14).padding(.bottom, 14)
    }

    private var photoToolsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("From a photograph to its settings").font(.system(size: 25, weight: .semibold))
                Text("Inspect an original Fujifilm JPEG or RAF to recover the recipe settings recorded by the camera. Review the result, then save it to your library.")
                    .font(.system(size: 13)).foregroundStyle(Palette.secondary).lineSpacing(4).frame(maxWidth: 620, alignment: .leading)
                Button { showPhotoInspector = true } label: { Label("Inspect original photo…", systemImage: "photo.badge.magnifyingglass") }.buttonStyle(.borderedProminent).tint(Palette.accent)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Use the original file").font(.system(size: 15, weight: .semibold))
                    Text("Choose the JPEG or RAF copied from your camera or memory card. Social networks, screenshots and edited exports often remove the Fujifilm MakerNote metadata. Missing or unknown values stay unspecified.")
                        .font(.system(size: 13)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    Text("RAW files and exact film rendering").font(.system(size: 15, weight: .semibold)).padding(.top, 10)
                    Text("For RAF development with the camera’s own processor, use Fujifilm X RAW Studio with a compatible connected camera. RecipeVault reads a RAF’s recorded settings but does not render RAW files; its recipe covers are approximate.")
                        .font(.system(size: 13)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    Button("Open X RAW Studio") { openRawStudio() }
                }
                Divider()
                HStack(spacing: 14) {
                    Image(systemName: "text.viewfinder").font(.system(size: 23)).foregroundStyle(Palette.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Have a screenshot of a recipe?").font(.system(size: 15, weight: .semibold))
                        Text("Use Import in the library. Text and QR reading happen on your Mac.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    Button("Import screenshot…") { showImport = true }
                }
                StatusNote(text: "Photo inspection stays on this Mac. Files are read without being modified.", symbol: "lock")
            }.padding(28).frame(maxWidth: 900, alignment: .leading)
        }
    }

    private func vaultRestoreSheet(_ preview: VaultArchivePreview) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Restore your RecipeVault").font(.system(size: 23, weight: .semibold))
            Text("Archive from \(preview.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            Divider()
            Text("\(preview.recipeCount) recipes · \(preview.kitCount) catalogs · \(preview.collectionCount) collections\n\(preview.backupCount) camera backups · \(preview.coverCount) covers")
                .font(.system(size: 14)).lineSpacing(8)
            StatusNote(text: "This replaces the library and backup vault on this Mac. Your current vault is kept in a recovery folder next to it. The connected camera is not changed.", symbol: "exclamationmark.triangle", warning: true)
            Divider()
            HStack {
                Button("Cancel") { restorePreview = nil; restoreURL = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restore vault") {
                    guard let url = restoreURL else { return }
                    restorePreview = nil; restoreURL = nil
                    run("Restoring vault…") {
                        let result = try VaultArchive.restore(from: url, into: store, expectedDigest: preview.archiveDigest)
                        try organization.reload(); clearFilters(); reconcileSelection()
                        activity = "Vault restored. Previous data saved in \(result.recoveryURL.lastPathComponent)."
                        NSWorkspace.shared.activateFileViewerSelecting([result.recoveryURL])
                    }
                }.buttonStyle(.borderedProminent).tint(Palette.accent)
            }
        }.padding(28).frame(width: 560).background(Palette.surface)
    }

    private var libraryEmptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: store.recipes.isEmpty ? "square.stack" : "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(Palette.secondary)
            Text(store.recipes.isEmpty ? "Build your recipe library" : "No matching recipe").font(.system(size: 24, weight: .semibold)).tracking(-0.4)
            Text(store.recipes.isEmpty ? "Import settings from a recipe page, a Simu code or a screenshot. You can also enter your own recipe, then choose a custom bank when your X-M5 is connected." : "Try another search, collection or film simulation, or clear your filters to see the full library.")
                .font(.system(size: 13)).lineSpacing(4).foregroundStyle(Palette.secondary).frame(maxWidth: 410, alignment: .leading)
            HStack {
                if store.recipes.isEmpty {
                    Button { showImport = true } label: { Label("Import recipe", systemImage: "square.and.arrow.down") }.buttonStyle(.borderedProminent).tint(Palette.accent)
                    Button("Create recipe") { editing = Recipe(name: "Untitled recipe") }
                } else { Button("Clear filters") { clearFilters() } }
            }
            if store.recipes.isEmpty {
                Divider().frame(maxWidth: 410).padding(.top, 12)
                Text("Simu · OFR · JSON · Text · Screenshots").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var cameraPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(camera.deviceInfo?.model ?? "FUJIFILM X-M5").font(.system(size: 27, weight: .semibold)).tracking(-0.5)
                        Label(camera.isConnected ? "Connected over USB" : "Camera not connected", systemImage: camera.isConnected ? "checkmark.circle.fill" : "cable.connector")
                            .font(.system(size: 12)).foregroundStyle(camera.isConnected ? Palette.ink : Palette.secondary)
                        Text(camera.status).font(.system(size: 12)).foregroundStyle(Palette.secondary).textSelection(.enabled)
                        if let info = camera.deviceInfo { Text("Firmware \(info.deviceVersion) · Serial \(info.serialNumber)").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        ForEach(1...4, id: \.self) { number in
                            Text("C\(number)").font(.system(size: 16, weight: .medium, design: .monospaced))
                                .frame(width: 43, height: 42).background(Palette.paper)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.line, lineWidth: 1))
                        }
                    }.accessibilityElement(children: .ignore).accessibilityLabel("Four custom recipe banks")
                }
                HStack {
                    if camera.isConnected {
                        Button("Read C1–C4") { readCamera() }.buttonStyle(.borderedProminent).tint(Palette.accent).disabled(busy)
                            .help("Reads all four banks in one fetch without switching banks")
                        Button("Save full backup") { saveFullBackup() }.disabled(busy)
                            .help("Saves the same settings file Tether App makes")
                        Button("Back up recipe banks") { backUpSlots() }.disabled(busy)
                            .help("Reads every value by switching banks, then restores the selection")
                        Button("Disconnect") { run("Disconnecting…") { await camera.disconnect(); slots = [] } }.disabled(busy)
                    } else {
                        ForEach(camera.cameras) { discovered in
                            Button("Connect \(discovered.name)") {
                                run("Connecting to camera…") { try requireCameraToSelf(); try await camera.connect(id: discovered.id); slots = []; activity = "Connected. Read the banks to inspect your camera." }
                            }.buttonStyle(.borderedProminent).tint(Palette.accent).disabled(busy)
                        }
                        if camera.cameras.isEmpty { Label("Waiting for a USB camera", systemImage: "cable.connector").font(.system(size: 12)).foregroundStyle(Palette.secondary) }
                    }
                }
                preflight
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Custom banks").font(.system(size: 15, weight: .semibold)); Spacer(); Text("Read the camera to inspect saved settings").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
                    StatusNote(text: "Read C1–C4 doesn’t switch banks, but dynamic range, D range priority, monochrome tone and grain that’s switched on aren’t decoded from it yet. Back up recipe banks reads those too.")
                    ForEach(1...4, id: \.self) { number in
                        bankRow(number)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("USB setup").font(.system(size: 14, weight: .semibold))
                    Text("Use a USB data cable. Set CONNECTION MODE to USB RAW CONV./BACKUP RESTORE and USB POWER SUPPLY/COMM SETTING to POWER SUPPLY OFF/COMM ON. Close Tether App, X Acquire, X RAW Studio and other camera apps.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    StatusNote(text: "X-M5 USB writing is experimental. The app checks advertised settings and saves a backup before writes. Keep a Tether App backup until your first write has been checked on the camera.", symbol: "exclamationmark.triangle", warning: true)
                }
            }.padding(28)
        }
    }

    @ViewBuilder private var preflight: some View {
        if !otherCameraApps.isEmpty {
            HStack(spacing: 10) {
                CautionLabel(text: "\(otherCameraApps.joined(separator: ", ")) is open. Quit it first, because only one app can use the camera safely.")
                Spacer()
                Button("Check again") { refreshPreflight() }
            }
        }
    }

    private func refreshPreflight() { otherCameraApps = CameraPreflight.otherCameraApps() }

    /// Refuses camera work while another camera app is running.
    private func requireCameraToSelf() throws {
        refreshPreflight()
        guard otherCameraApps.isEmpty else { throw VaultError.message("Quit \(otherCameraApps.joined(separator: ", ")) before using the camera here. Only one app can use it safely.") }
    }

    private func bankRow(_ number: Int) -> some View {
        let slot = slots.first { $0.slot == number }
        return HStack(spacing: 18) {
            Text("C\(number)").font(.system(size: 20, weight: .medium, design: .monospaced)).frame(width: 48)
            Rectangle().fill(Palette.line).frame(width: 1, height: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(slot?.name ?? "Not read yet").font(.system(size: 13, weight: .medium))
                if let slot {
                    Text(bankSummary(slot)).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
                    if !slot.readErrors.isEmpty { CautionLabel(text: "\(slot.readErrors.count) values not recognised yet. They are left out, not guessed.", size: 11) }
                } else {
                    Text("Connect and read C1–C4 to view this bank.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
            Spacer()
            if let slot {
                Button("Details") { editing = nil; inspectedSlot = slot }
                Button("Save to library") { do { try store.add([RecipeWireCodec.decode(slot)]); activity = "Saved C\(number) to your library." } catch { self.error = error.localizedDescription } }
            }
            Menu("Choose recipe…") {
                ForEach(store.recipes) { recipe in Button(recipe.name) { prepare(recipe, slot: number) } }
            }.disabled(!camera.isConnected || busy || store.recipes.isEmpty)
        }.padding(.horizontal, 16).padding(.vertical, 16).background(Palette.paper.opacity(0.7))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line, lineWidth: 0.7))
    }

    private var backupsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Keep your whole toolkit safe").font(.system(size: 25, weight: .semibold))
                    Text("One portable file for recipes, favourites, collections, catalogs, covers and the camera backups stored here.")
                        .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    HStack {
                        Button("Export complete vault…") { exportVault() }.buttonStyle(.borderedProminent).tint(Palette.accent).disabled(busy)
                        Button("Restore vault…") { previewVaultRestore() }.disabled(busy)
                    }
                    StatusNote(text: "Vault files contain any camera serial numbers in your backups. Keep them somewhere private. Photo originals and camera firmware are not included.")
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Camera settings backups").font(.system(size: 20, weight: .semibold)).tracking(-0.4)
                    Text("Recipe snapshots capture C1–C4. A full backup is the same settings file Tether App saves.")
                        .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                }
                HStack(spacing: 10) {
                    Button("Back up recipe banks") { backUpSlots() }.buttonStyle(.borderedProminent).tint(Palette.accent).disabled(!camera.isConnected || busy)
                    Button("Save full backup") { saveFullBackup() }.disabled(!camera.isConnected || busy)
                    Button("Open Tether App") { openAcquire() }
                    Spacer()
                    Button { NSWorkspace.shared.open(store.root) } label: { Label("Show vault", systemImage: "folder") }
                }
                StatusNote(text: "Recipe snapshots contain readable recipe properties, not every camera setting or your photos. Restore a full backup with Fujifilm Tether App; RecipeVault doesn’t write full backups to the camera.")
                Divider()
                HStack { Text("Backup history").font(.system(size: 14, weight: .semibold)); Spacer(); Text("\(store.backups.count) saved").font(.system(size: 12)).foregroundStyle(Palette.secondary) }
                if store.backups.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("No backups saved", systemImage: "externaldrive").font(.system(size: 16, weight: .medium))
                        Text("Connect your X-M5 to capture its recipe banks, or import an existing settings backup.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        Button("Import backup file…") { importBackup() }.padding(.top, 5)
                    }.padding(.vertical, 26)
                }
                ForEach(store.backups) { backup in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Image(systemName: backup.kind == .recipeSlots ? "square.stack.3d.up" : "externaldrive").font(.system(size: 18)).foregroundStyle(Palette.secondary).frame(width: 26)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(backup.title).font(.system(size: 13, weight: .semibold))
                                Text("\(backup.cameraModel) · \(ByteCountFormatter.string(fromByteCount: Int64(backup.byteCount), countStyle: .file))").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            Text(backup.createdAt, style: .date).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        }
                        HStack {
                            Text("SHA-256 checked on export / restore").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                            Spacer()
                            if store.banks(in: backup) != nil { Button("View banks") { viewingBackup = backup } }
                            Button("Export…") { exportBackup(backup) }
                            if backup.kind == .recipeSlots {
                                Menu("Restore bank…") { ForEach(1...4, id: \.self) { slot in Button("Restore C\(slot)") { restore(backup, slot: slot) } } }.disabled(!camera.isConnected || busy)
                            } else { Text("Restore with Tether App").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
                        }
                        Divider()
                    }
                }
            }.padding(28)
        }
    }

    private var guidePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("From recipe to camera").font(.system(size: 25, weight: .semibold)).tracking(-0.4)
                guide("1", "Build your library", "Paste recipe text or a Simu code, load an OFR/JSON file, or choose a screenshot. Screenshot reading runs locally on this Mac. Public page imports work best when the page exposes its settings as text. Always review names and values, especially after OCR.")
                guide("2", "Organise and prepare", "Mark favourites, filter by film simulation and group recipes into collections using the recipe actions menu. Save a catalog of four recipes for an outing. Catalogs keep their own copies, so later library edits won’t change them. Compare two recipes to see their differences, and export a PDF or copy the settings with attribution.")
                guide("3", "Connect and read", "Set the camera’s USB mode to USB RAW CONV./BACKUP RESTORE, use a data cable, and close other camera apps. Connect in Camera, then read C1–C4. This reads the settings file in one fetch without switching banks. No recipe is applied just by connecting.")
                guide("4", "Load a catalog", "Choose a catalog and load it, or send one recipe to a bank. Reviewing switches the bank selector to read each bank, then restores it. The app shows the planned changes, saves a backup, writes the included settings, and reads them back. A missing setting means keep the bank’s current value. For still photos, assign the custom bank to still mode and set the film simulation dial to C so the bank’s simulation is used.")
                guide("5", "Keep recoverable backups", "Save a full backup in Camera or Backups. Restore that file with Tether App’s RESTORE CAMERA SETTINGS command. Recipe-bank snapshots cover known recipe fields only. Export a complete RecipeVault file to preserve your library, organisation, covers and stored camera backups together. Vault restore affects this Mac’s data; camera restore is a separate reviewed operation.")
                Divider()
                Text("Compatibility").font(.system(size: 14, weight: .semibold))
                StatusNote(text: "This build targets the X-M5’s four custom banks. Its USB path is based on public Fujifilm PTP research, with strict property checks. X-M5 firmware 1.30 rejects the camera’s supported-values queries, so values are checked against a researched X-M5_0100 profile instead. A change is refused when RecipeVault could not undo it exactly from its own backup. Reading C1–C4 and switching banks have been tested on an X-M5 running firmware 1.30. Writing recipes and loading catalogs have not. After switching banks, the camera’s USB stopped responding once when its settings file was fetched next, so RecipeVault won’t fetch that file again until the camera has been unplugged. If a property is unsupported or a write cannot be verified, the app stops. A partial write may leave some settings changed; review the camera and restore the saved bank as needed.", symbol: "exclamationmark.triangle", warning: true)
                HStack(spacing: 20) {
                    Link("X-M5 manual", destination: URL(string: "https://app.fujifilm-dsc.com/en-int/manual/x-m5/")!)
                    Link("Tether App", destination: URL(string: "https://www.fujifilm-x.com/en-us/support/download/software/tether-app/")!)
                    Link("Protocol research", destination: URL(string: "https://github.com/ILFforever/fujifilm-ptp-recipes")!)
                }.font(.system(size: 12))
                Text("Independent software. Not affiliated with Fujifilm, Simu, FilmSim Recipes or any recipe publisher. Attribution travels with your recipes.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }.padding(32).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func guide(_ number: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(number).font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(width: 28, height: 28).background(Palette.paper)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.line, lineWidth: 1))
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(4)
            }
        }
    }

    private func run(_ message: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; activity = message
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() }
            catch { self.error = error.localizedDescription; activity = "Stopped: \(error.localizedDescription)" }
        }
    }

    private func readCamera() {
        run("Reading C1–C4…") { try requireCameraToSelf(); slots = try await service.readSlots(); activity = "Read \(slots.count) banks. No recipe settings were changed." }
    }
    private func backUpSlots() {
        run("Reading every bank and saving a backup…") {
            try requireCameraToSelf()
            let result = try await service.readAllProperties()
            guard let info = camera.deviceInfo else { throw VaultError.message("Camera disconnected.") }
            try store.saveSlots(result, camera: info, title: "Manual recipe-bank backup")
            slots = result; activity = "Recipe-bank backup saved locally."
        }
    }
    private func saveFullBackup() {
        run("Downloading the camera’s settings file…") {
            try requireCameraToSelf()
            let data = try await service.readFullBackup()
            guard let info = camera.deviceInfo else { throw VaultError.message("Camera disconnected.") }
            try store.savePayload(data, title: "Full camera backup", kind: .cameraBlob, camera: info, ext: "dat")
            activity = "Full camera backup saved. Restore it with Tether App."
        }
    }
    private func bankSummary(_ slot: CameraSlotSnapshot) -> String {
        let recipe = slot.recipe
        return [recipe.settings[.filmSimulation], recipe.settings[.whiteBalance]].compactMap { $0 }.joined(separator: " · ")
    }
    private func prepare(_ recipe: Recipe, slot: Int) {
        run("Checking C\(slot) and preparing changes…") {
            try requireCameraToSelf()
            let result = try await service.plan(recipe: recipe, slot: slot)
            pendingRecipeName = recipe.name; plan = result; activity = "Review the proposed changes to C\(slot)."
        }
    }
    private func prepareCatalog(_ kit: RecipeKit) {
        run("Reading C1–C4 and preparing \(kit.name)…") {
            try requireCameraToSelf()
            let recipes = Dictionary(uniqueKeysWithValues: kit.slots.map { ($0.slot, $0.recipe) })
            catalogPlan = try await service.planCatalog(id: kit.id, name: kit.name, recipes: recipes)
            activity = "Review the changes before loading \(kit.name)."
        }
    }
    private func applyCatalog(_ current: CatalogWritePlan) {
        catalogPlan = nil
        run("Backing up all banks, then loading \(current.catalogName)…") {
            try requireCameraToSelf()
            let awake = CameraPreflight.beginWriteActivity("Loading a catalog onto the camera")
            defer { ProcessInfo.processInfo.endActivity(awake) }
            try organization.clearLoaded()
            let reports = try await service.applyAll(current.plans) { snapshots, info in
                try store.saveSlots(snapshots, camera: info, title: "Before loading \(current.catalogName)")
            }
            slots = reports.map(\.snapshot).sorted { $0.slot < $1.slot }
            try organization.markLoaded(current.catalogID)
            activity = "\(current.catalogName) is loaded and every bank was read back. Check the look on your camera."
            reportUnexpected(reports)
        }
    }
    private func reportUnexpected(_ reports: [RecipeWriteReport]) {
        let items = reports.flatMap(\.unexpected)
        if !items.isEmpty { error = "The write was verified, but these settings also changed on the camera: \(items.joined(separator: ", ")). Your backup from before the write is saved." }
    }
    private func captureCatalog() {
        run("Reading every bank…") {
            try requireCameraToSelf()
            let banks = try await service.readAllProperties()
            let date = Date().formatted(date: .abbreviated, time: .omitted)
            let copies = banks.map { bank -> RecipeKitSlot in
                var recipe = bank.recipe
                if recipe.name.isEmpty { recipe.name = "C\(bank.slot)" }
                recipe.suggestedSlot = bank.slot
                return RecipeKitSlot(slot: bank.slot, recipe: recipe)
            }
            let kit = try organization.saveKit(name: "Camera \(date)", slots: copies)
            slots = banks; activity = "Saved the camera’s banks as \(kit.name)."
        }
    }
    private func apply(_ current: RecipeWritePlan) {
        plan = nil
        run("Backing up camera banks before writing…") {
            try requireCameraToSelf()
            let awake = CameraPreflight.beginWriteActivity("Writing a recipe to the camera")
            defer { ProcessInfo.processInfo.endActivity(awake) }
            try organization.clearLoaded()
            let report = try await service.apply(current) { snapshots, info in
                try store.saveSlots(snapshots, camera: info, title: "Before writing C\(current.slot)")
            }
            slots = slots.map { $0.slot == report.slot ? report.snapshot : $0 }
            activity = "C\(current.slot) written and read back successfully. Check the look on your camera."
            reportUnexpected([report])
        }
    }
    private func restore(_ backup: BackupRecord, slot: Int) {
        run("Checking backup and preparing C\(slot) restore…") {
            try requireCameraToSelf()
            let archive = try store.archive(backup)
            guard let info = camera.deviceInfo,
                  archive.camera.model == info.model,
                  archive.camera.deviceVersion == info.deviceVersion,
                  !info.serialNumber.isEmpty, archive.camera.serialNumber == info.serialNumber else {
                throw VaultError.message("Restore requires the same camera model, serial number and firmware as the backup.")
            }
            guard let snapshot = archive.slots.first(where: { $0.slot == slot }) else { throw VaultError.message("This backup does not contain C\(slot).") }
            let result = try await service.plan(snapshot: snapshot, slot: slot)
            pendingRecipeName = "Restore \(snapshot.name)"; plan = result
        }
    }
    private func exportRecipe(_ recipe: Recipe, ofr: Bool) {
        do {
            let text = ofr ? try RecipeExporter.ofr(recipe: recipe) : try RecipeExporter.json(recipes: [recipe])
            try saveData(Data(text.utf8), suggestedName: "\(recipe.name).\(ofr ? "ofr" : "json")")
        } catch { self.error = error.localizedDescription }
    }
    private func exportVault() {
        let panel = NSSavePanel()
        panel.title = "Export complete RecipeVault"
        panel.nameFieldStringValue = "RecipeVault-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).recipevault"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("Checking files and exporting vault…") {
            let preview = try VaultArchive.export(store: store, to: url)
            activity = "Exported \(preview.recipeCount) recipes, \(preview.kitCount) catalogs and \(preview.backupCount) camera backups."
        }
    }
    private func previewVaultRestore() {
        let panel = NSOpenPanel(); panel.title = "Choose a complete RecipeVault archive"; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("Checking archive before restore…") { restorePreview = try VaultArchive.preview(at: url); restoreURL = url }
    }
    private func openRawStudio() {
        run("Releasing the camera for X RAW Studio…") {
            await camera.disconnect(); slots = []
            let paths = ["/Applications/FUJIFILM X RAW STUDIO.app", "/Applications/FUJIFILM X RAW STUDIO/FUJIFILM X RAW STUDIO.app"]
            if let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            else { NSWorkspace.shared.open(URL(string: "https://fujifilm-x.com/en-us/support/download/software/x-raw-studio/")!) }
            activity = "X RAW Studio uses a compatible connected camera to develop RAF files."
        }
    }
    private func exportBackup(_ backup: BackupRecord) {
        do { try saveData(store.payload(backup), suggestedName: "\(backup.title).\(URL(fileURLWithPath: backup.payloadName).pathExtension)") }
        catch { self.error = error.localizedDescription }
    }
    private func saveData(_ data: Data, suggestedName: String) throws {
        let panel = NSSavePanel(); panel.nameFieldStringValue = suggestedName.replacingOccurrences(of: "/", with: "-")
        if panel.runModal() == .OK, let url = panel.url { try data.write(to: url, options: .atomic) }
    }
    private func importBackup() {
        let panel = NSOpenPanel(); panel.title = "Choose a RecipeVault or Fujifilm settings backup"; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (attributes.fileSize ?? 0) <= 64 * 1024 * 1024 else { throw VaultError.message("Backup is larger than 64 MB. Choose a settings backup, not an image file.") }
                let data = try Data(contentsOf: url)
                if url.pathExtension.lowercased() == "json" {
                    let archive = try JSONDecoder().decode(SlotArchive.self, from: data)
                    guard archive.formatVersion == 1, archive.slots.count == 4,
                          Set(archive.slots.map(\.slot)) == Set(1...4), archive.camera.isXM5 else {
                        throw VaultError.message("Choose a supported X-M5 recipe-bank archive containing C1–C4.")
                    }
                    try store.saveSlots(archive.slots, camera: archive.camera, title: url.deletingPathExtension().lastPathComponent)
                    activity = "Imported a recipe-bank backup. Restore requires the same camera and firmware."
                } else {
                    try store.savePayload(data, title: url.deletingPathExtension().lastPathComponent, kind: .acquireFile, ext: url.pathExtension)
                    activity = "Stored the original backup file. Tether App validates this file when restoring."
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func openAcquire() {
        run("Releasing the camera for Tether App…") {
            await camera.disconnect(); slots = []
            let paths = ["/Applications/FUJIFILM TETHER APP.app", "/Applications/FUJIFILM TETHER APP/FUJIFILM TETHER APP.app", "/Applications/FUJIFILM X Acquire.app", "/Applications/FUJIFILM X Acquire/FUJIFILM X Acquire.app"]
            if let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            else { NSWorkspace.shared.open(URL(string: "https://www.fujifilm-x.com/en-us/support/download/software/tether-app/")!) }
            activity = "Use Tether App to save or restore full camera settings."
        }
    }
}
