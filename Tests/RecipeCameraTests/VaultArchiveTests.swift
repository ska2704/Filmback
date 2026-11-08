import XCTest
import FujiCore
@testable import Filmback

@MainActor
final class VaultArchiveTests: XCTestCase {
    private func withFixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VaultArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func recipe(_ name: String = "Personal Chrome", cover: String? = nil) -> Recipe {
        Recipe(name: name, notes: "Personal settings", settings: [.filmSimulation: "Classic Chrome", .highlight: "-1"],
               cover: cover.map { RecipeCover(filename: $0, credit: "Camera owner", renderingNote: "Original photo") })
    }

    private func put(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func editArchive(_ url: URL, _ edit: (inout VaultArchive.Envelope) throws -> Void) throws {
        var envelope = try JSONDecoder().decode(VaultArchive.Envelope.self, from: Data(contentsOf: url))
        try edit(&envelope)
        envelope.fileCount = envelope.files.count
        envelope.totalBytes = envelope.files.reduce(0) { $0 + $1.data.count }
        try JSONEncoder().encode(envelope).write(to: url)
    }

    private func archiveWithRecipe(_ directory: URL) throws -> (VaultStore, URL) {
        let store = VaultStore(root: directory.appendingPathComponent("source"), coverResources: nil)
        try store.save(recipe())
        let url = directory.appendingPathComponent("portable.filmback")
        try VaultArchive.export(store: store, to: url)
        return (store, url)
    }

    func testCompleteRoundTripIncludesOrganizationPayloadsAllCoversAndRecovery() async throws {
        try withFixture { directory in
            let resources = directory.appendingPathComponent("resources")
            try put(Data([1, 2, 3]), at: resources.appendingPathComponent("Covers/bundled.png"))
            let source = VaultStore(root: directory.appendingPathComponent("source"), coverResources: resources)
            let original = recipe("Library recipe", cover: "local.jpg")
            let kitRecipe = recipe("Snapshot only", cover: "bundled.png")
            try put(Data([4, 5]), at: source.root.appendingPathComponent("Covers/local.jpg"))
            try source.save(original)
            let backup = try source.savePayload(Data([0, 255, 12]), title: "Camera settings", kind: .acquireFile)
            let organization = LibraryOrganization(root: source.root)
            try organization.toggleFavorite(original.id)
            let collection = try organization.createCollection(name: "Travel")
            try organization.toggleMembership(recipeID: original.id, collectionID: collection.id)
            try organization.saveKit(name: "Weekend", slots: [RecipeKitSlot(slot: 2, recipe: kitRecipe)])
            try put(Data("Preserve extra notes".utf8), at: source.root.appendingPathComponent("Notes/trip.txt"))
            try FileManager.default.createDirectory(at: source.root.appendingPathComponent("Empty"), withIntermediateDirectories: false)
            let archive = directory.appendingPathComponent("portable.filmback")
            let preview = try VaultArchive.export(store: source, to: archive)
            XCTAssertEqual(preview.recipeCount, 1)
            XCTAssertEqual(preview.backupCount, 1)
            XCTAssertEqual(preview.coverCount, 2)
            XCTAssertEqual(preview.kitCount, 1)
            XCTAssertEqual(preview.collectionCount, 1)
            XCTAssertEqual(preview.archiveDigest, try VaultArchive.preview(at: archive).archiveDigest)

            let destination = VaultStore(root: directory.appendingPathComponent("destination"), coverResources: nil)
            let prior = recipe("Before restore")
            try destination.save(prior)
            let priorOrganization = LibraryOrganization(root: destination.root)
            try priorOrganization.toggleFavorite(prior.id)
            let result = try VaultArchive.restore(from: archive, into: destination, expectedDigest: preview.archiveDigest)
            XCTAssertEqual(destination.recipes, [original])
            XCTAssertEqual(destination.backups.map(\.id), [backup.id])
            XCTAssertEqual(try destination.payload(destination.backups[0]), Data([0, 255, 12]))
            XCTAssertEqual(try Data(contentsOf: destination.coverURL(for: kitRecipe)!), Data([1, 2, 3]))
            XCTAssertEqual(try Data(contentsOf: destination.coverURL(for: original)!), Data([4, 5]))
            XCTAssertEqual(try Data(contentsOf: destination.root.appendingPathComponent("organization.json")),
                           try Data(contentsOf: source.root.appendingPathComponent("organization.json")))
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.root.appendingPathComponent("Empty").path))
            XCTAssertEqual(try Data(contentsOf: destination.root.appendingPathComponent("Notes/trip.txt")), Data("Preserve extra notes".utf8))
            try priorOrganization.reload()
            XCTAssertEqual(priorOrganization.kits.first?.slots.first?.recipe, kitRecipe)
            XCTAssertEqual(priorOrganization.favoriteIDs, [original.id])
            let recovery = VaultStore(root: result.recoveryURL, coverResources: nil)
            XCTAssertEqual(recovery.recipes, [prior])
            XCTAssertEqual(LibraryOrganization(root: result.recoveryURL).favoriteIDs, [prior.id])
        }
    }

    func testEmptyVaultExportsAndRestoresWithValidIndexes() async throws {
        try withFixture { directory in
            let source = VaultStore(root: directory.appendingPathComponent("empty"), coverResources: nil)
            let archive = directory.appendingPathComponent("empty.filmback")
            let preview = try VaultArchive.export(store: source, to: archive)
            XCTAssertEqual(preview.recipeCount, 0)
            XCTAssertEqual(preview.backupCount, 0)
            XCTAssertEqual(preview.fileCount, 2)
            let target = VaultStore(root: directory.appendingPathComponent("target"), coverResources: nil)
            try target.save(recipe())
            try VaultArchive.restore(from: archive, into: target)
            XCTAssertTrue(target.recipes.isEmpty)
            XCTAssertEqual(try JSONDecoder().decode([Recipe].self, from: Data(contentsOf: target.root.appendingPathComponent("library.json"))), [])
        }
    }

    func testCorruptPayloadIsRejectedBeforeAnyMutation() async throws {
        try withFixture { directory in
            let (store, archive) = try archiveWithRecipe(directory)
            let originalBytes = try Data(contentsOf: store.root.appendingPathComponent("library.json"))
            try editArchive(archive) { envelope in envelope.files[0].data.append(0) }
            XCTAssertThrowsError(try VaultArchive.preview(at: archive))
            XCTAssertThrowsError(try VaultArchive.restore(from: archive, into: store))
            XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent("library.json")), originalBytes)
        }
    }

    func testTraversalAbsoluteAndAmbiguousPathsAreRejected() async throws {
        try withFixture { directory in
            let (store, archive) = try archiveWithRecipe(directory)
            let clean = try Data(contentsOf: archive)
            for path in ["../escaped", "/tmp/escaped", "Covers/../../escaped", "Covers\\escaped", "Covers//a", "Covers/./a", "C:/escaped", "bad\u{0}name"] {
                try clean.write(to: archive)
                try editArchive(archive) { $0.files.append(VaultArchive.Entry(path: path, data: Data([1]))) }
                XCTAssertThrowsError(try VaultArchive.restore(from: archive, into: store), path)
            }
            XCTAssertEqual(store.recipes.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("escaped").path))
        }
    }

    func testDuplicateCaseAndParentFileConflictsAreRejected() async throws {
        try withFixture { directory in
            let (_, archive) = try archiveWithRecipe(directory)
            let clean = try Data(contentsOf: archive)
            for path in ["library.json", "LIBRARY.JSON", "library.json/nested", "Backups"] {
                try clean.write(to: archive)
                try editArchive(archive) { $0.files.append(VaultArchive.Entry(path: path, data: Data([1]))) }
                XCTAssertThrowsError(try VaultArchive.preview(at: archive), path)
            }
        }
    }

    func testBadIndexesAndOrganizationAreRejectedEvenWithValidFileChecksums() async throws {
        try withFixture { directory in
            let (_, archive) = try archiveWithRecipe(directory)
            let clean = try Data(contentsOf: archive)
            for path in ["library.json", "backups.json", "organization.json"] {
                try clean.write(to: archive)
                try editArchive(archive) { envelope in
                    envelope.files.removeAll { $0.path == path }
                    envelope.files.append(VaultArchive.Entry(path: path, data: Data("{broken".utf8)))
                }
                XCTAssertThrowsError(try VaultArchive.preview(at: archive), path)
            }
            try clean.write(to: archive)
            try editArchive(archive) { $0.files.append(VaultArchive.Entry(path: "organization.json", data: Data("{\"formatVersion\":999}".utf8))) }
            XCTAssertThrowsError(try VaultArchive.preview(at: archive))
        }
    }

    func testBadBackupPayloadCannotHideBehindValidManifestChecksum() async throws {
        try withFixture { directory in
            let (store, archive) = try archiveWithRecipe(directory)
            let backup = try store.savePayload(Data([1, 2]), title: "Original", kind: .acquireFile)
            try VaultArchive.export(store: store, to: archive)
            try editArchive(archive) { envelope in
                let index = envelope.files.firstIndex { $0.path == "Backups/\(backup.payloadName)" }!
                envelope.files[index] = VaultArchive.Entry(path: envelope.files[index].path, data: Data([3, 4]))
            }
            XCTAssertThrowsError(try VaultArchive.preview(at: archive))
        }
    }

    func testMissingBackupAndMissingLibraryOrKitCoverPreventExport() async throws {
        try withFixture { directory in
            let store = VaultStore(root: directory.appendingPathComponent("source"), coverResources: nil)
            let archive = directory.appendingPathComponent("missing.filmback")
            let covered = recipe(cover: "missing.png")
            try store.save(covered)
            XCTAssertThrowsError(try VaultArchive.export(store: store, to: archive))
            try store.delete(covered)
            let organization = LibraryOrganization(root: store.root)
            let kit = try organization.saveKit(name: "Missing cover", slots: [RecipeKitSlot(slot: 1, recipe: covered)])
            XCTAssertThrowsError(try VaultArchive.export(store: store, to: archive))
            try organization.deleteKit(kit.id)
            let backup = try store.savePayload(Data([1]), title: "Missing payload", kind: .acquireFile)
            try FileManager.default.removeItem(at: store.root.appendingPathComponent("Backups/\(backup.payloadName)"))
            XCTAssertThrowsError(try VaultArchive.export(store: store, to: archive))
            XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        }
    }

    func testMalformedAndExternallyDeletedVaultIndexesCannotExport() async throws {
        try withFixture { directory in
            let (store, archive) = try archiveWithRecipe(directory)
            try FileManager.default.removeItem(at: store.root.appendingPathComponent("library.json"))
            XCTAssertThrowsError(try VaultArchive.export(store: store, to: archive))
            try put(Data("broken".utf8), at: store.root.appendingPathComponent("library.json"))
            XCTAssertThrowsError(try VaultArchive.export(store: store, to: archive))
            let unreadable = VaultStore(root: store.root, coverResources: nil)
            XCTAssertThrowsError(try VaultArchive.export(store: unreadable, to: archive))
        }
    }

    func testSymlinksAreRejectedOnExportAndPreview() async throws {
        try withFixture { directory in
            let (store, archive) = try archiveWithRecipe(directory)
            let outside = directory.appendingPathComponent("outside.txt")
            try put(Data([1, 2]), at: outside)
            try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent("linked.txt"), withDestinationURL: outside)
            XCTAssertThrowsError(try VaultArchive.export(store: store, to: archive))
            let alias = directory.appendingPathComponent("alias.filmback")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: archive)
            XCTAssertThrowsError(try VaultArchive.preview(at: alias))
        }
    }

    func testCommitFailurePreservesVaultAndOrganizationAndRemovesStage() async throws {
        try withFixture { directory in
            let (_, archive) = try archiveWithRecipe(directory)
            let destination = VaultStore(root: directory.appendingPathComponent("target"), coverResources: nil)
            let original = recipe("Unchanged")
            try destination.save(original)
            let organization = LibraryOrganization(root: destination.root)
            try organization.toggleFavorite(original.id)
            let before = try Data(contentsOf: destination.root.appendingPathComponent("organization.json"))
            var operations = VaultArchive.FileOperations()
            operations.swap = { _, _ in throw CocoaError(.fileWriteNoPermission) }
            XCTAssertThrowsError(try VaultArchive.restore(from: archive, into: destination, fileOperations: operations))
            XCTAssertEqual(destination.recipes, [original])
            XCTAssertEqual(VaultStore(root: destination.root).recipes, [original])
            XCTAssertEqual(try Data(contentsOf: destination.root.appendingPathComponent("organization.json")), before)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".Filmback-restore-") })
        }
    }

    func testRecoveryRenameFailureStillRetainsRecoverableOriginal() async throws {
        try withFixture { directory in
            let (source, archive) = try archiveWithRecipe(directory)
            let destination = VaultStore(root: directory.appendingPathComponent("target"), coverResources: nil)
            let original = recipe("Before")
            try destination.save(original)
            var operations = VaultArchive.FileOperations()
            operations.move = { _, _ in throw CocoaError(.fileWriteNoPermission) }
            let result = try VaultArchive.restore(from: archive, into: destination, fileOperations: operations)
            XCTAssertEqual(destination.recipes, source.recipes)
            XCTAssertEqual(VaultStore(root: result.recoveryURL).recipes, [original])
        }
    }

    func testRestoreRecoversUnreadableVaultAndKeepsDamagedOriginal() async throws {
        try withFixture { directory in
            let (source, archive) = try archiveWithRecipe(directory)
            let targetRoot = directory.appendingPathComponent("damaged")
            let malformed = Data("{broken".utf8)
            try put(malformed, at: targetRoot.appendingPathComponent("library.json"))
            try put(malformed, at: targetRoot.appendingPathComponent("backups.json"))
            try put(malformed, at: targetRoot.appendingPathComponent("organization.json"))
            let destination = VaultStore(root: targetRoot, coverResources: nil)
            XCTAssertNotNil(destination.errorMessage)
            let result = try VaultArchive.restore(from: archive, into: destination)
            XCTAssertNil(destination.errorMessage)
            XCTAssertEqual(destination.recipes, source.recipes)
            try destination.save(recipe("Writable again"))
            try destination.savePayload(Data([1]), title: "Writable backups", kind: .acquireFile)
            for filename in ["library.json", "backups.json", "organization.json"] {
                XCTAssertEqual(try Data(contentsOf: result.recoveryURL.appendingPathComponent(filename)), malformed)
            }
        }
    }

    func testPreviewDigestBlocksChangedArchive() async throws {
        try withFixture { directory in
            let (source, archive) = try archiveWithRecipe(directory)
            let preview = try VaultArchive.preview(at: archive)
            try source.save(recipe("Another"))
            try VaultArchive.export(store: source, to: archive)
            let destination = VaultStore(root: directory.appendingPathComponent("target"), coverResources: nil)
            XCTAssertThrowsError(try VaultArchive.restore(from: archive, into: destination, expectedDigest: preview.archiveDigest))
            XCTAssertTrue(destination.recipes.isEmpty)
        }
    }

    func testFutureVersionAndInvalidCountsAreRejected() async throws {
        try withFixture { directory in
            let (_, archive) = try archiveWithRecipe(directory)
            let clean = try Data(contentsOf: archive)
            var envelope = try JSONDecoder().decode(VaultArchive.Envelope.self, from: clean)
            envelope.formatVersion = 2
            try JSONEncoder().encode(envelope).write(to: archive)
            XCTAssertThrowsError(try VaultArchive.preview(at: archive))
            envelope = try JSONDecoder().decode(VaultArchive.Envelope.self, from: clean)
            envelope.fileCount += 1
            try JSONEncoder().encode(envelope).write(to: archive)
            XCTAssertThrowsError(try VaultArchive.preview(at: archive))
            envelope = try JSONDecoder().decode(VaultArchive.Envelope.self, from: clean)
            envelope.totalBytes = VaultArchive.maximumTotalBytes + 1
            try JSONEncoder().encode(envelope).write(to: archive)
            XCTAssertThrowsError(try VaultArchive.preview(at: archive))
        }
    }

    func testExportInsideVaultIsRefused() async throws {
        try withFixture { directory in
            let (store, _) = try archiveWithRecipe(directory)
            XCTAssertThrowsError(try VaultArchive.export(store: store, to: store.root.appendingPathComponent("recursive.filmback")))
        }
    }
}
