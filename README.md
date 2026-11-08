# Filmback

Load Fujifilm film recipes onto your camera from your Mac.

Filmback keeps your recipes in catalogs: sets of four, one for each custom bank. Before a shoot, pick a catalog, review what will change, and load it over USB. It runs entirely on your Mac, with no account and no analytics.

> **Preview software.** Writing to a camera uses a protocol Fujifilm doesn't document. Filmback backs up your banks first and checks every write, but it comes with no warranty. Make a backup with Fujifilm Tether App before your first load. Filmback isn't affiliated with or endorsed by Fujifilm.

## Supported cameras

- **X-M5 (firmware 1.30):** reading, backups and loading catalogs.
- **Other Fujifilm cameras:** Filmback connects and can produce a camera report, but won't read or change banks. [Help add yours.](CONTRIBUTING.md)

On the X-M5, one full catalog load has been checked with a separate read of the camera, and every value matched. These writes haven't been tested on a camera yet: Daylight and Fluorescent 3 white balance; Provia, Classic Negative, Astia and Acros; DR200; Strong or Large grain; and restoring a backup. See [docs/VALIDATION.md](docs/VALIDATION.md).

## Install

1. Download the zip from [Releases](https://github.com/ska2704/Filmback/releases), unzip it and move Filmback to Applications.
2. Open it. macOS will refuse, because the preview isn't notarized by Apple yet.
3. Go to **System Settings → Privacy & Security** and choose **Open Anyway**.

The download is for Apple silicon Macs. It's built to run on macOS 13 or later, but has only been tested on macOS 27.

## Build from source

Use a Mac with Xcode. From the repository root:

```sh
./scripts/build-app.sh
```

This creates `Filmback.app` and `Filmback-macOS.zip` in the parent directory. To run the tests:

```sh
swift test --build-system native
```

The tests use a simulated camera. Personal recipes, vault files, camera backups and compiled apps are not part of this repository.

## What works without a camera

- Create, edit, duplicate and search recipes, mark favourites, and organise named collections. Filter by favourite, collection or film simulation; sort by date, name or simulation.
- Import your own JSON, Open Fuji Recipe v1 JSON, pasted settings, public recipe pages and Simu `SIMU1` codes/links (including kits).
- Read screenshots locally using Apple Vision OCR and QR recognition. Review the recognized values before adding them.
- Keep catalogs: folders of four recipes, one for each bank. Each stores its own recipe copies, so library edits leave it intact. Duplicate, edit, import or export them, compare one with the camera's last read or a saved backup, and load all four banks after one review.
- Compare two recipes side by side, showing all saved values or only differences. Unspecified fields remain explicit.
- Export recipes as JSON, Open Fuji Recipe or a PDF settings sheet, and copy settings as text. Source links, creator attribution and field notes travel with supported exports.
- Inspect an original Fujifilm camera JPEG or RAF locally, review the recognized EXIF/MakerNote settings and save them as a recipe.
- Archive original Fujifilm settings backup files with SHA-256 checksums, and export the complete local vault as one portable `.filmback` file.

The public recipe catalogue is deferred. Import the recipes you already have access to. A public page must expose its settings as readable text; authentication and subscription restrictions are not bypassed. If a page does not import cleanly, paste its settings or use a screenshot. FilmSim Recipes pages can be used through this general import workflow; its proprietary app database and binaries were not decompiled.

## Photo tools

Choose **Photo tools → Inspect original photo** for a file copied directly from your Fujifilm camera or card. Inspection reads the source without modifying or uploading it. Supported values become editable settings; missing values and unrecognized metadata are reported rather than guessed. Recipe names, C1–C4 assignments and Auto ISO limits cannot be recovered reliably. Exposure metadata describes the photograph, not a recommended shooting setup. The current inspector accepts JPEG files up to 80 MiB; RAF and HEIF inspection are unavailable.

**Open X RAW Studio** releases Filmback's camera connection and opens an installed Fujifilm X RAW Studio, or its download page. Exact RAF development uses that application's compatible connected camera workflow. Filmback does not currently render RAW files or transfer a kit into X RAW Studio.

## Camera setup

**Current hardware status:** X-M5 firmware 1.30 connects and returns current setting values, but rejects the camera's supported-values queries (`0x2002`). Filmback then checks each value against a researched `X-M5_0100` profile instead, and refuses any write it could not undo exactly from its own backup. See `docs/VALIDATION.md` for what has been tested on the camera.

1. Charge the X-M5 and use a USB cable that carries data.
2. Set **CONNECTION MODE → USB RAW CONV./BACKUP RESTORE**.
3. Set **USB POWER SUPPLY/COMM SETTING → POWER SUPPLY OFF/COMM ON**.
4. Quit X Acquire, X RAW Studio, tethering apps and other software using the camera.
5. Choose **Camera → Connect**, then **Read C1–C4**.
6. Keep a full settings backup made with Fujifilm Tether App (formerly X Acquire). Add its original file to the Backups tab.
7. Start by applying one recipe to one expendable bank and check it on the camera after disconnecting. For still recipes, check the bank's still/movie assignment. Set the film simulation dial to C to use the bank's simulation.

The X-M5 has **four custom banks**, not seven. Importing a seven-slot Simu kit adds recipes to the library only; you explicitly choose a valid C1–C4 target.

Saving or editing a catalog never changes the camera. **Load to camera…** reads all four banks, shows every change, saves one backup of C1–C4, writes the banks, then reads each one back. You can still send a single bank with **Review C1…** through **Review C4…**. Reviewing switches the bank selector to read each bank, then restores it. Filmback refuses to read or write while Tether App, X RAW Studio or Image Capture is open, and keeps the Mac awake during writes.

## How writes and restores behave

- Banks can only be read or written on models with a verified profile. Today that is the X-M5.
- The camera must advertise the required PTP operations and recipe properties.
- Bank selection is validated and the previous selector is restored after operations.
- Before a write, the app re-reads all banks, rejects stale plans and incomplete reads, and persists a snapshot. If saving fails, no recipe setting is written.
- Writes include only understood fields supplied by the recipe, in dependency order. Missing fields are not replaced by defaults. The camera's writable flag and value constraints are checked.
- The app reads settings back and reports failure rather than claiming success if anything differs.
- Failure midway through a write can leave a partial change. The pre-write backup remains available. There is no automatic speculative rollback.
- Snapshot restore requires matching camera model, serial number and firmware. It restores understood recipe settings and names; unmapped settings remain unchanged. Inactive dependent fields may be omitted.
- No firmware modifications, firmware uploads, undocumented memory writes, C0/live-state writes or photo deletion operations are implemented.

## Backup scopes

**Complete Filmback:** use **Backups → Export complete vault** to preserve recipes, favourites, collections, saved kit snapshots, covers and stored camera backups in one `.filmback` file. The app validates its indexes, references and checksums before export or restore. Restore previews the contents, replaces this Mac's vault only, and keeps the previous vault in a neighbouring recovery folder that opens in Finder. It does not change the camera. The current archive limit is 256 MiB of decoded contents, with a 384 MiB limit for the encoded file. Archives are not encrypted. See `docs/VAULT_ARCHIVE.md` for format, limits and recovery details.

**Recipe-bank snapshots:** JSON captures of readable C1–C4 property bytes plus camera identity. These are created manually or before writes. Restore applies known recipe fields and names after the same checks as a normal write. The UI makes this limited scope explicit.

**Full camera settings:** create and restore these using **Fujifilm Tether App (formerly X Acquire)**. Filmback stores the exact file you choose and its checksum, then exports it unchanged. It does not validate arbitrary user-supplied files as camera backups, convert them into a different format, or claim native whole-camera restore. Settings backups do not contain your photos or firmware. Fujifilm excludes certain settings, including measured custom white balance results, from its backup workflow.

**Save full backup** downloads the camera's settings file, which matched a Tether App backup byte for byte in testing. **View banks** shows the C1–C4 values in a stored backup and compares two backups. Restore a full backup with Tether App; Filmback doesn't write full backups, and restoring one hasn't been tested. After bank switching, the camera's USB stopped responding once when this file was fetched next, so Filmback won't fetch it again until the camera has been unplugged.

## Files and privacy

Your data lives in `~/Library/Application Support/Filmback/`. A vault from RecipeVault, this app's earlier name, moves there the first time Filmback opens:

- `library.json`: recipes and attribution
- `organization.json`: favourites, collections and complete saved kit recipes
- `backups.json`: backup metadata and checksums
- `Backups/`: original backup payloads
- `Covers/`: local cover images; the supplied covers also have an app-bundled fallback

Writes are atomic. If an index cannot be decoded, the app preserves it and blocks overwriting it. The app has no analytics, account, network-based OCR or background uploads. Network requests occur only when you explicitly load a recipe page or open a source/support link. Backups can contain camera model, firmware and serial number; keep them private. Portable backups contain the files in the vault. Photo inspection does not copy source photographs there, and export does not read photos or firmware from the camera.

## Implementation

- `Sources/FujiCore/`: recipe formats, strict import validation, Simu decoding, JPEG metadata inspection, PTP packet parsing and recipe property encodings.
- `Sources/Filmback/`: native UI, camera transport, write planning, library organisation, sharing, portable vault backups and OCR/page input.
- `Tests/FujiCoreTests/`: codec, parser, import, photo metadata and protocol tests.
- `Tests/RecipeCameraTests/`: simulated camera safety, organisation, sharing and persistent-vault/archive tests.
- `docs/VALIDATION.md`: test results and hardware verification boundary.
- `docs/PROTOCOL.md`: research decisions, sources and hardware verification boundary.
- `docs/ADDING_A_CAMERA.md`: how to add support for another model.
- `docs/VAULT_ARCHIVE.md`: portable archive validation, limits and restore behaviour.

This is independent software, not affiliated with Fujifilm, Simu, FilmSim Recipes or recipe publishers. See `THIRD_PARTY_NOTICES.md` for research sources and attribution.

## Interface and supplied recipes

A compact workspace in the X-M5 Silver palette with Library, Catalogs, Compare, Photo tools, Camera, Backups and Guide pages. Native recipe selection, grouped settings and C1–C4 rows share consistent controls and review sheets. Cmd-F searches, Cmd-I imports and Cmd-N creates a recipe. Filters clear after saving or importing so the new recipe remains visible. Design rationale and reusable conventions are recorded in `DESIGN.md`.

Your recipes live in the local vault and aren't included in this repository. A fresh installation starts with an empty library. The four bundled cover assets are included and explicitly labelled AI-styled approximations from one CC0 RAW-developed photograph, not exact camera renders or live previews. Covers are read locally and remain static when a recipe is edited. The separate local collection contains the original RAW, provenance, images and four-recipe JSON.

Portrait Enhancer is a separate saved field with Off/Weak/Medium/Strong options. Its USB mapping is unverified, so it remains manual and generates a write-review warning. Auto ISO and exposure compensation remain shooting notes.

## License

[MIT](LICENSE). Third-party sources and attributions are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
