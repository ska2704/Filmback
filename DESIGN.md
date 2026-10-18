# RecipeVault design

RecipeVault is a native macOS working tool for one photographer’s Fujifilm X-M5: collect recipes, inspect settings, assign C1–C4, and preserve camera backups. The user requested a Fujifilm-inspired interface that feels deliberately designed rather than a generic generated dashboard.

## Direction

A compact camera workbench. Graphite navigation and film identification, matte silver working surfaces, thin divisions, precise alignment and restrained green actions. The X-M5’s physical controls and Fujifilm’s film-exchange design rationale inform the interface; there are no imitation dials or official logos. Photo covers may illustrate a recipe’s mood when explicitly labelled as approximate; they must never claim to predict the camera’s exact output.

- Native SF typography, 11pt minimum supporting text, 12–13pt working text, 19–26pt headings.
- Monospaced digits for bank IDs and measured settings. Regular sans for prose and names.
- Shared semantic colors in `DesignSystem.swift`. Green signals actions; amber signals caution. Graphite anchors navigation and film identity.
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

Library, Kits, Compare, Photo tools, Camera, Backups and Guide use the existing semantic palette, SF typography, thin rules, restrained green actions and native controls. The toolkit extends the camera workbench without adding a new visual system.

- Library filters sit with recipe selection. A star marks favourites; collection and simulation pickers provide explicit scope. Empty results offer a way to clear filters.
- Kits use four aligned C1–C4 rows. Unassigned banks stay visible; inspection identifies the saved copy, and camera actions say which bank will be reviewed. Editing a set remains separate from applying it.
- Comparison uses a ruled three-column settings view with a differences-only toggle. Changed values have a small semantic marker, and absent values read “Not specified.”
- Photo inspection uses the established graphite sheet heading, grouped settings and fixed footer. Recovery warnings and uninterpreted metadata remain adjacent to the values being saved.
- Complete-vault restore presents archive counts and the replacement/recovery consequence before confirmation. Camera backup rows remain separate so the scope of each restore is clear.
- PDF sharing is a readable settings sheet with attribution and notes. It does not reuse approximate covers as evidence of rendered output.
