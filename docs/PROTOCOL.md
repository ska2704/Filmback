# Camera protocol and evidence

Research and implementation date: 17 October 2026. RecipeVault targets **Fujifilm X-M5, C1–C4**. It does not claim that an X-M5 has an X-Trans V sensor: the camera combines an X-Trans CMOS 4 sensor with X-Processor 5. Fujifilm's [X-M5 product information](https://www.fujifilm-x.com/en-us/products/cameras/x-m5/) and [camera manual](https://app.fujifilm-dsc.com/en/manual/x-m5/) are authoritative for the camera's capabilities.

## What is and is not verified

The app compiles against Apple's native ImageCaptureCore framework. Automated tests exercise wire encodings, malformed data handling, bank write planning and simulated camera failures. **Initial read-only X-M5 hardware checks were performed on 24 October 2026 with firmware 1.30.** Discovery, DeviceInfo and current-bank value reads succeeded. All recipe-property descriptor queries returned GeneralError `0x2002`, so bank switching and recipe writes remain blocked by the existing descriptor checks. No property writes were sent during those checks.

The protocol is publicly documented through community reverse engineering, not an official Fujifilm API contract. The [Fuji PTP Recipes compatibility matrix](https://github.com/ILFforever/fujifilm-ptp-recipes/blob/daba2d97d6b37bd1d5dbc68ca974f6b22f433071/docs/tested-bodies.md) confirms X-H2 and X-T5 and reports an X-Pro3 failure. It does not confirm X-M5. FilmKit reports X100VI testing. Processor or sensor generation alone does not establish USB compatibility.

The supplied [XRFC capability analysis](https://github.com/ILFforever/fujifilm-ptp-recipes/blob/daba2d97d6b37bd1d5dbc68ca974f6b22f433071/docs/reverse-engineering/xrfc-capability-database.md) includes X-M5, but static capability records are supporting evidence, not physical-camera validation. In particular, portrait enhancement and smooth-skin effects must not be treated as interchangeable. RecipeVault does not write smooth-skin settings on X-M5.

## Native Mac transport

ImageCaptureCore discovers local USB cameras. The implementation requires Fujifilm vendor ID `0x04CB`, `ICCameraDeviceCanAcceptPTPCommands`, an X-M5 DeviceInfo identity, and advertised property/operation support. Session ownership is delegated to ImageCaptureCore rather than issuing a competing raw OpenSession command.

The framework's [requestSendPTPCommand API](https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestsendptpcommand(_:outdata:completion:)) accepts a standard command container, a separate outgoing data payload, and returns incoming data plus the PTP response. Headers and callback signatures were checked against the installed Xcode SDK. Requests are serialized. Apple's official [PTPPassThrough sample](https://developer.apple.com/library/archive/samplecode/PTPPassThrough/PTPPassThrough.zip) states that ImageCaptureCore ignores the supplied transaction ID and assigns its own. Hardware confirmed supplied IDs 1 and 42 returning consecutive framework IDs. The ImageCaptureCore path validates response length (12–32 bytes in four-byte increments), kind and result code; its callback is correlated with the active device, session generation and local request counter. The generic raw-PTP validator still requires an exact transaction match. A timeout requires reconnecting. A shared operation lease prevents two services from switching the bank selector concurrently. Disconnect waits for the current operation.

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

The pinned research now documents `GetDevicePropDesc` as a stub on X-H2 firmware 5.20, returning `0x2002` despite being advertised ([hardware evidence](https://github.com/ILFforever/fujifilm-ptp-recipes/blob/daba2d97d6b37bd1d5dbc68ca974f6b22f433071/docs/current-shooting-state.md#discovering-what-a-body-supports)). The initial X-M5 check matches that behavior. Changing USB mode does not address it. When, and only when, a descriptor query returns exactly `0x2002`, RecipeVault falls back to `XM5CapabilityProfile`: the camera must identify as a Fujifilm X-M5 with a serial, report USB mode `0xD16E = 6`, and return `X-M5_0100` from both `0xD186` and `0xD187` (the XRFC.DAT key for `X-M5Config1`). Each value must then match the researched enumeration or stepped range for that property, with exact payload width. Any other descriptor error, any other capability generation, and any unmapped property stop the operation. The profile is a value allowlist; it does not prove a value is writable in the camera's current state, so camera rejections still stop the write and read-back verification still applies.

Every write must be advertised, mapped and described as writable. The camera descriptor is queried again immediately before the write, so dependency-driven ranges are evaluated after parent modes. Missing or unsupported descriptors stop the operation, except for the `0x2002` profile fallback above. RecipeVault never guesses an unknown encoding or blindly replays the raw property block.

## Backup and write safety

A write is refused unless RecipeVault could put every changed property back from its own bank backup. For each property the plan changes, re-encoding the pre-write bank must reproduce the original bytes exactly. Unmapped values (for example film simulation `0x8000`), values inactive in the original bank (Kelvin outside Kelvin WB; DR, highlight and shadow under DR priority) and names that are not safe ASCII therefore block the write; fields the plan leaves alone do not. Restoring a saved bank applies the same rule. The saved backup is re-read from disk and compared with the camera snapshot before any setting changes. After writing, all four banks are read again and the untouched banks must be unchanged. The bank selector is restored and read back after every operation; if that cannot be confirmed, the session is invalidated and the camera must be reconnected.

1. Read the target bank and prepare a reviewable plan.
2. Re-read all four banks before applying. Reject stale plans or incomplete reads.
3. Require the caller's persistent-backup operation to complete successfully.
4. Select the bank, refresh identity/capabilities, write mapped fields in dependency order, then its name.
5. Read back every requested field and the name. Any rejection or mismatch is a failure, not a successful recipe apply.

A mid-write failure may leave a partially changed bank. The app reports accepted property codes, stops further recipe changes and keeps the pre-write snapshot. It does not attempt an unverified automatic rollback.

Bank snapshots include model, firmware and serial information in their enclosing backup record. A recipe restore is deliberately limited to understood settings; it is not an exact restoration of every camera option. Unknown and inactive fields remain unchanged.

## Whole camera settings

[libfuji's USB implementation](https://github.com/petabyt/libfuji/blob/34af78ada37613b6dfa18a439900e49a54dde8e3/lib/fuji_usb.c) documents a separate backup object: read ObjectInfo for handle 0, then GetObject(0), in RAW-conversion mode. RecipeVault includes a conservative download path requiring USBMode `0xD16E = 6`, advertised operations `0x1008`/`0x1009`, object format `0x5000`, a nonzero size no larger than 100,000 bytes and exact downloaded length. These checks may reject a legitimate newer camera format rather than treating another object as a settings backup.

A read-only hardware probe downloaded a 67,452-byte object with format `0x5000` from X-M5 firmware 1.30. The resulting opaque blob has **not** been validated as an X-M5 restore file. Do not label it as a verified whole-camera restore backup. The UI vault supports keeping files made by Fujifilm's official software. [FUJIFILM TETHER APP](https://www.fujifilm-x.com/en-us/products/software/tether-app/) is the official whole-camera backup/restore route; X Acquire functionality has moved into TETHER APP. RecipeVault does not implement the unverified SendObjectInfo/SendObject restore sequence.

## Pinned research sources

- Fuji PTP Recipes: `daba2d97d6b37bd1d5dbc68ca974f6b22f433071`, documentation CC BY 4.0; example code MIT.
- [FilmKit](https://github.com/eggricesoy/filmkit/tree/9e3bbcf858b1f9dc522e90adf7e385554f5969e2): `9e3bbcf858b1f9dc522e90adf7e385554f5969e2`, MIT. Used for comparison, not copied wholesale.
- [libfuji](https://github.com/petabyt/libfuji/tree/34af78ada37613b6dfa18a439900e49a54dde8e3): `34af78ada37613b6dfa18a439900e49a54dde8e3`, MIT. This is the maintained Fujifilm library extracted from Fudge; the guessed `fujihack/fudge` repository does not exist.
- [Simu v1 format](https://simurecipes.com/format): public import-format documentation. Independently implemented; no proprietary app binaries or private endpoints were used.

See `THIRD_PARTY_NOTICES.md` for attribution and license notices. This project reverse engineers recipe interchange and USB setting behavior, not Fujifilm's proprietary image-processing algorithms. No optical or sensor output equivalence between recipes has been established.

## X-M5 settings object, mapped 4 November 2026

Firmware 1.30. `GetObject(0)` returned the same 67,452 bytes as a FUJIFILM TETHER APP backup saved moments earlier, so the Tether App `.dat` is that object. It starts with `FUJIFILMX-BACKUP0100X-M5`. A later fetch after a power cycle differed in one byte at offset 63268, outside the bank data.

Each bank holds a name field at 63985, 65009, 66033 or 67057, 1024 bytes apart. The name-to-bank link was confirmed for C1–C4 by selecting each bank and reading `0xD18D`. Offsets below are relative to the name.

- `-394` film simulation: 2 Astia, 15 Classic Chrome, 17 Nostalgic Neg, 18 Reala Ace. Other values are unmapped.
- `-364` grain: 2 reads back as `0xD195 = 6` (Off). 1 means on (Weak Small on the banks seen), but size isn't located, so RecipeVault doesn't report it.
- `-366`, `-365` Color Chrome and FX Blue: value + 1 = wire value.
- `-511` white balance: 0 Auto, 1 Auto White Priority, 10 Kelvin. Other values are unmapped.
- `-509`, `-505`, `-485` red/blue shift pairs for those three modes, with the blue value 2 bytes after red: wire = 9 − byte. Other modes appear to have their own pairs.
- `-613` Kelvin, 16-bit little endian.
- `-370`, `-368` highlight and shadow: wire = (byte − 4) × 5.
- `-374` color: wire = (7 − byte) × 10. `-372` sharpness: wire = (4 − byte) × 10.
- `-453` High ISO NR: value = byte − 4. `-448` clarity: wire = (byte − 6) × 10.

These were fitted to one live read of four banks, so color and sharpness each rest on two distinct values. Dynamic range, D range priority, monochrome tone and smooth skin were the same on all four banks and have not been located.

### Observed camera behaviour

- After a battery pull, `0xD18C` read 1 while `0xD18D` was empty and recipe properties held placeholders (`0xD190 = 0xFFFF`, `0xD191 = 0xD192 = 0x8000`). Writing `0xD18C` returned real bank values. The 24 October "C1" read shows nearly the same pattern, so it was very likely this state and not C1's recipe. RecipeVault now always writes the selector before reading a bank.
- `GetObject(0)` directly after four selector writes in one session got no data. Timeouts spread to the control endpoint, and the camera's indicator kept blinking while switched off until the battery was removed. This happened once and the cause is unknown. RecipeVault won't fetch the object after a selector write until the camera has been unplugged.
- DR Auto on this body is `0xD190 = 0xFFFF`. A bank set to DR Auto in the camera's own menu read 65535 with `0xD191 = 0`, and a write of 65535 was accepted and verified with AUTO ISO at 640–6400. Upstream describes 65535 as a placeholder while priority is active, so RecipeVault reads it as DR Auto only when priority is Off. A write of 0, the value upstream lists for other bodies, returned `0x201C` while AUTO ISO was capped at 400; that doesn't separate a wrong value from the ISO limit.
- Dynamic range writes appear to depend on ISO. `0xD190 = 400` on C4 returned `0x201C` with AUTO ISO at 160–400, then was accepted and verified with AUTO ISO at 640–6400. The manual requires ISO 640 for DR400 and 320 for DR200. This is one before-and-after, with an unplug between them. Whether the check uses the live ISO or the bank's saved ISO is unknown.
- `0xD195` can read 6, documented upstream as an Off read-back that must not be written. RecipeVault treats 6 and 1 as equal and only ever writes 1.
