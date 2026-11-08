import XCTest
@testable import Filmback

@MainActor
final class VaultMigrationTests: XCTestCase {
    private var support: URL!
    private let files = FileManager.default
    override func setUpWithError() throws {
        support = files.temporaryDirectory.appendingPathComponent("FilmbackMigration-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: support, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? files.removeItem(at: support) }
    private func folder(_ name: String, marker: String) throws {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: url.appendingPathComponent("library.json"))
    }
    private func marker(_ root: URL) throws -> String { String(decoding: try Data(contentsOf: root.appendingPathComponent("library.json")), as: UTF8.self) }

    func testOldVaultMovesToNewName() throws {
        try folder("RecipeVault", marker: "old")
        let root = VaultStore.defaultRoot(in: support)
        XCTAssertEqual(root.lastPathComponent, "Filmback")
        XCTAssertEqual(try marker(root), "old")
        XCTAssertFalse(files.fileExists(atPath: support.appendingPathComponent("RecipeVault").path))
    }
    func testExistingNewVaultIsNeverReplaced() throws {
        try folder("RecipeVault", marker: "old")
        try folder("Filmback", marker: "new")
        let root = VaultStore.defaultRoot(in: support)
        XCTAssertEqual(try marker(root), "new")
        XCTAssertEqual(try marker(support.appendingPathComponent("RecipeVault")), "old")
    }
    func testFreshInstallUsesNewName() {
        XCTAssertEqual(VaultStore.defaultRoot(in: support).lastPathComponent, "Filmback")
    }
}
