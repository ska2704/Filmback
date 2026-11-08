import Foundation
import Combine
import FujiCore

struct RecipeCollection: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var recipeIDs: Set<UUID>

    init(id: UUID = UUID(), name: String, recipeIDs: Set<UUID> = []) {
        self.id = id
        self.name = name
        self.recipeIDs = recipeIDs
    }
}

struct RecipeKitSlot: Identifiable, Codable, Equatable, Sendable {
    var slot: Int
    var recipe: Recipe
    var id: Int { slot }
}

struct RecipeKit: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var slots: [RecipeKitSlot]

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), updatedAt: Date = Date(), slots: [RecipeKitSlot]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.slots = slots
    }
}

struct LoadedCatalog: Codable, Equatable, Sendable {
    var kitID: UUID
    var loadedAt: Date
}

struct LibraryOrganizationState: Codable, Equatable, Sendable {
    var formatVersion = 1
    var favoriteIDs: Set<UUID> = []
    var collections: [RecipeCollection] = []
    var kits: [RecipeKit] = []
    var loadedCatalog: LoadedCatalog?

    init() {}

    private enum CodingKeys: String, CodingKey { case formatVersion, favoriteIDs, collections, kits, loadedCatalog }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        favoriteIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .favoriteIDs) ?? []
        collections = try values.decodeIfPresent([RecipeCollection].self, forKey: .collections) ?? []
        kits = try values.decodeIfPresent([RecipeKit].self, forKey: .kits) ?? []
        loadedCatalog = try values.decodeIfPresent(LoadedCatalog.self, forKey: .loadedCatalog)
        try validate()
    }

    static func decode(_ data: Data) throws -> LibraryOrganizationState {
        try JSONDecoder().decode(Self.self, from: data)
    }

    func validate() throws {
        guard formatVersion == 1 else {
            throw LibraryOrganizationError.message("This organization file uses an unsupported version. Update Filmback before opening it.")
        }
        guard Set(collections.map(\.id)).count == collections.count,
              Set(kits.map(\.id)).count == kits.count else {
            throw LibraryOrganizationError.message("The organization file contains duplicate collection or kit identifiers.")
        }
        for collection in collections {
            try Self.validateName(collection.name)
        }
        for kit in kits {
            try Self.validateName(kit.name)
            try Self.validateSlots(kit.slots)
        }
    }

    static func validateSlots(_ slots: [RecipeKitSlot]) throws {
        guard (1...4).contains(slots.count) else {
            throw LibraryOrganizationError.message("A catalog needs between one and four recipes.")
        }
        guard slots.allSatisfy({ (1...4).contains($0.slot) }) else {
            throw LibraryOrganizationError.message("Catalogs use C1 through C4 only.")
        }
        guard Set(slots.map(\.slot)).count == slots.count else {
            throw LibraryOrganizationError.message("Each slot can appear only once in a kit.")
        }
        for slot in slots {
            try validateName(slot.recipe.name)
            try slot.recipe.cover?.validate()
        }
    }

    private static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryOrganizationError.message("Give every collection, kit and saved recipe a name.")
        }
    }
}

@MainActor
final class LibraryOrganization: ObservableObject {
    @Published private var state = LibraryOrganizationState()
    @Published var errorMessage: String?
    let root: URL
    private var readable = true
    private var loadedData: Data?

    var favoriteIDs: Set<UUID> { state.favoriteIDs }
    var collections: [RecipeCollection] { state.collections }
    var kits: [RecipeKit] { state.kits }
    var loadedCatalog: LoadedCatalog? { state.loadedCatalog }
    private var fileURL: URL { root.appendingPathComponent("organization.json") }

    init(root: URL) {
        self.root = root
        do { try reload() }
        catch { /* reload retains the original file and exposes the error. */ }
    }

    func reload() throws {
        do {
            let data = try readFile()
            let next = try data.map(LibraryOrganizationState.decode) ?? LibraryOrganizationState()
            state = next
            loadedData = data
            readable = true
            errorMessage = nil
        } catch {
            readable = false
            errorMessage = "The organization file could not be opened. Your existing file has been preserved. \(error.localizedDescription)"
            throw error
        }
    }

    func isFavorite(_ recipeID: UUID) -> Bool { state.favoriteIDs.contains(recipeID) }

    func toggleFavorite(_ recipeID: UUID) throws {
        try mutate { next in
            if next.favoriteIDs.contains(recipeID) { next.favoriteIDs.remove(recipeID) }
            else { next.favoriteIDs.insert(recipeID) }
        }
    }

    @discardableResult
    func createCollection(name: String) throws -> RecipeCollection {
        let collection = RecipeCollection(name: cleaned(name))
        try mutate { $0.collections.append(collection) }
        return collection
    }

    func renameCollection(_ collectionID: UUID, to name: String) throws {
        try mutate { next in
            guard let index = next.collections.firstIndex(where: { $0.id == collectionID }) else {
                throw LibraryOrganizationError.message("That collection no longer exists.")
            }
            next.collections[index].name = cleaned(name)
        }
    }

    func deleteCollection(_ collectionID: UUID) throws {
        try mutate { $0.collections.removeAll { $0.id == collectionID } }
    }

    func toggleMembership(recipeID: UUID, collectionID: UUID) throws {
        try mutate { next in
            guard let index = next.collections.firstIndex(where: { $0.id == collectionID }) else {
                throw LibraryOrganizationError.message("That collection no longer exists.")
            }
            if next.collections[index].recipeIDs.contains(recipeID) {
                next.collections[index].recipeIDs.remove(recipeID)
            } else {
                next.collections[index].recipeIDs.insert(recipeID)
            }
        }
    }

    @discardableResult
    func saveKit(name: String, slots: [RecipeKitSlot]) throws -> RecipeKit {
        let now = Date()
        let kit = RecipeKit(name: cleaned(name), createdAt: now, updatedAt: now, slots: slots.sorted { $0.slot < $1.slot })
        try mutate { $0.kits.append(kit) }
        return kit
    }

    func updateKit(_ kitID: UUID, name: String, slots: [RecipeKitSlot]) throws {
        try mutate { next in
            guard let index = next.kits.firstIndex(where: { $0.id == kitID }) else {
                throw LibraryOrganizationError.message("That kit no longer exists.")
            }
            next.kits[index].name = cleaned(name)
            next.kits[index].slots = slots.sorted { $0.slot < $1.slot }
            next.kits[index].updatedAt = Date()
        }
    }

    func deleteKit(_ kitID: UUID) throws {
        try mutate { next in
            next.kits.removeAll { $0.id == kitID }
            if next.loadedCatalog?.kitID == kitID { next.loadedCatalog = nil }
        }
    }

    /// Records the catalog verified on the camera. Editing the catalog later clears the match.
    func markLoaded(_ kitID: UUID, at date: Date = Date()) throws {
        try mutate { $0.loadedCatalog = LoadedCatalog(kitID: kitID, loadedAt: date) }
    }

    /// Call before anything else changes the banks, so "On camera" can't outlive what's on the camera.
    func clearLoaded() throws {
        try mutate { $0.loadedCatalog = nil }
    }

    func isLoaded(_ kit: RecipeKit) -> Bool {
        guard let loaded = state.loadedCatalog, loaded.kitID == kit.id else { return false }
        return kit.updatedAt <= loaded.loadedAt
    }

    func removeRecipeReferences(_ recipeID: UUID) throws {
        try mutate { next in
            next.favoriteIDs.remove(recipeID)
            for index in next.collections.indices { next.collections[index].recipeIDs.remove(recipeID) }
        }
    }

    private func cleaned(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func readFile() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LibraryOrganizationError.message("organization.json must be a regular file inside the vault.")
        }
        return try Data(contentsOf: fileURL)
    }

    private func mutate(_ change: (inout LibraryOrganizationState) throws -> Void) throws {
        guard readable else {
            throw LibraryOrganizationError.message("Repair or recover organization.json before changing favorites, collections or kits. The original file has been preserved.")
        }
        guard try readFile() == loadedData else {
            throw LibraryOrganizationError.message("The organization file changed outside this window. Reload the vault before making more changes.")
        }
        var next = state
        try change(&next)
        try next.validate()
        guard next != state else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        state = next
        loadedData = data
        errorMessage = nil
    }
}

enum LibraryOrganizationError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}
