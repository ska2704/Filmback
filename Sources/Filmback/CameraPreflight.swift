import AppKit

/// Checks that need no camera traffic, run before Filmback opens or changes anything on the camera.
enum CameraPreflight {
    /// Other apps that also take over the camera. Only one may use it at a time.
    @MainActor static func otherCameraApps() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
            guard id.hasPrefix("com.fujifilm.") || id == "com.apple.Image_Capture" else { return nil }
            return app.localizedName ?? id
        }.sorted()
    }

    /// Stops idle sleep from interrupting a write. Release with `endActivity`.
    static func beginWriteActivity(_ reason: String) -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: reason)
    }
}
