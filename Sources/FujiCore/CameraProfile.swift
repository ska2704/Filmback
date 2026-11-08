import Foundation

/// Checks a value against what one camera generation accepts, for cameras that don't report their own limits.
public protocol CameraValueValidator {
    func validate(property: UInt16, value: Data) throws
}

extension XM5CapabilityProfile: CameraValueValidator {}

/// Everything Filmback needs to know to read and write one camera model's custom banks.
///
/// A model gets a profile only after its reads and writes have been checked on real hardware.
/// A camera without a profile can still connect, but only its diagnostics report is available.
/// See docs/ADDING_A_CAMERA.md.
public struct CameraProfile {
    public let name: String
    /// Model strings as the camera reports them, without the FUJIFILM prefix.
    public let models: Set<String>
    public let bankCount: Int
    /// The D186/D187 identity string that the value tables were checked against.
    public let generation: String
    public let decodeSettingsObject: (Data) throws -> [CameraSlotSnapshot]
    public let resolveValidator: (_ device: PTPDeviceInfo, _ usbMode: Data, _ condition: Data, _ compatibility: Data) throws -> any CameraValueValidator

    public var banks: ClosedRange<Int> { 1...bankCount }

    public static let xm5 = CameraProfile(
        name: "X-M5",
        models: ["X-M5"],
        bankCount: 4,
        generation: XM5CapabilityProfile.generation,
        decodeSettingsObject: XM5BackupDecoder.decode,
        resolveValidator: { device, usbMode, condition, compatibility in
            try XM5CapabilityProfile.resolve(device: device, usbMode: usbMode, condition: condition, compatibility: compatibility)
        })

    /// Add a new model here once it has been verified.
    public static let all: [CameraProfile] = [.xm5]

    public static func matching(_ device: PTPDeviceInfo) -> CameraProfile? {
        all.first { $0.models.contains(device.modelName) }
    }
}

public extension PTPDeviceInfo {
    /// The model without its FUJIFILM prefix, for example "X-M5".
    var modelName: String {
        model.uppercased().replacingOccurrences(of: "FUJIFILM", with: "").trimmingCharacters(in: .whitespaces)
    }
}
