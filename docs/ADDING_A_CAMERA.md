# Adding a camera

Filmback connects to any Fujifilm camera over USB, but it only touches custom banks on models that have a `CameraProfile`. Everything else gets the read-only camera report.

## How support is structured

`Sources/FujiCore/CameraProfile.swift` holds one entry per verified model:

- `models`: the model strings the camera reports, without "FUJIFILM"
- `bankCount`: how many custom banks it has
- `generation`: the value of properties `0xD186` and `0xD187`
- `decodeSettingsObject`: reads the banks from the backup object (`XM5BackupDecoder` is the example)
- `resolveValidator`: the values this generation accepts (`XM5CapabilityProfile` is the example)

`RecipeCameraService` refuses every bank operation for a camera with no profile, and `CameraConnection` only exposes the report.

## Steps

Work through these in order, and stop if anything surprises you.

1. **Collect the camera report.** It lists the operations and properties the camera advertises, and the identity strings.
2. **Make a Tether App backup** and keep it safe. It's your way back. Don't commit it.
3. **Compare with [fujifilm-ptp-recipes](https://github.com/ILFforever/fujifilm-ptp-recipes).** Its capability database and value tables cover many models, and may already describe yours.
4. **Decode the backup object.** Set different values in each bank on the camera, read them, and map the offsets. Report anything unmapped rather than guessing. See "X-M5 settings object" in [PROTOCOL.md](PROTOCOL.md).
5. **Add a profile and tests.** Use the X-M5 tests as a template.
6. **Test one write at a time.** Change one setting on one bank you don't mind losing, read it back, and check it on the camera after disconnecting. Move on to the next kind of write only when that works.
7. **Open a pull request** listing the model, firmware, and each kind of write you checked.

## Known work

These are hardcoded to four banks and need generalising for models with seven:

- catalogs (`RecipeKit` and `LibraryOrganization`)
- the load sheet and the Camera, Backups and Library pages, which draw C1–C4

The service layer already uses `bankCount`.

## Things that surprised us on the X-M5

Your camera may do the same:

- `GetDevicePropDesc` returned `0x2002` for every recipe property, so limits had to come from a researched table.
- DR Auto is `0xFFFF`, not 0. DR400 was refused while the ISO range was too low for it.
- Fetching the backup object straight after bank selector writes hung the camera's USB once. Recovery needed a battery pull, so Filmback now blocks that sequence until the camera is unplugged.
- After a power cycle, bank properties can hold placeholders (`0xD192 = 0x8000`) until the selector is written.
