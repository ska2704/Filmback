# Camera protocol and evidence

Research and implementation date: 17 October 2026. RecipeVault targets **Fujifilm X-M5, C1–C4**. It does not claim that an X-M5 has an X-Trans V sensor: the camera combines an X-Trans CMOS 4 sensor with X-Processor 5. Fujifilm's [X-M5 product information](https://www.fujifilm-x.com/en-us/products/cameras/x-m5/) and [camera manual](https://app.fujifilm-dsc.com/en/manual/x-m5/) are authoritative for the camera's capabilities.

## What is and is not verified

The app compiles against Apple's native ImageCaptureCore framework. Automated tests exercise wire encodings, malformed data handling, bank write planning and simulated camera failures. **No physical X-M5 was connected or modified during development.** USB discovery, custom-property descriptors and writes still require verification against the user's camera and firmware.

The protocol is publicly documented through community reverse engineering, not an official Fujifilm API contract. The [Fuji PTP Recipes compatibility matrix](https://github.com/ILFforever/fujifilm-ptp-recipes/blob/daba2d97d6b37bd1d5dbc68ca974f6b22f433071/docs/tested-bodies.md) confirms X-H2 and X-T5 and reports an X-Pro3 failure. It does not confirm X-M5. FilmKit reports X100VI testing. Processor or sensor generation alone does not establish USB compatibility.

The supplied [XRFC capability analysis](https://github.com/ILFforever/fujifilm-ptp-recipes/blob/daba2d97d6b37bd1d5dbc68ca974f6b22f433071/docs/reverse-engineering/xrfc-capability-database.md) includes X-M5, but static capability records are supporting evidence, not physical-camera validation. In particular, portrait enhancement and smooth-skin effects must not be treated as interchangeable. RecipeVault does not write smooth-skin settings on X-M5.

## Native Mac transport

ImageCaptureCore discovers local USB cameras. The implementation requires Fujifilm vendor ID `0x04CB`, `ICCameraDeviceCanAcceptPTPCommands`, an X-M5 DeviceInfo identity, and advertised property/operation support. Session ownership is delegated to ImageCaptureCore rather than issuing a competing raw OpenSession command.

The framework's [requestSendPTPCommand API](https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestsendptpcommand(_:outdata:completion:)) accepts a standard command container, a separate outgoing data payload, and returns incoming data plus the PTP response. Headers and callback signatures were checked against the installed Xcode SDK. Requests are serialized, response transaction IDs and lengths are checked, and a timeout requires reconnecting. A shared operation lease prevents two services from switching the bank selector concurrently. Disconnect waits for the current operation.

Camera setup: select **USB RAW CONV./BACKUP RESTORE**, connect a data-capable cable, and close other apps using the camera. Device mode is chosen on the camera; the app does not force a mode change.

## Recipe bank operations

Wire facts are derived from [Fuji PTP Recipes](https://github.com/ILFforever/fujifilm-ptp-recipes/tree/daba2d97d6b37bd1d5dbc68ca974f6b22f433071), with important corrections to FilmKit's wider write loop:

| Purpose | Code |
| --- | --- |
| GetDeviceInfo | `0x1001` |
| GetDevicePropDesc | `0x1014` |
| GetDevicePropValue | `0x1015` |
| SetDevicePropValue | `0x1016` |
| Bank selector | `0xD18C` |
| Bank name | `0xD18D` |
| Slot property range | `0xD18E`–`0xD1A4` |

Reading all banks temporarily writes the selector `0xD18C`. It does not rewrite saved recipe settings. The app waits 100 ms, confirms the selector, reads the selected bank and restores the prior selector on completion. It accesses only banks 1–4.

**`0xD1A5` is excluded.** The newer documentation identifies it as live shooting state, whereas FilmKit's older loop includes it among slot properties. Unknown image-size, image-quality, lens-modulation and color-space properties are retained in snapshots but never written by this app.

Explicit settings are mapped independently; missing fields remain unchanged. Signed tone fields use dial × 10; WB shifts use unscaled signed values. High ISO NR has a lookup encoding, and grain combines strength with size. Film simulation is written before dependent properties. Dynamic-range priority suppresses manual DR/highlight/shadow writes; Kelvin is written only in Kelvin WB mode; inactive monochrome/color fields are suppressed with review warnings. Names use a limited ASCII set with a 25-character maximum.

Every write must be advertised, mapped and described as writable. The camera descriptor is queried again immediately before the write, so dependency-driven ranges are evaluated after parent modes. Missing or unsupported descriptors stop the operation. RecipeVault never guesses an unknown encoding or blindly replays the raw property block.

## Backup and write safety

1. Read the target bank and prepare a reviewable plan.
2. Re-read all four banks before applying. Reject stale plans or incomplete reads.
3. Require the caller's persistent-backup operation to complete successfully.
4. Select the bank, refresh identity/capabilities, write mapped fields in dependency order, then its name.
5. Read back every requested field and the name. Any rejection or mismatch is a failure, not a successful recipe apply.

A mid-write failure may leave a partially changed bank. The app reports accepted property codes, stops further recipe changes and keeps the pre-write snapshot. It does not attempt an unverified automatic rollback.

Bank snapshots include model, firmware and serial information in their enclosing backup record. A recipe restore is deliberately limited to understood settings; it is not an exact restoration of every camera option. Unknown and inactive fields remain unchanged.

## Whole camera settings

[libfuji's USB implementation](https://github.com/petabyt/libfuji/blob/34af78ada37613b6dfa18a439900e49a54dde8e3/lib/fuji_usb.c) documents a separate backup object: read ObjectInfo for handle 0, then GetObject(0), in RAW-conversion mode. RecipeVault includes a conservative download path requiring USBMode `0xD16E = 6`, advertised operations `0x1008`/`0x1009`, object format `0x5000`, a nonzero size no larger than 100,000 bytes and exact downloaded length. These checks may reject a legitimate newer camera format rather than treating another object as a settings backup.

The resulting opaque blob has **not** been validated as an X-M5 restore file. Do not label it as a verified whole-camera restore backup. The UI vault supports keeping files made by Fujifilm's official software. [FUJIFILM TETHER APP](https://www.fujifilm-x.com/en-us/products/software/tether-app/) is the official whole-camera backup/restore route; X Acquire functionality has moved into TETHER APP. RecipeVault does not implement the unverified SendObjectInfo/SendObject restore sequence.

## Pinned research sources

- Fuji PTP Recipes: `daba2d97d6b37bd1d5dbc68ca974f6b22f433071`, documentation CC BY 4.0; example code MIT.
- [FilmKit](https://github.com/eggricesoy/filmkit/tree/9e3bbcf858b1f9dc522e90adf7e385554f5969e2): `9e3bbcf858b1f9dc522e90adf7e385554f5969e2`, MIT. Used for comparison, not copied wholesale.
- [libfuji](https://github.com/petabyt/libfuji/tree/34af78ada37613b6dfa18a439900e49a54dde8e3): `34af78ada37613b6dfa18a439900e49a54dde8e3`, MIT. This is the maintained Fujifilm library extracted from Fudge; the guessed `fujihack/fudge` repository does not exist.
- [Simu v1 format](https://simurecipes.com/format): public import-format documentation. Independently implemented; no proprietary app binaries or private endpoints were used.

See `THIRD_PARTY_NOTICES.md` for attribution and license notices. This project reverse engineers recipe interchange and USB setting behavior, not Fujifilm's proprietary image-processing algorithms. No optical or sensor output equivalence between recipes has been established.
