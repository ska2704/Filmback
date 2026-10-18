import XCTest
@testable import FujiCore

final class PTPTests: XCTestCase {
    private func baseline(_ overrides: [UInt16:Data] = [:]) -> CameraSlotSnapshot {
        let properties: [UInt16:Data] = [0xD192:PTP.u16(11),0xD191:PTP.u16(0),0xD199:PTP.u16(2),0xD195:PTP.u16(3)]
        return CameraSlotSnapshot(slot:1,name:"Original",properties:properties.merging(overrides) { _,new in new })
    }
    func testSignedAndFractionalToneWireEncoding() throws {
        let result = try RecipeWireCodec.encode(Recipe(name:"Test",settings:[.highlight:"-1.5",.wbShiftR:"-3"]),baseline:baseline())
        XCTAssertEqual(result.writes.first { $0.property == 0xD19D }?.data,Data([0xF1,0xFF]))
        XCTAssertEqual(result.writes.first { $0.property == 0xD19A }?.data,Data([0xFD,0xFF]))
    }
    func testPortraitEnhancerIsRetainedButNeverWrittenOverUSB() throws {
        let result = try RecipeWireCodec.encode(Recipe(name: "Portrait", settings: [.portraitEnhancer: "Off"]), baseline: baseline())
        XCTAssertTrue(result.writes.isEmpty)
        XCTAssertEqual(result.warnings, ["Portrait enhancer is not mapped for X-M5 USB writing. Set it to Off on the camera."])
    }
    func testNoiseReductionIsNotLinear() throws {
        for (dial,wire) in RecipeWireCodec.nrCodes {
            let result = try RecipeWireCodec.encode(Recipe(name:"Test",settings:[.highISONR:String(dial)]),baseline:baseline())
            XCTAssertEqual(result.writes.first?.data,PTP.u16(UInt16(wire)))
        }
    }
    func testMonochromeSuppressesColorAndRetainsToning() throws {
        let result = try RecipeWireCodec.encode(Recipe(name:"Mono",settings:[.filmSimulation:"Acros STD",.color:"2",.colorChromeFXBlue:"Strong",.wbShiftR:"1",.monoWC:"5"]),baseline:baseline())
        XCTAssertEqual(result.writes.map(\.property),[0xD192,0xD193])
        XCTAssertEqual(result.warnings.count,3)
        XCTAssertEqual(result.writes.last?.data,PTP.i16(50))
    }
    func testPrioritySuppressesAllThreeDependentTones() throws {
        let result = try RecipeWireCodec.encode(Recipe(name:"DR",settings:[.dRangePriority:"Auto",.dynamicRange:"DR400",.highlight:"-2",.shadow:"3"]),baseline:baseline())
        XCTAssertEqual(result.writes.map(\.property),[0xD191]); XCTAssertEqual(result.warnings.count,3)
        XCTAssertEqual(result.writes.first?.data,PTP.u16(32768))
    }
    func testDisablePriorityOrdersItBeforeToneWrites() throws {
        let result = try RecipeWireCodec.encode(Recipe(name:"DR",settings:[.dRangePriority:"Off",.dynamicRange:"DR400",.shadow:"3"]),baseline:baseline([0xD191:PTP.u16(2)]))
        XCTAssertEqual(result.writes.map(\.property),[0xD191,0xD190,0xD19E])
    }
    func testTemperatureOnlyWrittenForKelvinMode() throws {
        let suppressed = try RecipeWireCodec.encode(Recipe(name:"WB",settings:[.kelvin:"5600"]),baseline:baseline())
        XCTAssertTrue(suppressed.writes.isEmpty)
        let applied = try RecipeWireCodec.encode(Recipe(name:"WB",settings:[.whiteBalance:"Kelvin",.kelvin:"5600"]),baseline:baseline())
        XCTAssertEqual(applied.writes.map(\.property),[0xD199,0xD19C])
    }
    func testPartialGrainPreservesOtherAxis() throws {
        let result = try RecipeWireCodec.encode(Recipe(name:"Grain",settings:[.grainSize:"Large"]),baseline:baseline())
        XCTAssertEqual(result.writes.first?.data,PTP.u16(5))
        XCTAssertThrowsError(try RecipeWireCodec.encode(Recipe(name:"Grain",settings:[.grainRoughness:"Strong"]),baseline:baseline([0xD195:PTP.u16(6)])))
    }
    func testUnsupportedAndFractionalNumericValuesRejected() throws {
        for pair: (RecipeField,String) in [(.color,"NaN"),(.sharpness,"0.5"),(.monoWC,"1.5"),(.wbShiftR,"10"),(.highlight,"4.5")] {
            var settings: [RecipeField:String] = [.filmSimulation:pair.0 == .monoWC ? "Acros STD" : "Provia"]
            settings[pair.0] = pair.1
            XCTAssertThrowsError(try RecipeWireCodec.encode(Recipe(name:"Bad",settings:settings),baseline:baseline()))
        }
    }
    func testSparseRecipeDoesNotFillDefaultsOrWriteUnknownState() throws {
        let result = try RecipeWireCodec.encode(Recipe(name:"Only clarity",settings:[.clarity:"2"]),baseline:baseline())
        XCTAssertEqual(result.writes.map(\.property),[0xD1A2])
        XCTAssertFalse(RecipeWireCodec.writableProperties.contains(0xD1A5))
        XCTAssertFalse(RecipeWireCodec.writableProperties.contains(0xD18E))
        XCTAssertFalse(RecipeWireCodec.writableProperties.contains(0xD1A4))
    }
    func testStringsRejectTruncationAndNormalizeNames() throws {
        let raw = try PTP.string("Café")
        var reader = PTPReader(raw); XCTAssertEqual(try reader.string(),"Café")
        var truncated = PTPReader(raw.dropLast()); XCTAssertThrowsError(try truncated.string())
        XCTAssertEqual(PTP.safeName("  Café’s 🎞️ summer  "),"Cafe's summer")
        XCTAssertEqual(PTP.safeName(String(repeating:"a",count:30)).count,25)
    }
    func testResponseRejectsCrossTransactionAndCameraError() throws {
        var response = PTP.u32(12); response.append(PTP.u16(3)); response.append(PTP.u16(0x2001)); response.append(PTP.u32(7))
        XCTAssertNoThrow(try PTP.validateResponse(response,transaction:7))
        XCTAssertThrowsError(try PTP.validateResponse(response,transaction:8))
        response[6] = 0x1C; XCTAssertThrowsError(try PTP.validateResponse(response,transaction:7))
    }
    func testDescriptorValidatesSignedHalfStepRange() throws {
        var raw = PTP.u16(0xD19D); raw.append(PTP.u16(3)); raw.append(1)
        raw.append(PTP.i16(0)); raw.append(PTP.i16(-10)); raw.append(1)
        raw.append(PTP.i16(-20)); raw.append(PTP.i16(40)); raw.append(PTP.i16(5))
        let descriptor = try PTPPropertyDescriptor.parse(raw)
        XCTAssertNoThrow(try descriptor.validate(PTP.i16(-15)))
        XCTAssertThrowsError(try descriptor.validate(PTP.i16(-14)))
        XCTAssertThrowsError(try descriptor.validate(PTP.i16(45)))
    }
    func testDescriptorEnumerationsAndReadOnlyAreEnforced() throws {
        var raw = PTP.u16(0xD192); raw.append(PTP.u16(4)); raw.append(1)
        raw.append(PTP.u16(1)); raw.append(PTP.u16(1)); raw.append(2)
        raw.append(PTP.u16(2)); raw.append(PTP.u16(1)); raw.append(PTP.u16(11))
        let descriptor = try PTPPropertyDescriptor.parse(raw)
        XCTAssertNoThrow(try descriptor.validate(PTP.u16(11)))
        XCTAssertThrowsError(try descriptor.validate(PTP.u16(20)))
        raw[4] = 0; XCTAssertThrowsError(try PTPPropertyDescriptor.parse(raw).validate(PTP.u16(11)))
    }
    func testDecodePreservesSentinelsAsUnknownAndGrainOffAlias() throws {
        let recipe = baseline([0xD195:PTP.u16(6),0xD19D:PTP.i16(-32768),0xD190:PTP.u16(65535)]).recipe
        XCTAssertEqual(recipe.settings[.grainRoughness],"Off")
        XCTAssertNil(recipe.settings[.highlight]); XCTAssertNil(recipe.settings[.dynamicRange])
    }
}
