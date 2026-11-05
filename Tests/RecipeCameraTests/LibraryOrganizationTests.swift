import XCTest
import FujiCore
@testable import RecipeVault

@MainActor
final class LibraryOrganizationTests: XCTestCase {
    private func withTemporaryOrganization(_ body: (URL, LibraryOrganization) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecipeOrganizationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, LibraryOrganization(root: root))
    }

    private var recipe: Recipe {
        Recipe(name: "Personal Chrome", sourceURL: "https://example.org/recipe", author: "Camera owner",
               notes: "Outdoor test", settings: [.filmSimulation: "Classic Chrome", .highlight: "-1"],
               createdAt: Date(timeIntervalSince1970: 1_700_000_000), sensors: ["X-Trans IV"],
               suggestedSlot: 2,
               cover: RecipeCover(filename: "personal.png", credit: "Camera owner", renderingNote: "Approximate preview"))
    }

    func testMissingOrganizationStartsEmptyWithoutCreatingUserData() async throws {
        try withTemporaryOrganization { root, organization in
            XCTAssertTrue(organization.favoriteIDs.isEmpty)
            XCTAssertTrue(organization.collections.isEmpty)
            XCTAssertTrue(organization.kits.isEmpty)
            XCTAssertNil(organization.errorMessage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testFavoritesAndCollectionsPersistAcrossReloadAndDeletion() async throws {
        try withTemporaryOrganization { root, organization in
            let first = UUID(), second = UUID()
            let collection = try organization.createCollection(name: "  Weekend  ")
            XCTAssertEqual(collection.name, "Weekend")
            try organization.toggleFavorite(first)
            try organization.toggleFavorite(second)
            try organization.toggleFavorite(second)
            try organization.toggleMembership(recipeID: first, collectionID: collection.id)
            try organization.toggleMembership(recipeID: second, collectionID: collection.id)
            try organization.toggleMembership(recipeID: second, collectionID: collection.id)
            try organization.renameCollection(collection.id, to: " Travel ")

            let reopened = LibraryOrganization(root: root)
            XCTAssertEqual(reopened.favoriteIDs, [first])
            XCTAssertTrue(reopened.isFavorite(first))
            XCTAssertEqual(reopened.collections, [RecipeCollection(id: collection.id, name: "Travel", recipeIDs: [first])])
            try reopened.deleteCollection(collection.id)
            XCTAssertTrue(LibraryOrganization(root: root).collections.isEmpty)
            XCTAssertTrue(reopened.isFavorite(first))
        }
    }

    func testOlderStateDefaultsAbsentFieldsAndRetainsUnresolvedReferences() async throws {
        try withTemporaryOrganization { root, organization in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let unresolved = UUID()
            let oldData = Data("{\"favoriteIDs\":[\"\(unresolved.uuidString)\"]}".utf8)
            let file = root.appendingPathComponent("organization.json")
            try oldData.write(to: file)
            try organization.reload()
            XCTAssertTrue(organization.isFavorite(unresolved))
            XCTAssertTrue(organization.collections.isEmpty)
            XCTAssertTrue(organization.kits.isEmpty)
            XCTAssertEqual(try Data(contentsOf: file), oldData)
            let collection = try organization.createCollection(name: "Recovered")
            try organization.toggleMembership(recipeID: unresolved, collectionID: collection.id)
            let reopened = LibraryOrganization(root: root)
            XCTAssertTrue(reopened.isFavorite(unresolved))
            XCTAssertEqual(reopened.collections[0].recipeIDs, [unresolved])
        }
    }

    func testKitSnapshotsSurviveSourceEditsAndRecipeRemoval() async throws {
        try withTemporaryOrganization { root, organization in
            var source = recipe
            let original = source
            let unrelated = UUID()
            let kit = try organization.saveKit(name: " Weekend set ", slots: [RecipeKitSlot(slot: 4, recipe: source), RecipeKitSlot(slot: 1, recipe: source)])
            XCTAssertEqual(kit.name, "Weekend set")
            XCTAssertEqual(kit.slots.map(\.slot), [1, 4])
            let collection = try organization.createCollection(name: "Travel")
            try organization.toggleMembership(recipeID: source.id, collectionID: collection.id)
            try organization.toggleMembership(recipeID: unrelated, collectionID: collection.id)
            try organization.toggleFavorite(source.id)
            try organization.toggleFavorite(unrelated)

            source.name = "Edited source"
            source.settings[.highlight] = "4"
            source.cover = nil
            try organization.removeRecipeReferences(source.id)
            let reopened = LibraryOrganization(root: root)
            XCTAssertEqual(reopened.kits[0].slots.map(\.recipe), [original, original])
            XCTAssertEqual(reopened.kits[0].id, kit.id)
            XCTAssertEqual(reopened.favoriteIDs, [unrelated])
            XCTAssertEqual(reopened.collections[0].recipeIDs, [unrelated])
        }
    }

    func testKitUpdatePreservesIdentityAndCreationDateWhileReplacingSnapshots() async throws {
        try withTemporaryOrganization { root, organization in
            let original = try organization.saveKit(name: "Weekend", slots: [RecipeKitSlot(slot: 1, recipe: recipe)])
            var changed = recipe
            changed.settings[.highlight] = "2"
            try organization.updateKit(original.id, name: "Night", slots: [RecipeKitSlot(slot: 3, recipe: changed)])
            let reopened = LibraryOrganization(root: root)
            XCTAssertEqual(reopened.kits.count, 1)
            XCTAssertEqual(reopened.kits[0].id, original.id)
            XCTAssertEqual(reopened.kits[0].createdAt, original.createdAt)
            XCTAssertGreaterThanOrEqual(reopened.kits[0].updatedAt, original.updatedAt)
            XCTAssertEqual(reopened.kits[0].name, "Night")
            XCTAssertEqual(reopened.kits[0].slots, [RecipeKitSlot(slot: 3, recipe: changed)])
            try reopened.deleteKit(original.id)
            XCTAssertTrue(LibraryOrganization(root: root).kits.isEmpty)
        }
    }

    func testInvalidKitMutationsNeverReplaceValidSavedData() async throws {
        try withTemporaryOrganization { root, organization in
            let slot = RecipeKitSlot(slot: 1, recipe: recipe)
            let valid = try organization.saveKit(name: "Valid", slots: [slot])
            let file = root.appendingPathComponent("organization.json")
            let originalBytes = try Data(contentsOf: file)
            let invalidSlots = [[], [slot, slot], [RecipeKitSlot(slot: 0, recipe: recipe)],
                                [RecipeKitSlot(slot: 5, recipe: recipe)], Array(repeating: slot, count: 5)]
            for slots in invalidSlots {
                XCTAssertThrowsError(try organization.saveKit(name: "Invalid", slots: slots))
                XCTAssertThrowsError(try organization.updateKit(valid.id, name: "Invalid", slots: slots))
                XCTAssertEqual(organization.kits, [valid])
                XCTAssertEqual(try Data(contentsOf: file), originalBytes)
            }
            XCTAssertThrowsError(try organization.saveKit(name: " \n ", slots: [slot]))
            XCTAssertThrowsError(try organization.createCollection(name: ""))
            XCTAssertThrowsError(try organization.updateKit(UUID(), name: "Missing", slots: [slot]))
            XCTAssertThrowsError(try organization.toggleMembership(recipeID: UUID(), collectionID: UUID()))
            XCTAssertEqual(try Data(contentsOf: file), originalBytes)
        }
    }

    func testMalformedFileIsPreservedAndBlocksAllMutations() async throws {
        try withTemporaryOrganization { root, organization in
            let collection = try organization.createCollection(name: "Existing")
            let file = root.appendingPathComponent("organization.json")
            let broken = Data("{broken".utf8)
            try broken.write(to: file)
            let damaged = LibraryOrganization(root: root)
            XCTAssertNotNil(damaged.errorMessage)
            XCTAssertThrowsError(try damaged.toggleFavorite(UUID()))
            XCTAssertThrowsError(try damaged.createCollection(name: "New"))
            XCTAssertThrowsError(try damaged.renameCollection(collection.id, to: "New"))
            XCTAssertThrowsError(try damaged.deleteCollection(collection.id))
            XCTAssertThrowsError(try damaged.removeRecipeReferences(UUID()))
            XCTAssertThrowsError(try damaged.saveKit(name: "New", slots: [RecipeKitSlot(slot: 1, recipe: recipe)]))
            XCTAssertThrowsError(try damaged.deleteKit(UUID()))
            XCTAssertEqual(try Data(contentsOf: file), broken)
        }
    }

    func testDecodeRejectsFutureVersionsDuplicateSlotsAndDuplicateIdentifiers() async throws {
        XCTAssertThrowsError(try LibraryOrganizationState.decode(Data("{\"formatVersion\":2}".utf8)))
        var malformed = LibraryOrganizationState()
        let collection = RecipeCollection(name: "Duplicate")
        malformed.collections = [collection, collection]
        XCTAssertThrowsError(try LibraryOrganizationState.decode(JSONEncoder().encode(malformed)))
        malformed.collections = []
        let slot = RecipeKitSlot(slot: 1, recipe: recipe)
        malformed.kits = [RecipeKit(name: "Duplicate slot", slots: [slot, slot])]
        XCTAssertThrowsError(try LibraryOrganizationState.decode(JSONEncoder().encode(malformed)))
        malformed.kits = [RecipeKit(name: "Outside X-M5", slots: [RecipeKitSlot(slot: 7, recipe: recipe)])]
        XCTAssertThrowsError(try LibraryOrganizationState.decode(JSONEncoder().encode(malformed)))
        let kit = RecipeKit(name: "Duplicate identity", slots: [slot])
        malformed.kits = [kit, kit]
        XCTAssertThrowsError(try LibraryOrganizationState.decode(JSONEncoder().encode(malformed)))
    }

    func testFailedFileWriteDoesNotCommitMemory() async throws {
        try withTemporaryOrganization { root, organization in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("organization.json"), withIntermediateDirectories: false)
            XCTAssertThrowsError(try organization.toggleFavorite(UUID()))
            XCTAssertTrue(organization.favoriteIDs.isEmpty)
            XCTAssertTrue(organization.collections.isEmpty)
            XCTAssertTrue(organization.kits.isEmpty)
        }
    }

    func testExternalChangeCannotBeOverwrittenAndReloadAdoptsRestoredState() async throws {
        try withTemporaryOrganization { root, organization in
            let first = UUID(), second = UUID()
            try organization.toggleFavorite(first)
            let anotherWindow = LibraryOrganization(root: root)
            try anotherWindow.toggleFavorite(second)
            let file = root.appendingPathComponent("organization.json")
            let latestBytes = try Data(contentsOf: file)
            XCTAssertThrowsError(try organization.toggleFavorite(first))
            XCTAssertEqual(organization.favoriteIDs, [first])
            XCTAssertEqual(try Data(contentsOf: file), latestBytes)
            try organization.reload()
            XCTAssertEqual(organization.favoriteIDs, [first, second])
            try organization.toggleFavorite(first)
            XCTAssertEqual(LibraryOrganization(root: root).favoriteIDs, [second])

            try FileManager.default.removeItem(at: file)
            try organization.reload()
            XCTAssertTrue(organization.favoriteIDs.isEmpty)
            XCTAssertNil(organization.errorMessage)
            try organization.toggleFavorite(first)
            XCTAssertEqual(LibraryOrganization(root: root).favoriteIDs, [first])
        }
    }

    func testFailedReloadRetainsMemoryAndRecoveredFileUnblocksMutations() async throws {
        try withTemporaryOrganization { root, organization in
            let recipeID = UUID()
            try organization.toggleFavorite(recipeID)
            let file = root.appendingPathComponent("organization.json")
            let goodBytes = try Data(contentsOf: file)
            try Data("null".utf8).write(to: file)
            XCTAssertThrowsError(try organization.reload())
            XCTAssertEqual(organization.favoriteIDs, [recipeID])
            XCTAssertThrowsError(try organization.toggleFavorite(recipeID))
            try goodBytes.write(to: file)
            try organization.reload()
            XCTAssertNil(organization.errorMessage)
            try organization.toggleFavorite(recipeID)
            XCTAssertTrue(organization.favoriteIDs.isEmpty)
        }
    }

    func testSymlinkOrganizationCannotReadOrChangeAnotherFile() async throws {
        try withTemporaryOrganization { root, organization in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let outside = root.appendingPathComponent("external.json")
            let original = Data("{}".utf8)
            try original.write(to: outside)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("organization.json"), withDestinationURL: outside)
            XCTAssertThrowsError(try organization.reload())
            XCTAssertThrowsError(try organization.toggleFavorite(UUID()))
            XCTAssertEqual(try Data(contentsOf: outside), original)
        }
    }

    func testLoadedCatalogTracksEditsDeletesAndReopen() throws {
        try withTemporaryOrganization { root, organization in
            let slots = (1...4).map { RecipeKitSlot(slot: $0, recipe: Recipe(name: "Bank \($0)")) }
            let kit = try organization.saveKit(name: "Outing", slots: slots)
            XCTAssertFalse(organization.isLoaded(kit))
            try organization.markLoaded(kit.id, at: kit.updatedAt.addingTimeInterval(1))
            XCTAssertTrue(organization.isLoaded(try XCTUnwrap(organization.kits.first)))
            XCTAssertTrue(LibraryOrganization(root: root).isLoaded(try XCTUnwrap(organization.kits.first)), "the record survives a restart")
            var edited = slots; edited[0].recipe.name = "Changed"
            try organization.updateKit(kit.id, name: "Outing", slots: edited)
            let updated = try XCTUnwrap(organization.kits.first)
            try organization.markLoaded(kit.id, at: updated.updatedAt.addingTimeInterval(-1))
            XCTAssertFalse(organization.isLoaded(updated), "a catalog edited after loading no longer matches the camera")
            try organization.clearLoaded()
            XCTAssertNil(organization.loadedCatalog)
            try organization.markLoaded(kit.id)
            try organization.deleteKit(kit.id)
            XCTAssertNil(organization.loadedCatalog)
        }
    }

    func testOnCameraSourceNeverShowsBanksFromBeforeALoad() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let bank = { (slot: Int, name: String) in CameraSlotSnapshot(slot: slot, name: name, properties: [:]) }
        let kit = RecipeKit(name: "People", createdAt: t0, updatedAt: t0, slots: [RecipeKitSlot(slot: 1, recipe: Recipe(name: "New — Recipe"))])
        let before = (title: "Before loading People", createdAt: t0.addingTimeInterval(10), banks: [bank(1, "old")])
        let loaded = LoadedCatalog(kitID: kit.id, loadedAt: t0.addingTimeInterval(11))

        XCTAssertNil(CameraBankSource.resolve(lastRead: [], loaded: nil, kits: [], backups: []))
        // After a restart the newest backup still holds the old banks, so the verified load wins.
        let afterLoad = CameraBankSource.resolve(lastRead: [], loaded: loaded, kits: [kit], backups: [before])
        XCTAssertEqual(afterLoad?.banks.first?.name, "New Recipe")
        // A read saved after the load is better evidence than the load.
        let later = (title: "Manual", createdAt: t0.addingTimeInterval(20), banks: [bank(1, "fresh")])
        XCTAssertEqual(CameraBankSource.resolve(lastRead: [], loaded: loaded, kits: [kit], backups: [before, later])?.banks.first?.name, "fresh")
        // This session's read beats everything.
        XCTAssertEqual(CameraBankSource.resolve(lastRead: [bank(1, "live")], loaded: loaded, kits: [kit], backups: [later])?.banks.first?.name, "live")
        // A failed load clears the record, leaving only the backup, described as a saved read.
        let failed = CameraBankSource.resolve(lastRead: [], loaded: nil, kits: [kit], backups: [before])
        XCTAssertEqual(failed?.banks.first?.name, "old"); XCTAssertTrue(failed?.label.hasPrefix("SAVED READ") == true)
        // A catalog edited after its load no longer describes the camera.
        var edited = kit; edited.updatedAt = t0.addingTimeInterval(30)
        XCTAssertEqual(CameraBankSource.resolve(lastRead: [], loaded: loaded, kits: [edited], backups: [before])?.banks.first?.name, "old")
    }
}
