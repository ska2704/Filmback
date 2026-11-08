# Filmback design

Filmback is a native macOS working tool for Fujifilm photographers, verified on the X-M5: collect recipes, inspect settings, assign C1–C4, and preserve camera backups. The user requested a Fujifilm-inspired interface that feels deliberately designed rather than a generic generated dashboard.

## Direction

A compact camera workbench based on the silver X-M5: a black leatherette sidebar, satin and highlight silver working surfaces, thin divisions and precise alignment. The camera's physical controls and Fujifilm's film-exchange design rationale inform the interface; there are no imitation dials or official logos. Photo covers may illustrate a recipe's mood when explicitly labelled as approximate; they must never claim to predict the camera's exact output.

## Load sheet (version 0.6)

Catalogs are laid out around the decision made before a shoot: what's on the camera now, and what loading this catalog would change. Two film strips line up C1–C4, with ON CAMERA above THIS CATALOG. Each bank in the catalog strip is stamped CHANGED, NO CHANGE or NOT READ. Monospaced edge-print type marks labels and navigation, and recipe names stay in the regular typeface for easy reading. The sidebar and sheet carry a fine grain, so flat colour reads as leatherette and paper.

ON CAMERA shows only what the app has evidence for, and says where it came from: this session's read, a later saved read, or a verified load. A setting the read couldn't see is never called changed. The app can't see changes made on the camera itself, and the sheet says so.

## Palette: Fujifilm X-M5 Silver

Every interface colour comes from these seven values, defined in `DesignSystem.swift`.

- Silver Highlight `#E4E5E1`: main working surface, text on dark panels.
- Satin Silver `#C8CAC8`: headers, side panels, sheets.
- Brushed Aluminum `#A6A9A7`: rules, muted text on black.
- Dark Metal `#777C7C`: dividers on black. Fails small-text contrast on silver (3.4:1), so never used for text there.
- Graphite `#343638`: secondary text, secondary controls, selected navigation, film band.
- Leatherette Black `#151515`: sidebar and primary text.
- Fujifilm Red `#C92832`: primary actions and small markers only, like the camera's record button. Reaches 4.3:1 on Silver Highlight, so cautions pair a red symbol with black text instead of setting small text in red.

- Native SF typography, 11pt minimum supporting text, 12–13pt working text, 19–26pt headings.
- Monospaced digits for bank IDs and measured settings. Regular sans for prose and names.
- Shared semantic colors in `DesignSystem.swift`. Red signals primary actions and cautions. Black and graphite anchor navigation and film identity.
- Five-point corners for controls and panel boundaries. Lists and ruled settings rows carry the main content.
- Settings follow Film & tone, Color & white balance, Detail & grain throughout browsing, editing and import review.
- Native button, menu, picker, text field and selection behaviors. No gratuitous animation.
- The library uses keyboard selection, coherent filtered selection, explicit empty/search states and Cmd-F / Cmd-I / Cmd-N shortcuts.
- Camera operations retain preview, backup and verification. Disabled writes explain the connection requirement.
- Window minimum 1040 × 700; default 1220 × 820. Fixed sheet footers remain accessible while forms scroll.

## Design references

- [Fujifilm Film Simulation design](https://design.fujifilm.com/en/work/film-simulation/)
- [Fujifilm X-M5](https://www.fujifilm-x.com/en-us/products/cameras/x-m5/)
- [Impeccable](https://github.com/pbakaus/impeccable), installed from the official repository at commit `6af45ac9a5eb8792f033d3242f52e99812fd91fa`. Its Operate and craft guidance informed the redesign. It is a development skill, not an app runtime dependency.

## Recipe covers

Local photo thumbnails identify recipes in the browser, with a wider cover inside the scrolling inspector. Suggested bank labels are advisory and never imply an actual camera assignment. Photo credit links and an explicit approximate/AI-styled caption accompany each supplied illustration. Existing recipes without cover metadata retain their original layout. No photo network fetch occurs during browsing.

## Version 0.4 toolkit extension

Library, Catalogs, Compare, Photo tools, Camera, Backups and Guide use the shared palette, SF typography, thin rules, restrained red actions and native controls. The toolkit extends the camera workbench without adding a new visual system.

- Library filters sit with recipe selection. A star marks favourites; collection and simulation pickers provide explicit scope. Empty results offer a way to clear filters.
- Catalogs are folders of four recipes, listed beside four aligned C1–C4 rows. Each keeps its own copies, and the one verified on the camera carries a red marker. Editing a catalog remains separate from loading it, and loading always passes through a review of every bank.
- Comparison uses a ruled three-column settings view with a differences-only toggle. Changed values have a small semantic marker, and absent values read “Not specified.”
- Photo inspection uses the established graphite sheet heading, grouped settings and fixed footer. Recovery warnings and uninterpreted metadata remain adjacent to the values being saved.
- Complete-vault restore presents archive counts and the replacement/recovery consequence before confirmation. Camera backup rows remain separate so the scope of each restore is clear.
- PDF sharing is a readable settings sheet with attribution and notes. It does not reuse approximate covers as evidence of rendered output.
