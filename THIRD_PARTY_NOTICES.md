# Third-party notices

Filmback is an independent implementation. It is not affiliated with Fujifilm, Simu, FilmKit, Fuji X Weekly or any recipe publisher. No proprietary Fujifilm SDK, camera firmware, paid recipe catalog or GPL-licensed implementation is bundled.

## Protocol documentation attribution

The USB recipe-bank findings and encoding tables were adapted from **Fuji PTP Recipes**, by the Fuji PTP Recipes contributors:

- Source: https://github.com/ILFforever/fujifilm-ptp-recipes
- Inspected commit: `daba2d97d6b37bd1d5dbc68ca974f6b22f433071`
- Documentation license: [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/).
- Changes: independent Swift implementation; X-M5-only bank limits; native ImageCaptureCore transport; strict descriptor and identity checks; mandatory persistent snapshots; dependency-aware writes and verification. No claim is made that upstream tested this camera or endorses this implementation.
- Example code license: MIT, notice reproduced below as conservative attribution for reference-derived implementation.

## Implementation references

**FilmKit**, by eggricesoy:

- Source: https://github.com/eggricesoy/filmkit
- Inspected commit: `9e3bbcf858b1f9dc522e90adf7e385554f5969e2`
- License: MIT. Used to compare USB recipe mapping and sequencing. The TypeScript application is not bundled.

**libfuji**, by Daniel Cook and contributors:

- Source: https://github.com/petabyt/libfuji
- Inspected commit: `34af78ada37613b6dfa18a439900e49a54dde8e3`
- License: MIT. Used to understand RAW-mode backup object access. The C library is not linked or bundled.

## MIT notices

The following notice is reproduced for these copyright holders:

Copyright (c) 2026 Fuji PTP Recipes contributors

Copyright (c) 2026 eggricesoy

Copyright (c) 2026 Daniel Cook

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Recipe interchange specifications

- [Simu public recipe format v1](https://simurecipes.com/format), documented 8 October 2026. Independently implemented from the public format specification. The public example code `SIMU102KQY54AEMG0TN3B` is used as an interoperability fixture. No Simu application source code, binary or private API is included.
- [Open Fuji Recipe specification](https://github.com/gosku/open-fuji-recipe), commit `888af1d1a2e7a9a155630d926423a2d0de8acc9e`. Independently implemented as an interchange format. No source code copied.

Imported recipes remain attributed to their original authors and sources. Filmback does not ship a scraped recipe database. User-provided source URLs, author names and notes are retained where supplied. Recipe settings describe camera controls; original article text and sample photographs are not republished by this project.

## Photograph metadata references

The independent JPEG/EXIF reader uses public tag definitions documented by Phil Harvey and ExifTool contributors: [Fujifilm tag reference](https://exiftool.org/TagNames/FujiFilm.html), [Fujifilm mapping source](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/FujiFilm.pm). No ExifTool executable or Perl implementation is bundled. Its public legacy Fujifilm test image was used only for local validation and is not included in the app or source distribution.

## Recipe cover source photograph

Joerg Lippmann, raw.pixls.us sample 6666, Fujifilm X-S20 DSCF2526.RAF. CC0 1.0 Universal: https://creativecommons.org/publicdomain/zero/1.0/. Source repository: https://raw.pixls.us/#repo. Source RAW SHA-256: 737c1551843282d4963ccb351a4d6409f3eaf172928d563bbaf72fe0f1f74fdd.

The bundled covers are AI-styled edits of a generic RAW development of this photograph. They are illustrative approximations, not Fujifilm camera output.
