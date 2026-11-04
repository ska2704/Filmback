import XCTest
@testable import FujiCore

final class RecipeImportTests: XCTestCase {
    func testCoverMetadataSurvivesNativeImportExportAndPersistence() throws {
        let cover = RecipeCover(filename: "summer-cover.jpg", credit: "Original photographer, CC0",
                                sourceURL: "https://example.org/photo", renderingNote: "Illustrative recipe approximation.")
        let recipe = Recipe(name: "Summer", settings: [.filmSimulation: "Classic Chrome", .portraitEnhancer: "Off"], cover: cover)
        let imported = try RecipeImporter.parse(RecipeExporter.json(recipes: [recipe]))
        XCTAssertEqual(imported.recipes[0].cover, cover)
        XCTAssertEqual(imported.recipes[0].settings[.portraitEnhancer], "Off")
        XCTAssertTrue(imported.warnings.isEmpty)
        let persisted = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(persisted, recipe)

        var localCover = cover
        localCover.sourceURL = nil
        XCTAssertEqual(try JSONDecoder().decode(RecipeCover.self, from: JSONEncoder().encode(localCover)), localCover)
    }

    func testPortraitEnhancerIsDistinctFromSmoothSkin() throws {
        let imported = try RecipeImporter.parse("Film Simulation: Reala Ace\nPortrait Enhancer LV: Medium\nSmooth Skin Effect: Weak").recipes[0]
        XCTAssertEqual(imported.settings[.portraitEnhancer], "Medium")
        XCTAssertEqual(imported.settings[.smoothSkin], "Weak")
        let native = try RecipeImporter.parse(RecipeExporter.json(recipes: [imported])).recipes[0]
        XCTAssertEqual(native.settings, imported.settings)
        XCTAssertThrowsError(try RecipeImporter.normalizedValue("Medium", for: .smoothSkin))
    }

    func testLegacyRecipeWithoutCoverRemainsReadable() throws {
        let data = Data(#"{"name":"Legacy","settings":{"filmSimulation":"Provia"}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Recipe.self, from: data).cover)
        XCTAssertNil(try RecipeImporter.parse(String(decoding: data, as: UTF8.self)).recipes[0].cover)
    }

    func testCoverRejectsUnsafeFilenamesAndSourceURLs() throws {
        for filename in ["../outside.jpg", "/tmp/photo.jpg", "nested/photo.png", "nested\\photo.jpg",
                         "file:///photo.jpg", "%2E%2E%2Fphoto.jpg", ".hidden.jpg", "photo.gif", "photo.jpg\n", ""] {
            let cover = RecipeCover(filename: filename, credit: "Photographer", renderingNote: "Approximation")
            XCTAssertFalse(cover.hasSafeFilename, filename)
            XCTAssertThrowsError(try cover.validate(), filename)
            XCTAssertThrowsError(try JSONDecoder().decode(RecipeCover.self, from: JSONEncoder().encode(cover)), filename)
        }
        for source in ["file:///tmp/photo.jpg", "javascript:alert(1)", "ftp://example.org/photo", "https:///", "relative.jpg", ""] {
            let cover = RecipeCover(filename: "photo.jpg", credit: "Photographer", sourceURL: source, renderingNote: "Approximation")
            XCTAssertThrowsError(try cover.validate(), source)
        }
        for filename in ["photo.JPG", "photo.jpeg", "photo 2.png", "a.jpg"] {
            XCTAssertNoThrow(try RecipeCover(filename: filename, credit: "Photographer", renderingNote: "Approximation").validate())
        }
    }

    func testImportRejectsMalformedCoverObjects() throws {
        let malformed: [Any] = ["photo.jpg", ["photo.jpg"], true,
                                ["filename": "photo.jpg"],
                                ["filename": "../photo.jpg", "credit": "Author", "renderingNote": "Approximation"],
                                ["filename": "photo.jpg", "credit": 42, "renderingNote": "Approximation"],
                                ["filename": "photo.jpg", "credit": "Author", "sourceURL": false, "renderingNote": "Approximation"],
                                ["filename": "photo.jpg", "credit": "", "renderingNote": "Approximation"]]
        for cover in malformed {
            let data = try JSONSerialization.data(withJSONObject: ["name": "Invalid", "settings": ["filmSimulation": "Provia"], "cover": cover])
            XCTAssertThrowsError(try RecipeImporter.parse(String(decoding: data, as: UTF8.self)))
        }
    }

    func testNativeJSONRoundTripPreservesAbsenceAndAttribution() throws {
        let original = Recipe(name: "Evening experiment", sourceURL: "https://example.org/original",
                              author: "Camera owner", notes: "Try outdoors", settings: [.filmSimulation: "Classic Chrome", .shadow: "0.5"],
                              createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let exported = try RecipeExporter.json(recipes: [original])
        XCTAssertTrue(exported.contains("\"settings\" : {"))
        let result = try RecipeImporter.parse(exported)
        XCTAssertEqual(result.recipes, [original])
        XCTAssertNil(result.recipes[0].settings[.color])
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testOFRNumbersAndHalfToneSteps() throws {
        let result = try RecipeImporter.parse(#"{"v":1,"name":"My recipe","film_simulation":"Classic Chrome","white_balance_red":2,"white_balance_blue":-5,"highlight":-1,"shadow":0.5,"source_url":"https://example.org/recipe","source_attribution":"Original author"}"#)
        let recipe = try XCTUnwrap(result.recipes.first)
        XCTAssertEqual(recipe.settings[.shadow], "0.5")
        XCTAssertEqual(recipe.settings[.wbShiftB], "-5")
        XCTAssertEqual(recipe.author, "Original author")
        XCTAssertNil(recipe.settings[.clarity])
    }

    func testPastedRecipeSettings() throws {
        let result = try RecipeImporter.parse("""
        Personal summer test
        Film Simulation: Classic Neg.
        Dynamic Range: DR400
        Grain Effect: Weak, Small
        White Balance: 6500K, +2 Red & -5 Blue
        Highlight Tone: -1
        Shadow Tone: +0.5
        Noise Reduction: -4
        ISO: Auto up to 6400
        """)
        let recipe = result.recipes[0]
        XCTAssertEqual(recipe.name, "Personal summer test")
        XCTAssertEqual(recipe.settings[.filmSimulation], "Classic Negative")
        XCTAssertEqual(recipe.settings[.grainSize], "Small")
        XCTAssertEqual(recipe.settings[.whiteBalance], "Kelvin")
        XCTAssertEqual(recipe.settings[.kelvin], "6500")
        XCTAssertEqual(recipe.settings[.wbShiftR], "2")
        XCTAssertEqual(recipe.settings[.wbShiftB], "-5")
        XCTAssertTrue(recipe.notes.contains("ISO: Auto up to 6400"))
        XCTAssertTrue(result.warnings.contains { $0.contains("ISO") })
    }

    func testUnknownFieldWarnsAndNullStaysAbsent() throws {
        let result = try RecipeImporter.parse(#"{"name":"Partial","settings":{"filmSimulation":"Provia","clarity":null,"futureSetting":"yes"}}"#)
        XCTAssertNil(result.recipes[0].settings[.clarity])
        XCTAssertEqual(result.warnings.count, 2)
    }

    func testRejectsMalformedUnknownVersionAndInvalidValues() {
        for input in ["{", "[]", #"{"v":2,"film_simulation":"Provia"}"#,
                      #"{"schemaVersion":2,"recipes":[]}"#,
                      #"{"settings":{"clarity":true}}"#,
                      #"{"settings":{"highlight":0.25}}"#,
                      #"{"settings":{"wbShiftR":10}}"#,
                      #"{"settings":{"filmSimulation":"Not a simulation"}}"#,
                      "Just a title", "https://example.org/recipe"] {
            XCTAssertThrowsError(try RecipeImporter.parse(input), "Should reject: \(input)")
        }
    }

    func testConflictingFieldsAreNeverSilentlyOverwritten() {
        XCTAssertThrowsError(try RecipeImporter.parse("Film Simulation: Provia\nFilm Simulation: Velvia"))
        XCTAssertThrowsError(try RecipeImporter.parse(#"{"film_simulation":"Provia","filmSimulation":"Velvia"}"#))
    }

    func testIncompleteWBShiftFailsInsteadOfInventingChannel() {
        XCTAssertThrowsError(try RecipeImporter.parse("White Balance: Auto\nWB Shift: Red +2"))
        XCTAssertThrowsError(try RecipeImporter.parse("White Balance: Auto, +2 Red & -3.5 Blue"))
    }

    func testOFRExportRefusesToFillMissingValues() {
        XCTAssertThrowsError(try RecipeExporter.ofr(recipe: Recipe(name: "Partial", settings: [.filmSimulation: "Provia"])))
    }

    func testOFRExportUsesNumericJSON() throws {
        let recipe = Recipe(name: "Neutral test", settings: [
            .filmSimulation: "Provia", .dynamicRange: "DR100", .dRangePriority: "Off", .grainRoughness: "Off",
            .colorChromeEffect: "Off", .colorChromeFXBlue: "Off", .whiteBalance: "Auto", .wbShiftR: "0", .wbShiftB: "0",
            .highlight: "-0.5", .shadow: "0.5", .color: "0", .sharpness: "0", .highISONR: "0", .clarity: "0"
        ])
        let exported = try RecipeExporter.ofr(recipe: recipe)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any])
        XCTAssertEqual(object["shadow"] as? Double, 0.5)
        XCTAssertFalse(object["shadow"] is String)
        XCTAssertNil(object["grain_size"])
        XCTAssertEqual(try RecipeImporter.parse(exported).recipes[0].settings, recipe.settings)
    }

    func testSimuPresenceMaskKeepsAbsentValuesAbsent() throws {
        let code = makeCode(fields: [(0, 10, 5), (12, 3, 4)])
        let recipe = try RecipeImporter.parse(code.lowercased()).recipes[0]
        XCTAssertEqual(recipe.settings, [.filmSimulation: "Classic Chrome", .highlight: "-0.5"])
        XCTAssertNil(recipe.settings[.shadow])
    }

    func testSimuKelvinAndLinkName() throws {
        let code = makeCode(fields: [(9, 13, 4)], extraBits: [(430, 11)])
        let result = try RecipeImporter.parse("https://simurecipes.com/r#\(code)&n=My%20Recipe")
        XCTAssertEqual(result.recipes[0].name, "My Recipe")
        XCTAssertEqual(result.recipes[0].settings[.whiteBalance], "Kelvin")
        XCTAssertEqual(result.recipes[0].settings[.kelvin], "6300")
        let encodedName = try RecipeImporter.parse("https://simurecipes.com/r#\(code)&n=Light%20%26%20shade%20100%25")
        XCTAssertEqual(encodedName.recipes[0].name, "Light & shade 100%")
    }

    func testSimuKitNamesAndSlots() throws {
        var bits: [Int] = []
        append(1, width: 8, to: &bits)
        append(1, width: 3, to: &bits)
        append(0, width: 3, to: &bits)
        append(1 << 17, width: 18, to: &bits)
        append(10, width: 5, to: &bits)
        append(5, width: 3, to: &bits)
        append(1 << 17, width: 18, to: &bits)
        append(19, width: 5, to: &bits)
        let code = encode(bits)
        let result = try RecipeImporter.parse("simu://k/\(code)?n=Travel&r=First&r=Second")
        XCTAssertEqual(result.recipes.map(\.name), ["First", "Second"])
        XCTAssertEqual(result.recipes.map(\.suggestedSlot), [1, 6])
        XCTAssertTrue(result.warnings.contains { $0.contains("C6") })
    }

    func testSimuChecksumAndInvalidIndicesAreRejected() throws {
        let valid = makeCode(fields: [(0, 10, 5)])
        let corrupted = String(valid.dropLast()) + (valid.last == "0" ? "Z" : "0")
        XCTAssertThrowsError(try RecipeImporter.parse(corrupted))
        XCTAssertThrowsError(try RecipeImporter.parse(makeCode(fields: [(0, 31, 5)])))
        XCTAssertThrowsError(try RecipeImporter.parse(makeCode(fields: [(12, 15, 4)])))
        XCTAssertThrowsError(try RecipeImporter.parse(valid.replacingOccurrences(of: "SIMU1", with: "SIMU2")))
        XCTAssertThrowsError(try RecipeImporter.parse(String(valid.dropLast(2))))
    }

    func testPublicSimuFormatExample() throws {
        let result = try RecipeImporter.parse("SIMU102KQY54AEMG0TN3B")
        XCTAssertEqual(result.recipes[0].settings[.filmSimulation], "Classic Chrome")
        XCTAssertEqual(result.recipes[0].settings[.dynamicRange], "DR200")
    }

    private func makeCode(fields: [(Int, Int, Int)], extraBits: [(Int, Int)] = []) -> String {
        var bits: [Int] = []
        append(0, width: 8, to: &bits)
        let mask = fields.reduce(0) { $0 | (1 << (17 - $1.0)) }
        append(mask, width: 18, to: &bits)
        for (_, value, width) in fields { append(value, width: width, to: &bits) }
        for (value, width) in extraBits { append(value, width: width, to: &bits) }
        return encode(bits)
    }

    private func append(_ value: Int, width: Int, to bits: inout [Int]) {
        bits += (0..<width).reversed().map { (value >> $0) & 1 }
    }

    private func encode(_ input: [Int]) -> String {
        var bits = input
        while bits.count % 8 != 0 { bits.append(0) }
        var crc = 0
        for start in stride(from: 0, to: bits.count, by: 8) {
            crc ^= bits[start..<(start + 8)].reduce(0) { ($0 << 1) | $1 }
            for _ in 0..<8 { crc = ((crc << 1) ^ (crc & 0x80 != 0 ? 7 : 0)) & 0xff }
        }
        append(crc, width: 8, to: &bits)
        while bits.count % 5 != 0 { bits.append(0) }
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return "SIMU1" + stride(from: 0, to: bits.count, by: 5).map { start in
            String(alphabet[bits[start..<(start + 5)].reduce(0) { ($0 << 1) | $1 }])
        }.joined()
    }

    func testRecipeDiffIgnoresInactiveAndEquivalentValues() {
        let camera = Recipe(name: "bank", settings: [.highlight: "2", .color: "1", .kelvin: "4500", .whiteBalance: "Auto", .grainRoughness: "Off"])
        let target = Recipe(name: "new", settings: [.highlight: "2.0", .color: "4", .kelvin: "6700", .whiteBalance: "Auto", .grainRoughness: "Off", .grainSize: "Small", .clarity: "-2"])
        XCTAssertEqual(RecipeDiff.changes(from: camera, to: target), [
            RecipeSettingChange(field: .clarity, current: nil, target: "-2"),
            RecipeSettingChange(field: .color, current: "1", target: "4"),
        ].sorted { a, b in RecipeField.allCases.firstIndex(of: a.field)! < RecipeField.allCases.firstIndex(of: b.field)! })
        XCTAssertEqual(RecipeDiff.changes(from: nil, to: Recipe(name: "x", settings: [.color: "1"])).first?.current, nil)
    }
}
