import Foundation
import Combine
import CryptoKit
import FujiCore

struct BackupRecord: Codable, Identifiable {
    enum Kind: String, Codable { case recipeSlots, acquireFile, cameraBlob }
    var id: UUID
    var createdAt: Date
    var title: String
    var kind: Kind
    var cameraModel: String
    var firmware: String
    var serial: String
    var payloadName: String
    var checksum: String
    var byteCount: Int
}

struct SlotArchive: Codable {
    var formatVersion = 1
    var camera: PTPDeviceInfo
    var slots: [CameraSlotSnapshot]
}

@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var recipes: [Recipe] = []
    @Published private(set) var backups: [BackupRecord] = []
    @Published var errorMessage: String?
    let root: URL
    private let coverResources: URL?
    private var libraryReadable = true
    private var backupsReadable = true
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    init(root: URL? = nil, coverResources: URL? = Bundle.main.resourceURL) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecipeVault", isDirectory: true)
        self.coverResources = coverResources
        do {
            try FileManager.default.createDirectory(at: self.root.appendingPathComponent("Backups"), withIntermediateDirectories: true)
        } catch { errorMessage = error.localizedDescription }
        do { recipes = try load([Recipe].self, from: "library.json") ?? [] }
        catch { libraryReadable = false; errorMessage = "The recipe library could not be opened. Your existing file has been preserved. \(error.localizedDescription)" }
        do { backups = try load([BackupRecord].self, from: "backups.json") ?? [] }
        catch { backupsReadable = false; errorMessage = "The backup index could not be opened. Existing backups have been preserved. \(error.localizedDescription)" }
    }

    func save(_ recipe: Recipe) throws {
        var next = recipes
        if let index = next.firstIndex(where: { $0.id == recipe.id }) { next[index] = recipe }
        else { next.insert(recipe, at: 0) }
        try saveLibrary(next)
    }

    func add(_ imported: [Recipe]) throws {
        var next = recipes
        for var recipe in imported {
            recipe.id = UUID()
            next.insert(recipe, at: 0)
        }
        try saveLibrary(next)
    }

    func delete(_ recipe: Recipe) throws { try saveLibrary(recipes.filter { $0.id != recipe.id }) }

    func coverURL(for recipe: Recipe) -> URL? {
        guard let cover = recipe.cover, cover.hasSafeFilename else { return nil }
        for directory in [root, coverResources].compactMap({ $0 }) {
            let covers = directory.resolvingSymlinksInPath().standardizedFileURL
                .appendingPathComponent("Covers", isDirectory: true)
            guard covers.resolvingSymlinksInPath().standardizedFileURL == covers else { continue }
            let candidate = covers.appendingPathComponent(cover.filename)
                .resolvingSymlinksInPath().standardizedFileURL
            guard candidate.deletingLastPathComponent() == covers,
                  let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            return candidate
        }
        return nil
    }

    private func saveLibrary(_ next: [Recipe]) throws {
        guard libraryReadable else { throw VaultError.message("Repair or recover library.json before saving new recipes. The original file is preserved in the vault folder.") }
        for recipe in next { try recipe.cover?.validate() }
        try encoder.encode(next).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        recipes = next
    }

    @discardableResult
    func saveSlots(_ slots: [CameraSlotSnapshot], camera: PTPDeviceInfo, title: String) throws -> BackupRecord {
        let data = try encoder.encode(SlotArchive(camera: camera, slots: slots))
        let record = try savePayload(data, title: title, kind: .recipeSlots, camera: camera, ext: "json")
        try verifySlotBackup(record, slots: slots, camera: camera)
        return record
    }

    func verifySlotBackup(_ record: BackupRecord, slots: [CameraSlotSnapshot], camera: PTPDeviceInfo) throws {
        let saved = try archive(record)
        guard saved.camera == camera, saved.slots == slots else {
            throw VaultError.message("The saved recipe-bank backup does not match the camera snapshot. Camera writing is blocked.")
        }
    }

    @discardableResult
    func savePayload(_ data: Data, title: String, kind: BackupRecord.Kind, camera: PTPDeviceInfo? = nil, ext: String = "dat") throws -> BackupRecord {
        guard backupsReadable else { throw VaultError.message("The backup index must be recovered before adding backups.") }
        guard !data.isEmpty else { throw VaultError.message("An empty file is not a backup.") }
        let id = UUID()
        let safeExt = ext.filter { $0.isLetter || $0.isNumber }.prefix(12)
        let name = "\(id.uuidString).\(safeExt.isEmpty ? "dat" : String(safeExt))"
        let record = BackupRecord(id: id, createdAt: Date(), title: title, kind: kind,
                                  cameraModel: camera?.model ?? "X-M5 (user supplied)", firmware: camera?.deviceVersion ?? "Unknown",
                                  serial: camera?.serialNumber ?? "Unknown", payloadName: name,
                                  checksum: Self.digest(data), byteCount: data.count)
        let destination = root.appendingPathComponent("Backups").appendingPathComponent(name)
        try data.write(to: destination, options: .atomic)
        let next = [record] + backups
        do { try encoder.encode(next).write(to: root.appendingPathComponent("backups.json"), options: .atomic) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        backups = next
        return record
    }

    func payload(_ backup: BackupRecord) throws -> Data {
        guard backup.payloadName == URL(fileURLWithPath: backup.payloadName).lastPathComponent else {
            throw VaultError.message("Invalid backup path.")
        }
        let data = try Data(contentsOf: root.appendingPathComponent("Backups").appendingPathComponent(backup.payloadName))
        guard Self.digest(data) == backup.checksum else { throw VaultError.message("This backup's checksum does not match. Restore is blocked because the file changed or is damaged.") }
        return data
    }

    func archive(_ backup: BackupRecord) throws -> SlotArchive {
        guard backup.kind == .recipeSlots else { throw VaultError.message("This file must be restored using Fujifilm X Acquire.") }
        let archive = try JSONDecoder().decode(SlotArchive.self, from: payload(backup))
        guard archive.formatVersion == 1 else { throw VaultError.message("Unsupported backup version.") }
        return archive
    }

    /// C1–C4 from a stored backup, or nil when the file isn't a format RecipeVault can read.
    func banks(in backup: BackupRecord) -> [CameraSlotSnapshot]? {
        if backup.kind == .recipeSlots { return (try? archive(backup))?.slots }
        guard let data = try? payload(backup) else { return nil }
        return try? XM5BackupDecoder.decode(data)
    }

    private func load<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    func ensureReadableForArchive() throws {
        guard libraryReadable, backupsReadable else {
            throw VaultError.message("The vault contains an unreadable library or backup index. Recover those files before exporting a portable backup.")
        }
    }

    func applyRestoredContents(recipes: [Recipe], backups: [BackupRecord]) {
        self.recipes = recipes
        self.backups = backups
        libraryReadable = true
        backupsReadable = true
        errorMessage = nil
    }

    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

enum VaultError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
