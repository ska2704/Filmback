# Portable vault backups

Filmback's `.filmback` file (`.filmback` before version 0.7) is a versioned JSON envelope containing the complete local vault. It preserves recipes, camera backup indexes and original payloads, cover images, favorites, collections, saved C1–C4 kit snapshots, extra regular files and empty folders. It does not read or change a connected camera.

Every file has a relative path, decoded byte count, SHA-256 checksum and base64 data. The envelope records its format, version, creation date, file count, total decoded bytes and directories. The preview validates the complete archive, including its recipe library, backup index, organization state, referenced camera backup payloads and referenced covers. A digest of the entire archive binds the restore confirmation to the previewed file.

Exports fail if a library or backup index is unreadable, a referenced backup is missing or damaged, a cover is unavailable, or any vault entry is a symbolic link or another unsupported filesystem object. The export does not silently skip files. Referenced covers supplied by the app bundle are copied into `Covers/` in the archive, including covers used only by a saved kit. Restoring therefore works without the original application's bundled cover files. If neither a local cover nor a bundled fallback exists, recover the image or remove the cover reference before exporting.

Restore checks the complete envelope before staging anything. It rejects absolute paths, traversal, ambiguous or duplicate paths, file/folder collisions, unsupported versions, invalid counts, invalid checksums, malformed indexes and missing referenced data. Current limits are 10,000 files, 10,000 folders, 128 MiB per file, 256 MiB of decoded data and 384 MiB for the encoded archive.

Validated files are written to a new sibling directory and read back for checksum verification. macOS atomically exchanges that directory with the current vault. An unsuccessful exchange leaves the current vault untouched. The previous vault remains in a sibling `Filmback-before-restore-<UUID>` directory; the UI reports its location. If naming that recovery directory fails, the previous vault is retained at the staging directory and the returned recovery location points there. Recovery folders are never automatically removed.

Archive contents are checksummed, not encrypted or authenticated. Store portable backups as carefully as camera settings files and photographs. Only restore a vault whose source you trust.

## Internal integration

- `VaultArchive.export(store:to:)` returns a `VaultArchivePreview`.
- `VaultArchive.preview(at:)` fully validates and returns counts, sizes, creation date and `archiveDigest`.
- `VaultArchive.restore(from:into:expectedDigest:)` stages, atomically replaces and refreshes the existing `VaultStore`, returning the preview and `recoveryURL`.
- Call `LibraryOrganization.reload()` after restoring so the UI refreshes favorites, collections and kits.
