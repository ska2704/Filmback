# Validation

## Version 0.4 toolkit

The 18 October 2026 implementation adds favourites, collections, library filters and sorting; C1–C4 kit snapshots; saved-value comparison; PDF/text sharing; local original-JPEG EXIF/MakerNote inspection; portable `.recipevault` export/restore; and X RAW Studio handoff. The existing four recipes and their approximate covers are retained. Public catalogue browsing remains deferred.

On 18 October 2026, the complete native SwiftPM test suite passed **98 tests with zero failures**. The 16 archive tests passed again after final staging hardening. Coverage includes organisation persistence and corruption preservation, kit validation and snapshot independence, missing and unknown JPEG metadata, malformed binary input, portable archive integrity and restore recovery, and multi-page PDF text preservation. Debug and release builds succeeded. The app is ad-hoc signed and packaged as version 0.4.0.

Native release UI checks used a separate copy of the library. They verified favourite filtering, collection creation and membership, kit creation and persistence across restart, comparisons, original-JPEG review/import, whole-vault export, restore preview and restore completion. The exported fixture contained five recipes, one favourite, one collection, one kit and four covers. The prior vault was retained in a recovery folder, and the restored indexes were checked on disk. The normal user vault retained its four recipes. PDF/text output was checked through automated tests, including long notes across multiple pages. X RAW Studio remains an external handoff, not an internal RAW-rendering test.

An independent source review found no material issues. The visual finish review returned **ship** after inspecting 11 native captures: Library, Collections, kit editor, Kits, Compare, Photo tools, JPEG inspection, Backups, restore preview, and Library/Compare at the enforced minimum window size. The minimum content size is 1040 × 700; the captured outer window is 1040 × 732 including window chrome. Keyboard/VoiceOver behaviour and connected-camera states were not covered by this visual review. C4 in the kit editor is reachable by scrolling with the save footer fixed in place.

The JPEG parser was also compared with ExifTool's public legacy Fujifilm sample. Camera metadata and the two recoverable recipe fields matched; other values remained unspecified. An original X-M5 JPEG is still required to verify modern fields against this camera. The app has no ExifTool runtime dependency.

No physical X-M5 verification is claimed. Camera compatibility still requires the real-device checks described below.

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
