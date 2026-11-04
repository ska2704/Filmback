import XCTest
import FujiCore
@testable import RecipeVault

@MainActor
final class VaultStoreTests: XCTestCase {
    private func withTemporaryVault(_ body: (URL, VaultStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecipeVaultTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, VaultStore(root: root))
    }

    private var recipe: Recipe {
        Recipe(name: "Personal Chrome", sourceURL: "https://example.org/recipe", author: "Camera owner",
               notes: "Outdoor test", settings: [.filmSimulation: "Classic Chrome", .highlight: "-1"],
               createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testCoverResolvesLocallyAndSurvivesDuplicateDeletion() async throws {
        try withTemporaryVault { root, store in
            let covers = root.appendingPathComponent("Covers", isDirectory: true)
            try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
            let image = covers.appendingPathComponent("test.jpg")
            try Data([1, 2, 3]).write(to: image)
            var original = recipe
            original.cover = RecipeCover(filename: "test.jpg", credit: "Owner", renderingNote: "Approximation")
            try store.save(original)
            try store.add([original])
            XCTAssertEqual(store.coverURL(for: original), image.resolvingSymlinksInPath())
            XCTAssertEqual(VaultStore(root: root).recipes.map(\.cover), [original.cover, original.cover])
            try store.delete(original)
            XCTAssertEqual(store.recipes.count, 1)
            XCTAssertEqual(store.coverURL(for: store.recipes[0]), image.resolvingSymlinksInPath())
            XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        }
    }

    func testCoverUsesBundledFallbackAndPrefersLocalFile() async throws {
        try withTemporaryVault { root, _ in
            let resources = root.appendingPathComponent("FixtureResources", isDirectory: true)
            let bundledCovers = resources.appendingPathComponent("Covers", isDirectory: true)
            try FileManager.default.createDirectory(at: bundledCovers, withIntermediateDirectories: true)
            let bundled = bundledCovers.appendingPathComponent("test.png")
            try Data([1]).write(to: bundled)
            let store = VaultStore(root: root, coverResources: resources)
            var original = recipe
            original.cover = RecipeCover(filename: "test.png", credit: "Owner", renderingNote: "Approximation")
            XCTAssertEqual(store.coverURL(for: original), bundled.resolvingSymlinksInPath())
            let localCovers = root.appendingPathComponent("Covers", isDirectory: true)
            try FileManager.default.createDirectory(at: localCovers, withIntermediateDirectories: true)
            let local = localCovers.appendingPathComponent("test.png")
            try Data([2]).write(to: local)
            XCTAssertEqual(store.coverURL(for: original), local.resolvingSymlinksInPath())
        }
    }

    func testCoverRefusesMissingFilesDirectoriesAndEscapingSymlinks() async throws {
        try withTemporaryVault { root, _ in
            let store = VaultStore(root: root, coverResources: nil)
            let covers = root.appendingPathComponent("Covers", isDirectory: true)
            try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
            var original = recipe
            original.cover = RecipeCover(filename: "test.jpg", credit: "Owner", renderingNote: "Approximation")
            XCTAssertNil(store.coverURL(for: original))
            let directory = covers.appendingPathComponent("test.jpg", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            XCTAssertNil(store.coverURL(for: original))
            try FileManager.default.removeItem(at: directory)
            let outside = root.appendingPathComponent("outside.jpg")
            try Data([1]).write(to: outside)
            try FileManager.default.createSymbolicLink(at: covers.appendingPathComponent("test.jpg"), withDestinationURL: outside)
            XCTAssertNil(store.coverURL(for: original))
            original.cover?.filename = "../outside.jpg"
            XCTAssertNil(store.coverURL(for: original))
            XCTAssertThrowsError(try store.save(original))
        }
    }

    func testCoverDirectorySymlinkCannotEscapeVault() async throws {
        try withTemporaryVault { root, _ in
            let resources = root.appendingPathComponent("OtherFolder", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try Data([1]).write(to: resources.appendingPathComponent("test.jpg"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Covers"), withDestinationURL: resources)
            let store = VaultStore(root: root, coverResources: nil)
            var original = recipe
            original.cover = RecipeCover(filename: "test.jpg", credit: "Owner", renderingNote: "Approximation")
            XCTAssertNil(store.coverURL(for: original))
        }
    }

    func testLibraryPersistsEditsAndDeletesWithStableIdentity() async throws {
        try withTemporaryVault { root, store in
            var original = recipe
            try store.save(original)
            XCTAssertEqual(VaultStore(root: root).recipes, [original])

            original.name = "Updated name"
            original.settings[.highlight] = "-0.5"
            try store.save(original)
            let reopened = VaultStore(root: root)
            XCTAssertEqual(reopened.recipes, [original])

            try reopened.delete(original)
            XCTAssertTrue(VaultStore(root: root).recipes.isEmpty)
        }
    }

    func testImportCopiesCannotReplaceAnExistingRecipe() async throws {
        try withTemporaryVault { root, store in
            let original = recipe
            try store.save(original)
            try store.add([original, original])
            let reopened = VaultStore(root: root)
            XCTAssertEqual(reopened.recipes.count, 3)
            XCTAssertEqual(Set(reopened.recipes.map(\.id)).count, 3)
            XCTAssertEqual(reopened.recipes.filter { $0.id == original.id }, [original])
            for imported in reopened.recipes {
                XCTAssertEqual(imported.settings, original.settings)
                XCTAssertEqual(imported.sourceURL, original.sourceURL)
                XCTAssertEqual(imported.author, original.author)
            }
        }
    }

    func testBackupPreservesOriginalBytesAndReloadsIndex() async throws {
        try withTemporaryVault { root, store in
            let bytes = Data([0, 1, 2, 3, 255])
            let record = try store.savePayload(bytes, title: "Camera settings", kind: .acquireFile, ext: "dat")
            let reopened = VaultStore(root: root)
            XCTAssertEqual(reopened.backups.map(\.id), [record.id])
            XCTAssertEqual(reopened.backups.first?.checksum, VaultStore.digest(bytes))
            XCTAssertEqual(reopened.backups.first?.byteCount, bytes.count)
            XCTAssertEqual(reopened.backups.first?.kind, .acquireFile)
            XCTAssertEqual(try reopened.payload(record), bytes)
        }
    }

    func testDamagedBackupCannotBeExportedOrRestored() async throws {
        try withTemporaryVault { root, store in
            let record = try store.savePayload(Data([1, 2, 3]), title: "Original", kind: .recipeSlots)
            let payloadURL = root.appendingPathComponent("Backups").appendingPathComponent(record.payloadName)
            try Data([8, 9]).write(to: payloadURL)

            XCTAssertThrowsError(try store.payload(record)) { error in
                XCTAssertTrue(error.localizedDescription.contains("checksum"))
            }
            XCTAssertThrowsError(try store.archive(record))
            XCTAssertEqual(store.backups.map(\.id), [record.id])
            XCTAssertEqual(try Data(contentsOf: payloadURL), Data([8, 9]))
        }
    }

    func testMalformedLibraryIsPreservedAndBlocksAllMutations() async throws {
        try withTemporaryVault { root, store in
            let original = recipe
            try store.save(original)
            let libraryURL = root.appendingPathComponent("library.json")
            let malformed = Data("{broken".utf8)
            try malformed.write(to: libraryURL)

            let damaged = VaultStore(root: root)
            XCTAssertNotNil(damaged.errorMessage)
            XCTAssertThrowsError(try damaged.save(original))
            XCTAssertThrowsError(try damaged.add([original]))
            XCTAssertThrowsError(try damaged.delete(original))
            XCTAssertEqual(try Data(contentsOf: libraryURL), malformed)
        }
    }

    func testMalformedBackupIndexBlocksWritesAndPreservesPayloads() async throws {
        try withTemporaryVault { root, store in
            let record = try store.savePayload(Data([1, 2]), title: "Existing", kind: .acquireFile)
            let indexURL = root.appendingPathComponent("backups.json")
            let malformed = Data("[broken".utf8)
            try malformed.write(to: indexURL)

            let damaged = VaultStore(root: root)
            XCTAssertNotNil(damaged.errorMessage)
            XCTAssertThrowsError(try damaged.savePayload(Data([3, 4]), title: "Blocked", kind: .acquireFile))
            XCTAssertEqual(try Data(contentsOf: indexURL), malformed)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Backups").path),
                           [record.payloadName])
            XCTAssertEqual(try store.payload(record), Data([1, 2]))
        }
    }

    func testFailedIndexWriteRollsBackNewPayload() async throws {
        try withTemporaryVault { root, store in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("backups.json"),
                                                    withIntermediateDirectories: false)
            XCTAssertThrowsError(try store.savePayload(Data([1, 2]), title: "Rollback", kind: .acquireFile))
            XCTAssertTrue(store.backups.isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Backups").path).isEmpty)
        }
    }

    func testFailedLibraryWriteDoesNotCommitInMemory() async throws {
        try withTemporaryVault { root, store in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("library.json"),
                                                    withIntermediateDirectories: false)
            XCTAssertThrowsError(try store.save(recipe))
            XCTAssertTrue(store.recipes.isEmpty)
        }
    }

    func testUnsafePayloadPathsAndEmptyBackupsAreRefused() async throws {
        try withTemporaryVault { _, store in
            XCTAssertThrowsError(try store.savePayload(Data(), title: "Empty", kind: .acquireFile))
            XCTAssertTrue(store.backups.isEmpty)
            var record = try store.savePayload(Data([1]), title: "Original", kind: .acquireFile)
            record.payloadName = "../library.json"
            XCTAssertThrowsError(try store.payload(record)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Invalid backup path"))
            }
        }
    }

    func testSlotArchiveRoundTripRetainsReadErrorsAndRejectsFutureVersion() async throws {
        try withTemporaryVault { _, store in
            let camera = PTPDeviceInfo(manufacturer: "FUJIFILM", model: "X-M5", deviceVersion: "1.00",
                                       serialNumber: "FIXTURE", operations: [0x1015], properties: [0xD192])
            let snapshot = CameraSlotSnapshot(slot: 1, name: "C1", properties: [0xD192: PTP.u16(11)],
                                              readErrors: ["0xD1A2": "Unavailable"])
            let record = try store.saveSlots([snapshot], camera: camera, title: "Recipe banks")
            let archive = try store.archive(record)
            XCTAssertEqual(archive.camera, camera)
            XCTAssertEqual(archive.slots, [snapshot])

            var future = archive
            future.formatVersion = 2
            let futureRecord = try store.savePayload(JSONEncoder().encode(future), title: "Future format", kind: .recipeSlots)
            XCTAssertThrowsError(try store.archive(futureRecord)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Unsupported backup version"))
            }
        }
    }

    func testVerifiedSlotBackupPreservesEveryBankAndUnknownRawValues() async throws {
        try withTemporaryVault { root, store in
            let camera = PTPDeviceInfo(manufacturer: "FUJIFILM", model: "X-M5", deviceVersion: "1.30",
                                       serialNumber: "FIXTURE", operations: [0x1015], properties: [0xD192, 0xD195])
            let slots = (1...4).map {
                CameraSlotSnapshot(slot: $0, name: "Original \($0)",
                                   properties: [0xD192: PTP.u16(0x8000), 0xD195: PTP.u16(6)])
            }
            let record = try store.saveSlots(slots, camera: camera, title: "Before changing camera")
            let reopened = VaultStore(root: root)
            try reopened.verifySlotBackup(record, slots: slots, camera: camera)
            XCTAssertEqual(try reopened.archive(record).slots, slots)
            XCTAssertEqual(reopened.backups.first?.id, record.id)
        }
    }

    func testSlotBackupVerificationRejectsDamagedBytesAndDifferentSnapshot() async throws {
        try withTemporaryVault { root, store in
            let camera = PTPDeviceInfo(manufacturer: "FUJIFILM", model: "X-M5", deviceVersion: "1.30",
                                       serialNumber: "FIXTURE", operations: [0x1015], properties: [0xD192])
            let slots = [CameraSlotSnapshot(slot: 1, name: "Original", properties: [0xD192: PTP.u16(11)])]
            let record = try store.saveSlots(slots, camera: camera, title: "Original bank")
            let changedSlots = [CameraSlotSnapshot(slot: 1, name: "Original", properties: [0xD192: PTP.u16(20)])]
            XCTAssertThrowsError(try store.verifySlotBackup(record, slots: changedSlots, camera: camera)) { error in
                XCTAssertTrue(error.localizedDescription.contains("does not match"))
            }
            let otherCamera = PTPDeviceInfo(manufacturer: "FUJIFILM", model: "X-M5", deviceVersion: "1.30",
                                            serialNumber: "OTHER", operations: [0x1015], properties: [0xD192])
            XCTAssertThrowsError(try store.verifySlotBackup(record, slots: slots, camera: otherCamera))

            let payloadURL = root.appendingPathComponent("Backups").appendingPathComponent(record.payloadName)
            try Data("damaged".utf8).write(to: payloadURL)
            XCTAssertThrowsError(try store.verifySlotBackup(record, slots: slots, camera: camera)) { error in
                XCTAssertTrue(error.localizedDescription.contains("checksum"))
            }
        }
    }
}
