# RecipeVault for Mac

A native, local photography toolkit for Arin's Fujifilm X-M5. Version 0.4 adds library organisation, saved camera kits, recipe comparison, JPEG inspection and portable vault backups. Built with SwiftUI, ImageCaptureCore and Vision, with no package dependencies, account, subscription or cloud service.

**Status: hardware preview, not yet tested on an actual X-M5.** The included app runs on Apple silicon Macs with macOS 13 or later. Source can be built for an Intel Mac on that machine. Camera writing is implemented, but successful hardware compatibility is not claimed until the first read/write/restore check on the actual body.

## Build from this repository

Use a Mac with Xcode and its Swift toolchain installed. From the repository root:

```sh
./scripts/build-app.sh
```

The script creates `RecipeVault.app` and `RecipeVault-macOS.zip` in the parent directory. Unzip the archive, move the app to Applications, and open it. The app is locally ad-hoc signed, not Apple notarized. It discovers attached Fujifilm devices and waits for you to connect explicitly; it does not change recipes automatically. Packaging runs in a temporary folder so cloud-synced Documents metadata cannot invalidate the archived signature.

To run the automated checks:

```sh
swift test --build-system native
```

GitHub Actions runs the automated suite and builds the release executable on macOS. These checks use simulated camera transport and cannot establish physical X-M5 compatibility. USB validation comes before a public camera-control release; a Windows version is not available yet.

This repository contains source, tests, documentation and attributed cover assets. Personal recipes, vault files, camera backups, local UI test captures and compiled apps are excluded.

## What works without a camera

- Create, edit, duplicate and search recipes, mark favourites, and organise named collections. Filter by favourite, collection or film simulation; sort by date, name or simulation.
- Import your own JSON, Open Fuji Recipe v1 JSON, pasted settings, public recipe pages and Simu `SIMU1` codes/links (including kits).
- Read screenshots locally using Apple Vision OCR and QR recognition. Review the recognized values before adding them.
- Save named C1–C4 kits with one to four assigned banks. Each kit stores complete recipe copies, so editing or deleting a library recipe leaves the kit intact. Inspect or replace saved entries, add copies back to the library, or export the kit recipes as JSON with suggested slots.
- Compare two recipes side by side, showing all saved values or only differences. Unspecified fields remain explicit.
- Export recipes as JSON, Open Fuji Recipe or a PDF settings sheet, and copy settings as text. Source links, creator attribution and field notes travel with supported exports.
- Inspect an original Fujifilm camera JPEG locally, review the recognized EXIF/MakerNote settings and save them as a recipe.
- Archive original Fujifilm settings backup files with SHA-256 checksums, and export the complete local vault as one portable `.recipevault` file.

The public recipe catalogue is deferred. Import the recipes you already have access to. A public page must expose its settings as readable text; authentication and subscription restrictions are not bypassed. If a page does not import cleanly, paste its settings or use a screenshot. FilmSim Recipes pages can be used through this general import workflow; its proprietary app database and binaries were not decompiled.

## Photo tools

Choose **Photo tools → Inspect original JPEG** for a file copied directly from your Fujifilm camera or card. Inspection reads the source without modifying or uploading it. Supported values become editable settings; missing values and unrecognized metadata are reported rather than guessed. Recipe names, C1–C4 assignments and Auto ISO limits cannot be recovered reliably. Exposure metadata describes the photograph, not a recommended shooting setup. The current inspector accepts JPEG files up to 80 MiB; RAF and HEIF inspection are unavailable.

**Open X RAW Studio** releases RecipeVault's camera connection and opens an installed Fujifilm X RAW Studio, or its download page. Exact RAF development uses that application's compatible connected camera workflow. RecipeVault does not currently render RAW files or transfer a kit into X RAW Studio.

## Camera setup

1. Charge the X-M5 and use a USB cable that carries data.
2. Set **CONNECTION MODE → USB RAW CONV./BACKUP RESTORE**.
3. Set **USB POWER SUPPLY/COMM SETTING → POWER SUPPLY OFF/COMM ON**.
4. Quit X Acquire, X RAW Studio, tethering apps and other software using the camera.
5. Choose **Camera → Connect**, then **Read C1–C4**.
6. Keep a full settings backup made with Fujifilm Tether App (formerly X Acquire). Add its original file to the Backups tab.
7. Start by applying one recipe to one expendable bank and check it on the camera after disconnecting. For still recipes, check the bank's still/movie assignment. Set the film simulation dial to C to use the bank's simulation.

The X-M5 has **four custom banks**, not seven. Importing a seven-slot Simu kit adds recipes to the library only; you explicitly choose a valid C1–C4 target.

Saving or editing a kit never changes the camera. Use **Review C1…** through **Review C4…** to review and apply each assigned bank separately. An unassigned kit bank stays unchanged.

## How writes and restores behave

- Only the exact X-M5 model is enabled in this version.
- The camera must advertise the required PTP operations and recipe properties.
- Bank selection is validated and the previous selector is restored after operations.
- Before a write, the app re-reads all banks, rejects stale plans and incomplete reads, and persists a snapshot. If saving fails, no recipe setting is written.
- Writes include only understood fields supplied by the recipe, in dependency order. Missing fields are not replaced by defaults. The camera's writable flag and value constraints are checked.
- The app reads settings back and reports failure rather than claiming success if anything differs.
- Failure midway through a write can leave a partial change. The pre-write backup remains available. There is no automatic speculative rollback.
- Snapshot restore requires matching camera model, serial number and firmware. It restores understood recipe settings and names; unmapped settings remain unchanged. Inactive dependent fields may be omitted.
- No firmware modifications, firmware uploads, undocumented memory writes, C0/live-state writes or photo deletion operations are implemented.

## Backup scopes

**Complete RecipeVault:** use **Backups → Export complete vault** to preserve recipes, favourites, collections, saved kit snapshots, covers and stored camera backups in one `.recipevault` file. The app validates its indexes, references and checksums before export or restore. Restore previews the contents, replaces this Mac's vault only, and keeps the previous vault in a neighbouring recovery folder that opens in Finder. It does not change the camera. The current archive limit is 256 MiB of decoded contents, with a 384 MiB limit for the encoded file. Archives are not encrypted. See `docs/VAULT_ARCHIVE.md` for format, limits and recovery details.

**Recipe-bank snapshots:** JSON captures of readable C1–C4 property bytes plus camera identity. These are created manually or before writes. Restore applies known recipe fields and names after the same checks as a normal write. The UI makes this limited scope explicit.

**Full camera settings:** create and restore these using **Fujifilm Tether App (formerly X Acquire)**. RecipeVault stores the exact file you choose and its checksum, then exports it unchanged. It does not validate arbitrary user-supplied files as camera backups, convert them into a different format, or claim native whole-camera restore. Settings backups do not contain your photos or firmware. Fujifilm excludes certain settings, including measured custom white balance results, from its backup workflow.

A read-only experimental settings-object download is present in the source but is not exposed as a supported full backup/restore workflow. It has not been validated on X-M5 hardware.

## Files and privacy

Your data lives in `~/Library/Application Support/RecipeVault/`:

- `library.json`: recipes and attribution
- `organization.json`: favourites, collections and complete saved kit recipes
- `backups.json`: backup metadata and checksums
- `Backups/`: original backup payloads
- `Covers/`: local cover images; the supplied covers also have an app-bundled fallback

Writes are atomic. If an index cannot be decoded, the app preserves it and blocks overwriting it. The app has no analytics, account, network-based OCR or background uploads. Network requests occur only when you explicitly load a recipe page or open a source/support link. Backups can contain camera model, firmware and serial number; keep them private. Portable backups contain the files in the vault. Photo inspection does not copy source photographs there, and export does not read photos or firmware from the camera.

## Implementation

- `Sources/FujiCore/`: recipe formats, strict import validation, Simu decoding, JPEG metadata inspection, PTP packet parsing and recipe property encodings.
- `Sources/RecipeVault/`: native UI, camera transport, write planning, library organisation, sharing, portable vault backups and OCR/page input.
- `Tests/FujiCoreTests/`: codec, parser, import, photo metadata and protocol tests.
- `Tests/RecipeCameraTests/`: simulated camera safety, organisation, sharing and persistent-vault/archive tests.
- `docs/VALIDATION.md`: test results and hardware verification boundary.
- `docs/PROTOCOL.md`: research decisions, sources and hardware verification boundary.
- `docs/VAULT_ARCHIVE.md`: portable archive validation, limits and restore behaviour.

This is independent software, not affiliated with Fujifilm, Simu, FilmSim Recipes or recipe publishers. See `THIRD_PARTY_NOTICES.md` for research sources and attribution.

## Interface and supplied recipes

A compact graphite-and-silver workspace with Library, Kits, Compare, Photo tools, Camera, Backups and Guide pages. Native recipe selection, grouped settings and C1–C4 rows share consistent controls and review sheets. Cmd-F searches, Cmd-I imports and Cmd-N creates a recipe. Filters clear after saving or importing so the new recipe remains visible. Design rationale and reusable conventions are recorded in `DESIGN.md`.

The owner's **Perfect Summer, Ronin Neg, Reality Plus and Everyday Ace** recipes remain in the local vault and separate `Recipe-Collection` deliverable; neither is included in this repository. A fresh installation starts with an empty library. Their four cover assets are included and explicitly labelled AI-styled approximations from one CC0 RAW-developed photograph, not exact camera renders or live previews. Covers are read locally and remain static when a recipe is edited. The separate local collection contains the original RAW, provenance, images and four-recipe JSON.

Portrait Enhancer is a separate saved field with Off/Weak/Medium/Strong options. Its USB mapping is unverified, so it remains manual and generates a write-review warning. Auto ISO and exposure compensation remain shooting notes.
