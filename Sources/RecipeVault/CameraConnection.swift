import Foundation
import Combine
import ImageCaptureCore
import FujiCore

struct DiscoveredCamera: Identifiable {
    let id: String
    let name: String
}

private final class CompletionOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
}

@MainActor
final class CameraConnection: NSObject, ObservableObject, RecipeCameraTransport, @preconcurrency ICDeviceBrowserDelegate, @preconcurrency ICCameraDeviceDelegate {
    @Published private(set) var cameras: [DiscoveredCamera] = []
    @Published private(set) var deviceInfo: PTPDeviceInfo?
    @Published private(set) var status = "Connect your X-M5 by USB to begin."
    @Published private(set) var isConnected = false
    /// Kept across launches: relaunching doesn't reset the camera, so the fetch stays unsafe until it's unplugged.
    var selectorWritten: Bool {
        get { UserDefaults.standard.bool(forKey: "selectorWrittenSinceUnplug") }
        set { UserDefaults.standard.set(newValue, forKey: "selectorWrittenSinceUnplug") }
    }
    private let browser = ICDeviceBrowser()
    private var devices: [String: ICCameraDevice] = [:]
    private var active: ICCameraDevice?
    private var sessionID = UUID()
    private var transaction: UInt32 = 0
    private var inFlight = false
    private var started = false
    private var operationLocked = false
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []

    func acquireOperation() throws {
        guard !operationLocked else { throw PTPError.unsupported("Another camera operation is running.") }
        operationLocked = true
    }
    func releaseOperation() {
        operationLocked = false
        let waiting = disconnectWaiters; disconnectWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    func invalidateSession(reason: String) {
        active = nil
        sessionID = UUID()
        isConnected = false
        deviceInfo = nil
        status = reason
    }

    func validateCommandCompletion(response: Data, error: Error?) throws {
        if let error {
            invalidateSession(reason: "Camera transport failed. Disconnect and reconnect the USB cable before retrying.")
            throw error
        }
        do {
            try PTP.validateImageCaptureCoreResponse(response)
        } catch PTPError.response(let code) {
            // A valid rejection has a known outcome; the session can still be used.
            throw PTPError.response(code)
        } catch {
            invalidateSession(reason: "Invalid camera response. Disconnect and reconnect the USB cable before retrying.")
            throw error
        }
    }

    func startDiscovery() {
        guard !started else { return }; started = true
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x00000101)!
        browser.start()
    }

    func connect(id: String) async throws {
        guard active == nil else { throw PTPError.unsupported("Disconnect the current camera first.") }
        guard let camera = devices[id], camera.usbVendorID == 0x04CB else { throw PTPError.unsupported("Fujifilm camera is no longer connected.") }
        guard camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue) else { throw PTPError.unsupported("Select USB RAW CONV./BACKUP RESTORE on the camera, then reconnect its USB cable.") }
        let session = UUID(); sessionID = session
        active = camera; camera.delegate = self; status = "Opening camera session…"
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completion = CompletionOnce(continuation)
                camera.requestOpenSession(options: nil) { error in
                    if let error { completion.finish(.failure(error)) } else { completion.finish(.success(())) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { completion.finish(.failure(PTPError.unsupported("Camera session timed out. Close X RAW STUDIO, TETHER APP and other camera apps, then reconnect."))) }
            }
            guard active === camera, sessionID == session else { throw PTPError.unsupported("Camera was disconnected.") }
            let info = try PTPDeviceInfo.parse(await command(0x1001))
            guard active === camera, sessionID == session else { throw PTPError.unsupported("Camera was disconnected.") }
            guard info.isXM5 else { throw PTPError.unsupported("This version supports X-M5 C1–C4 only. Connected model: \(info.model).") }
            guard info.properties.contains(0xD18C), info.properties.contains(0xD18D), [UInt16(0x1014),0x1015,0x1016].allSatisfy(info.operations.contains) else { throw PTPError.unsupported("This camera mode does not advertise the recipe protocol. Select USB RAW CONV./BACKUP RESTORE and reconnect.") }
            deviceInfo = info; isConnected = true
            status = "\(info.model) · firmware \(info.deviceVersion) · USB connected"
        } catch {
            if active === camera, sessionID == session { await disconnect(); status = error.localizedDescription }
            throw error
        }
    }

    func disconnect() async {
        if operationLocked { await withCheckedContinuation { disconnectWaiters.append($0) } }
        let old = active; active = nil; sessionID = UUID(); isConnected = false; deviceInfo = nil; transaction = 0
        status = "Camera disconnected."
        guard let old else { return }
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Closing is best effort. Clearing state first also covers unplugged cameras.
            let completion = CompletionOnce(continuation)
            old.requestCloseSession(options: nil) { _ in completion.finish(.success(())) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { completion.finish(.success(())) }
        }
    }

    func command(_ operation: UInt16, parameters: [UInt32] = [], outData: Data? = nil) async throws -> Data {
        guard let camera = active else { throw PTPError.unsupported("Connect the camera first.") }
        guard !inFlight else { throw PTPError.unsupported("Another camera operation is running.") }
        inFlight = true; defer { inFlight = false }
        transaction &+= 1; let tx = transaction
        let session = sessionID
        let cameraID = ObjectIdentifier(camera)
        let packet = PTP.command(operation, transaction: tx, parameters: parameters)
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let completion = CompletionOnce(continuation)
            camera.requestSendPTPCommand(packet, outData: outData) { [weak self] data, response, error in
                Task { @MainActor in
                    guard let self, self.active.map(ObjectIdentifier.init) == cameraID, self.sessionID == session, self.transaction == tx else {
                        completion.finish(.failure(PTPError.unsupported("Camera session changed before the command completed.")))
                        return
                    }
                    do {
                        try self.validateCommandCompletion(response: response, error: error)
                        completion.finish(.success(data))
                    } catch { completion.finish(.failure(error)) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                // A timed-out transaction leaves uncertain wire state. Require reconnect before further commands.
                let timedOut = completion.finish(.failure(PTPError.unsupported("Camera command timed out. Reconnect before retrying.")))
                if timedOut, self?.active.map(ObjectIdentifier.init) == cameraID, self?.sessionID == session, self?.inFlight == true, self?.transaction == tx {
                    self?.invalidateSession(reason: "Command timed out. Disconnect and reconnect the USB cable.")
                }
            }
        }
        guard active === camera, sessionID == session else { throw PTPError.unsupported("Camera session changed before the command completed.") }
        return result
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice, camera.usbVendorID == 0x04CB else { return }
        let id = camera.uuidString ?? String(describing: ObjectIdentifier(camera))
        devices[id] = camera; refreshDevices()
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) { remove(device) }
    private func refreshDevices() { cameras = devices.map { DiscoveredCamera(id: $0.key, name: $0.value.name ?? "Fujifilm camera") }.sorted { $0.name < $1.name } }
    private func remove(_ device: ICDevice) {
        selectorWritten = false
        devices = devices.filter { $0.value !== device }; refreshDevices()
        if active === device { active = nil; sessionID = UUID(); deviceInfo = nil; isConnected = false; status = "Camera unplugged. No further writes will be sent." }
    }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        if active === device { active = nil; sessionID = UUID(); deviceInfo = nil; isConnected = false; status = "Camera session closed." }
    }
    func didRemove(_ device: ICDevice) { remove(device) }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
