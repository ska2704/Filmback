import Foundation
import Darwin
import FujiCore

struct VaultArchivePreview {
    let createdAt: Date
    let recipeCount: Int
    let backupCount: Int
    let coverCount: Int
    let collectionCount: Int
    let kitCount: Int
    let fileCount: Int
    let totalBytes: Int
    var archiveDigest: String = ""
}

struct VaultRestoreResult {
    let preview: VaultArchivePreview
    let recoveryURL: URL
}

@MainActor
enum VaultArchive {
    static let fileExtension = "filmback"
    static let maximumFiles = 10_000
    static let maximumFileBytes = 128 * 1_024 * 1_024
    static let maximumTotalBytes = 256 * 1_024 * 1_024
    static let maximumEncodedBytes = 384 * 1_024 * 1_024

    struct Entry: Codable {
        var path: String
        var byteCount: Int
        var sha256: String
        var data: Data

        init(path: String, data: Data) {
            self.path = path
            byteCount = data.count
            sha256 = VaultStore.digest(data)
            self.data = data
        }
    }

    struct Envelope: Codable {
        var format = "recipevault.archive"
        var formatVersion = 1
        var createdAt: Date
        var fileCount: Int
        var totalBytes: Int
        var directories: [String]
        var files: [Entry]
    }

    private struct Validated {
        let envelope: Envelope
        let recipes: [Recipe]
        let backups: [BackupRecord]
        let preview: VaultArchivePreview
    }

    // The swap is injectable to exercise commit failures without touching a real vault.
    struct FileOperations {
        var swap: (URL, URL) throws -> Void = { first, second in
            let result = first.withUnsafeFileSystemRepresentation { firstPath in
                second.withUnsafeFileSystemRepresentation { secondPath in
                    renameatx_np(AT_FDCWD, firstPath!, AT_FDCWD, secondPath!, UInt32(RENAME_SWAP))
                }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        var move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    }

    static func preview(at url: URL) throws -> VaultArchivePreview {
        try read(url).preview
    }

    @discardableResult
    static func export(store: VaultStore, to destination: URL) throws -> VaultArchivePreview {
        try store.ensureReadableForArchive()
        let root = try checkedRoot(store.root)
        let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard destinationPath != root.path, !destinationPath.hasPrefix(root.path + "/") else {
            throw VaultError.message("Save the portable backup outside the vault folder.")
        }
        let fm = FileManager.default
        var files: [Entry] = []
        var directories: [String] = []
        var total = 0
        func collect(_ directory: URL, prefix: String) throws {
            for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]) {
                let path = prefix + child.lastPathComponent
                try validatePath(path)
                let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw VaultError.message("The vault contains a symbolic link: \(path). Portable backups only include regular files.") }
                if values.isDirectory == true {
                    directories.append(path)
                    guard directories.count <= maximumFiles else { throw VaultError.message("The vault contains too many folders.") }
                    try collect(child, prefix: path + "/")
                } else if values.isRegularFile == true {
                    let data = try checkedData(at: child, maximumBytes: maximumFileBytes)
                    total += data.count
                    guard total <= maximumTotalBytes, files.count < maximumFiles else { throw sizeError() }
                    files.append(Entry(path: path, data: data))
                } else {
                    throw VaultError.message("Unsupported vault item: \(path). No files were omitted.")
                }
            }
        }
        try collect(root, prefix: "")
        let encoder = JSONEncoder()
        if !files.contains(where: { $0.path == "library.json" }) {
            guard store.recipes.isEmpty else { throw VaultError.message("library.json is missing. The portable backup was not created.") }
            files.append(Entry(path: "library.json", data: try encoder.encode([Recipe]())))
        }
        if !files.contains(where: { $0.path == "backups.json" }) {
            guard store.backups.isEmpty else { throw VaultError.message("backups.json is missing. The portable backup was not created.") }
            files.append(Entry(path: "backups.json", data: try encoder.encode([BackupRecord]())))
        }
        let recipes = try JSONDecoder().decode([Recipe].self, from: requiredFile("library.json", in: files))
        let organization = try files.first(where: { $0.path == "organization.json" }).map { try LibraryOrganizationState.decode($0.data) }
        let allRecipes = recipes + (organization?.kits.flatMap(\.slots).map(\.recipe) ?? [])
        for recipe in allRecipes {
            guard let cover = recipe.cover else { continue }
            let path = "Covers/\(cover.filename)"
            if files.contains(where: { $0.path == path }) { continue }
            guard let source = store.coverURL(for: recipe) else {
                throw VaultError.message("The cover for ‘\(recipe.name)’ is missing: \(cover.filename). Recover it before exporting.")
            }
            // Bundled fallback covers become ordinary local cover files in the archive.
            files.append(Entry(path: path, data: try checkedData(at: source, maximumBytes: maximumFileBytes)))
            if !directories.contains("Covers") { directories.append("Covers") }
        }
        if !directories.contains("Backups") { directories.append("Backups") }
        let envelope = Envelope(createdAt: Date(), fileCount: files.count,
                                totalBytes: files.reduce(0) { $0 + $1.data.count },
                                directories: directories.sorted(), files: files.sorted { $0.path < $1.path })
        let validated = try validate(envelope)
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= maximumEncodedBytes else { throw sizeError() }
        if fm.fileExists(atPath: destination.path) {
            _ = try checkedData(at: destination, maximumBytes: maximumEncodedBytes)
        }
        try data.write(to: destination, options: .atomic)
        var preview = validated.preview
        preview.archiveDigest = VaultStore.digest(data)
        return preview
    }

    @discardableResult
    static func restore(from archiveURL: URL, into store: VaultStore, expectedDigest: String? = nil,
                        fileOperations: FileOperations = FileOperations()) throws -> VaultRestoreResult {
        let validated = try read(archiveURL)
        if let expectedDigest, expectedDigest != validated.preview.archiveDigest {
            throw VaultError.message("This portable backup changed after its preview was shown. Open it again to review the current contents before restoring.")
        }
        let root = try checkedRoot(store.root)
        let parent = root.deletingLastPathComponent()
        let token = UUID().uuidString
        let stage = parent.appendingPathComponent(".Filmback-restore-\(token)", isDirectory: true)
        let recovery = parent.appendingPathComponent("Filmback-before-restore-\(token)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: stage) } }
        for path in validated.envelope.directories {
            try fm.createDirectory(at: stage.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for file in validated.envelope.files {
            let target = stage.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Exclusive creation also catches aliases specific to the destination filesystem.
            try file.data.write(to: target, options: .withoutOverwriting)
        }
        for file in validated.envelope.files {
            let target = stage.appendingPathComponent(file.path)
            let actual = try checkedData(at: target, maximumBytes: maximumFileBytes)
            guard actual.count == file.byteCount, VaultStore.digest(actual) == file.sha256 else {
                throw VaultError.message("A staged file failed verification. Your current vault was not changed.")
            }
        }
        // Both directories are siblings on the same volume. RENAME_SWAP either swaps
        // the whole vault atomically or leaves both directories untouched.
        _ = try checkedRoot(root)
        try fileOperations.swap(root, stage)
        committed = true
        var recoveryURL = recovery
        do { try fileOperations.move(stage, recovery) }
        catch { recoveryURL = stage }
        store.applyRestoredContents(recipes: validated.recipes, backups: validated.backups)
        return VaultRestoreResult(preview: validated.preview, recoveryURL: recoveryURL)
    }

    private static func read(_ url: URL) throws -> Validated {
        let data = try checkedData(at: url, maximumBytes: maximumEncodedBytes)
        do { return try validate(JSONDecoder().decode(Envelope.self, from: data), archiveDigest: VaultStore.digest(data)) }
        catch let error as VaultError { throw error }
        catch { throw VaultError.message("The portable backup could not be read: \(error.localizedDescription)") }
    }

    private static func validate(_ envelope: Envelope, archiveDigest: String = "") throws -> Validated {
        guard envelope.format == "recipevault.archive", envelope.formatVersion == 1 else {
            throw VaultError.message("Unsupported portable backup format or version.")
        }
        guard envelope.createdAt.timeIntervalSinceReferenceDate.isFinite,
              envelope.fileCount == envelope.files.count,
              envelope.fileCount >= 2, envelope.fileCount <= maximumFiles,
              envelope.directories.count <= maximumFiles,
              envelope.totalBytes >= 0, envelope.totalBytes <= maximumTotalBytes else { throw sizeError() }
        var knownFiles = Set<String>()
        var knownDirectories = Set<String>()
        for directory in envelope.directories {
            try validatePath(directory)
            guard knownDirectories.insert(pathKey(directory)).inserted else { throw pathConflict() }
        }
        var total = 0
        for file in envelope.files {
            try validatePath(file.path)
            let key = pathKey(file.path)
            guard knownFiles.insert(key).inserted, !knownDirectories.contains(key) else { throw pathConflict() }
            guard file.byteCount >= 0, file.byteCount <= maximumFileBytes,
                  file.byteCount == file.data.count else { throw sizeError() }
            total += file.byteCount
            guard total <= maximumTotalBytes else { throw sizeError() }
            guard file.sha256 == VaultStore.digest(file.data) else {
                throw VaultError.message("Checksum verification failed for \(file.path). Your current vault was not changed.")
            }
        }
        guard total == envelope.totalBytes else { throw VaultError.message("The portable backup's total size does not match its manifest.") }
        for path in envelope.directories + envelope.files.map(\.path) {
            var parts = path.split(separator: "/").map(String.init)
            while parts.count > 1 {
                parts.removeLast()
                guard !knownFiles.contains(pathKey(parts.joined(separator: "/"))) else { throw pathConflict() }
            }
        }
        let recipes = try JSONDecoder().decode([Recipe].self, from: requiredFile("library.json", in: envelope.files))
        let backups = try JSONDecoder().decode([BackupRecord].self, from: requiredFile("backups.json", in: envelope.files))
        guard recipes.count <= maximumFiles, backups.count <= maximumFiles,
              Set(recipes.map(\.id)).count == recipes.count, Set(backups.map(\.id)).count == backups.count else {
            throw VaultError.message("The portable backup contains duplicate recipe or backup identities.")
        }
        var payloadNames = Set<String>()
        for backup in backups {
            try validatePath(backup.payloadName)
            guard !backup.payloadName.contains("/"), payloadNames.insert(pathKey(backup.payloadName)).inserted else { throw pathConflict() }
            let payload = try requiredFile("Backups/\(backup.payloadName)", in: envelope.files)
            guard backup.byteCount > 0, backup.byteCount == payload.count,
                  backup.checksum == VaultStore.digest(payload) else {
                throw VaultError.message("Camera backup ‘\(backup.title)’ is missing or damaged. Your current vault was not changed.")
            }
            if backup.kind == .recipeSlots {
                let slots = try JSONDecoder().decode(SlotArchive.self, from: payload)
                guard slots.formatVersion == 1 else { throw VaultError.message("Unsupported camera slot backup version.") }
            }
        }
        let organization = try envelope.files.first(where: { $0.path == "organization.json" }).map { try LibraryOrganizationState.decode($0.data) }
        let allRecipes = recipes + (organization?.kits.flatMap(\.slots).map(\.recipe) ?? [])
        for recipe in allRecipes {
            guard let cover = recipe.cover else { continue }
            try cover.validate()
            guard !(try requiredFile("Covers/\(cover.filename)", in: envelope.files)).isEmpty else {
                throw VaultError.message("The cover for ‘\(recipe.name)’ is empty.")
            }
        }
        let preview = VaultArchivePreview(createdAt: envelope.createdAt, recipeCount: recipes.count,
                                          backupCount: backups.count,
                                          coverCount: envelope.files.filter { $0.path.hasPrefix("Covers/") }.count,
                                          collectionCount: organization?.collections.count ?? 0,
                                          kitCount: organization?.kits.count ?? 0,
                                          fileCount: envelope.fileCount, totalBytes: total, archiveDigest: archiveDigest)
        return Validated(envelope: envelope, recipes: recipes, backups: backups, preview: preview)
    }

    private static func requiredFile(_ path: String, in files: [Entry]) throws -> Data {
        guard let file = files.first(where: { $0.path == path }) else {
            throw VaultError.message("The portable backup is incomplete: \(path) is missing.")
        }
        return file.data
    }

    private static func validatePath(_ path: String) throws {
        let parts = path.components(separatedBy: "/")
        guard !path.isEmpty, path.utf8.count <= 1_024, parts.count <= 16,
              !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw VaultError.message("The portable backup contains an unsafe file path.")
        }
    }

    private static func pathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func checkedRoot(_ url: URL) throws -> URL {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw VaultError.message("The vault folder is missing or is a symbolic link.")
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func checkedData(at url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw VaultError.message("Only regular files can be included in a portable backup: \(url.lastPathComponent).")
        }
        guard let size = values.fileSize, size >= 0, size <= maximumBytes else { throw sizeError() }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw sizeError() }
        return data
    }

    private static func pathConflict() -> VaultError {
        .message("The portable backup contains duplicate or conflicting file paths.")
    }

    private static func sizeError() -> VaultError {
        .message("The portable backup has an invalid size or count. Limits are 10,000 files, 128 MB per file and 256 MB of vault data.")
    }
}
