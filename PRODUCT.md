# Filmback

A local native macOS photography toolkit for Fujifilm cameras, verified on the X-M5. It connects seven workspaces: Library, Kits, Compare, Photo tools, Camera, Backups and Guide.

The library accepts Simu codes/kits, Open Fuji Recipe, JSON, pasted text, local screenshot OCR/QR and public recipe-page text. Favourites, named collections, film-simulation filters and sorting help prepare a shooting set. Saved C1–C4 kits contain independent recipe snapshots, with inspection, editing and recipe-JSON export. Kit storage never writes to the camera; each bank uses the existing reviewed write workflow.

Comparison shows saved setting differences, including unspecified values. PDF settings sheets and copied text retain attribution and field notes. Original Fujifilm JPEG inspection recovers supported EXIF/MakerNote settings locally without inventing missing values; RAF and HEIF inspection are outside the current feature set. X RAW Studio handoff releases the camera connection and opens the external application or its download page.

The backup workspace distinguishes local vault recovery, C1–C4 recipe snapshots and archived official Tether App settings files. Complete `.filmback` archives preserve recipes, organisation, kit snapshots, covers and stored camera backups up to 256 MiB of decoded data. Restore validates the archive, previews its contents, replaces only this Mac’s vault and retains the previous vault in a recovery folder. Whole-camera settings restoration remains in Tether App.

The supplied recipe covers remain clearly labelled static approximations. Public catalogue browsing is deferred; users can continue importing recipes they have access to.

Hardware compatibility remains experimental until tested on the physical X-M5. Connection, preview, backup and verification states must remain explicit. A write is successful only after readback; a partial write may require a reviewed restore.

No account, remote recipe sync, subscription or cloud image analysis is required. Recipe publishers retain attribution. The app is independent of Fujifilm, Simu and FilmSim Recipes.
