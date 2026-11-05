# Validation

## Version 0.6 load sheet, 4 November 2026

The catalog page and navigation were redesigned around Option 5 of the concepts in `work/ui-concepts-2026-11-04`. `swift test --build-system native` passed **156 tests, zero failures**, with new tests for the bank status stamps and for choosing the ON CAMERA source. Release captures of Catalogs and Library were reviewed with a copy of the real data. This release changes no camera commands, and it was not run against the camera. Its sheets and menus, and the minimum window size, have not been visually checked.

## Version 0.5 catalogs, 4 November 2026

`swift test --build-system native` passed **153 tests, zero failures**, including two optional checks against real files kept out of the repository: a Tether App backup against live reads of all four banks, and a real X-S20 RAF. The decoder was fitted to those same live reads, so that check confirms the fit rather than proving it independently. A baseline run on the earlier code didn't finish, so the last earlier result is the 124 recorded below.

Hardware, firmware 1.30, using separate test tools and not this app: `GetObject(0)` matched a Tether App backup byte for byte. Selector writes to C1, C2, C4 and back to C3 read back correctly, and the settings object afterwards differed from the backup by one byte outside the bank data. The next `GetObject(0)` straight after those selector writes got no data and left the camera's USB unresponsive until its battery was removed. The cause is unknown.

In the installed 0.5 app on the same camera, Connect and Read C1–C4 showed all four bank names, with no USB errors logged, and comparing the catalog with that read showed only the settings this read can't see.

Dynamic range: the first load attempt on 4 November stopped when the camera answered `0x201C` to DR Auto sent as 0. DR400 was then also refused with AUTO ISO capped at 400, and accepted once AUTO was 640–6400. DR Auto sent as 65535 was then accepted too. Each write was confirmed by the app reading the banks back.

Catalog loads then worked in the app for a one-setting change: C4 clarity went from -2 to -1 and back, confirmed on the camera's screen for -1 and by the app's saved reads. C1, C2 and C3 didn't change, and no USB errors were logged.

A full catalog, People & Interiors, then loaded in the app. A separate bank read afterwards matched the requested values on all 65 compared values across C1–C4, including names, film simulation, white balance, shifts, half-step tone and grain Off, which was written as 1 and read back as 6. No settings outside the load changed, and no USB errors were logged. The catalog's film and white balance modes were Classic Chrome, Nostalgic Negative, Eterna, Reala Ace, Auto, Auto White Priority and Kelvin.

**Not tested on the camera:** other film simulations and white balance modes (including Daylight and Fluorescent 3), Acros and other monochrome recipes, DR200, DR Auto with a lower ISO range, Grain Large, and restoring a backup.

An independent read-through of the write path found nine issues, all fixed with tests. They include white balance shifts that could be wrong after a mode change, an "On camera" label that could go stale, and placeholder values being accepted as a recipe. That review only read the code.

UI review covered release captures of Library, Catalogs and Camera in the new palette. Sheets, including the catalog review, comparison and backup viewer, have not been visually checked.


## X-M5 descriptor fallback and recovery guard, 24 October 2026

`swift test --build-system native` passed **124 tests, zero failures**. The new service-level camera-safety tests cover: the `0x2002` fallback planning and applying a write with backup-first ordering and read-back; Kelvin values outside the researched range (2000 K, 5555 K) refused; other descriptor errors (`0x2005`) not falling back; an unverified capability generation (`X-M5_0200`) refused; an unmapped baseline film simulation (`0x8000`) blocking overwrite while unrelated fields stay writable; a saved bank holding an unmapped value refused for restore; a failed selector restore invalidating the session; and an out-of-range selector refusing any bank change. Profile unit tests, backup re-read verification and transport-invalidation tests are included.

The rebuilt release app was launched on the Mac. It has **not** yet read C1–C4 or written a bank on the physical X-M5, and the camera's `0xD186`/`0xD187` capability strings have not been read. The C1 values read earlier today include film simulation `0x8000` and DR priority Auto, which this guard treats as not exactly restorable, so a write that changes the film simulation, DR, highlight or shadow on that bank would currently be refused.

## Initial X-M5 hardware check, 24 October 2026

The transport correction passed all **102 tests**, including 19 PTP tests and all eight simulated camera-safety tests. Regression fixtures cover the observed framework-assigned transaction IDs, malformed framing and preserved camera errors. An independent source review found no material transport regression. The rebuilt, ad-hoc-signed release app was launched and connected successfully to the physical X-M5 through its Camera view, displaying firmware 1.30 and the camera identity. No bank-read or recipe-write action was invoked in that UI check.

A connected Fujifilm X-M5 on firmware 1.30 was identified with a nonempty serial and USB mode `0xD16E = 6`. Read-only probes confirmed GetDeviceInfo and all current-bank values in `0xD18C`–`0xD1A4`. The selector was 1. No selector or recipe-setting writes were sent.

ImageCaptureCore replaced app transaction IDs 1 and 42 with consecutive wire IDs, confirming Apple's documented transport behavior. This exposed and led to correction of the app's exact-ID check at the ImageCaptureCore boundary. Strict response framing, error handling and session/request correlation remain enforced; raw PTP retains exact transaction matching.

GetDevicePropDesc returned GeneralError `0x2002` for every property in `0xD18C`–`0xD1A4`, although the operation and properties were advertised. The existing descriptor requirement therefore blocks bank switching and recipe writes. This check does not establish C1–C4 write compatibility, saved-bank persistence or restoration.

GetObjectInfo(0) reported format `0x5000` and 67,452 bytes; GetObject(0) returned that exact length. The object was saved privately as experimental diagnostic data. It is not a verified Fujifilm restore file. Camera serial, bank bytes and downloaded settings are excluded from the repository.

## Version 0.4 toolkit

The 18 October 2026 implementation adds favourites, collections, library filters and sorting; C1–C4 kit snapshots; saved-value comparison; PDF/text sharing; local original-JPEG EXIF/MakerNote inspection; portable `.recipevault` export/restore; and X RAW Studio handoff. The existing four recipes and their approximate covers are retained. Public catalogue browsing remains deferred.

On 18 October 2026, the complete native SwiftPM test suite passed **98 tests with zero failures**. The 16 archive tests passed again after final staging hardening. Coverage includes organisation persistence and corruption preservation, kit validation and snapshot independence, missing and unknown JPEG metadata, malformed binary input, portable archive integrity and restore recovery, and multi-page PDF text preservation. Debug and release builds succeeded. The app is ad-hoc signed and packaged as version 0.4.0.

Native release UI checks used a separate copy of the library. They verified favourite filtering, collection creation and membership, kit creation and persistence across restart, comparisons, original-JPEG review/import, whole-vault export, restore preview and restore completion. The exported fixture contained five recipes, one favourite, one collection, one kit and four covers. The prior vault was retained in a recovery folder, and the restored indexes were checked on disk. The normal user vault retained its four recipes. PDF/text output was checked through automated tests, including long notes across multiple pages. X RAW Studio remains an external handoff, not an internal RAW-rendering test.

An independent source review found no material issues. The visual finish review returned **ship** after inspecting 11 native captures: Library, Collections, kit editor, Kits, Compare, Photo tools, JPEG inspection, Backups, restore preview, and Library/Compare at the enforced minimum window size. The minimum content size is 1040 × 700; the captured outer window is 1040 × 732 including window chrome. Keyboard/VoiceOver behaviour and connected-camera states were not covered by this visual review. C4 in the kit editor is reachable by scrolling with the save footer fixed in place.

The JPEG parser was also compared with ExifTool's public legacy Fujifilm sample. Camera metadata and the two recoverable recipe fields matched; other values remained unspecified. An original X-M5 JPEG is still required to verify modern fields against this camera. The app has no ExifTool runtime dependency.

At the time of the 0.4 toolkit release, no physical X-M5 verification was claimed. The later read-only findings above do not establish write or restore compatibility.

## Earlier release validation

Validated on 17 October 2026 with Apple Swift 6.4, Xcode's macOS SDK, Apple silicon and a macOS 13 deployment target.

`swift test --build-system native` passed **46 tests, zero failures**:

- 14 PTP parser and recipe wire-encoding tests
- 14 recipe-import/export and Simu interoperability tests
- 8 simulated-camera safety tests
- 10 persistent vault, corruption and failure-handling tests

Safety tests exercise backup persistence failure before mutation, all-four-bank capture before write, stale plan rejection, read-only property rejection, partial writes, readback mismatch, live-state write rejection and shared operation locking.

Separate native-input smoke checks verified an actual Vision-decoded QR image, local text imports, HTML recipe extraction, HTTP failures and oversized responses. All data fixtures were temporary; no personal camera settings or recipes were used.

No physical camera was connected or modified. These tests cannot establish X-M5 USB/firmware compatibility. A first real-device check must verify discovery, readable C1–C4, a preserved pre-write backup, a single chosen bank write, camera-side persistence after disconnect, and a known-field restore. Full camera settings restoration remains in Fujifilm Tether App.

The current Swift 6.4 default Xcode build backend encountered generated test-bundle signing errors caused by filesystem metadata in this environment. The native SwiftPM backend completed the full suite. The app packager clears metadata only from its generated app bundle before ad-hoc signing and verifies that signature.

For isolated UI testing, set `RECIPEVAULT_DATA_DIR` to an absolute temporary folder when launching the executable. Normal launches use the Application Support vault described in the README.

The release app was launched and visually inspected through native UI automation. Editing and saving a recipe, importing and reviewing pasted settings, and the C1–C4 camera page were verified with an isolated temporary vault. No camera was detected. The QA fixture initially lived in protected Documents and blocked startup during file access; moving only the fixture to a local temporary directory resolved that test-environment issue. The normal vault uses Application Support.

## Version 0.2 interface

The camera-workbench redesign compiled in debug and release configurations. All 46 existing tests passed after the main redesign; final follow-ups affected view styling, accessibility labels, selection assignment and disabling the import editor during asynchronous loading. The camera service, transport and persistence implementations were unchanged.

Native UI checks covered automatic initial selection, Cmd-F, Tab/arrow-key list navigation, empty search and clearing search, recipe editing/saving, pasted text review/import, disconnected camera banks and the empty backup vault. Focused selection was checked again after removing a foreground-color override so native selected text remains legible. The default 1220 × 820 window was inspected. The 1040 × 700 minimum was reviewed in source; native automation did not successfully resize the preview, so that size has not been visually verified.

Semantic palette pairs for body/supporting text measured 5.24:1 or greater contrast. Native controls retain platform focus and selection behavior. All UI fixtures were isolated in /tmp and are excluded from the distributed app.

## Version 0.3 recipes and covers

The complete suite passed 55 tests after cover metadata, import/export, path containment, missing-image fallback, legacy-library compatibility and Portrait Enhancer support were added. One further focused PTP test passed after adding an explicit guarantee that Portrait Enhancer is retained but never written over USB: 56 distinct passing tests in total.

The supplied four-recipe JSON was decoded by the real FujiCore importer and audited independently against the source table: all 68 setting values, suggested C1–C4 slots, ISO ranges and exposure notes matched. Dry-run encoding preserved the half-stop values and white-priority balance. Portrait Enhancer remains manual, with a review warning.

Four CC0-source, AI-styled approximate covers were verified to exist in both the app assets and portable collection with matching bytes. The original RAF checksum matched the source repository. The four recipes and covers were added to the normal local vault, preserving any existing entries.

Native release UI checks verified all four recipe rows, cover changes while switching recipes, approximate-preview captions and attribution links, C1–C4 suggestions, white-priority balance and half-stop settings. A stale-cover issue found during this check was fixed by loading the new URL passed to the change callback; the corrected release was rebuilt and inspected again. The app was left open with the four recipes. No camera was connected or modified.
