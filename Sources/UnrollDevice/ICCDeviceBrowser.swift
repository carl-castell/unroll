import Foundation
@preconcurrency import ImageCaptureCore
import UnrollCore

/// Finds iPhones and iPads through ImageCaptureCore.
///
/// ImageCaptureCore delivers delegate callbacks on the main thread, so the adapter is main-actor isolated.
/// The process must keep the main run loop running (see the executable's entry point).
@MainActor
public final class ICCDeviceBrowser: NSObject, DeviceBrowsing {
    private static let appleVendorID: Int32 = 0x05AC

    private let browser = ICDeviceBrowser()
    private var cameras: [ICCameraDevice] = []
    private var enumerated = false

    public override init() {
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
        browser.start()
    }

    public func connectedDevices() async -> [DeviceInfo] {
        await waitForEnumeration()
        // A closure, not a method reference: Swift 6.0 treats the reference as nonisolated.
        return cameras.map { Self.info(for: $0) }
    }

    public func open(_ id: DeviceID, unlockTimeout: Duration) async throws(DeviceError) -> any DeviceSession {
        try await openSession(id, unlockTimeout: unlockTimeout)
    }

    /// Like `open`, but returns the concrete session for adapter-specific diagnostics.
    public func openSession(_ id: DeviceID, unlockTimeout: Duration) async throws(DeviceError) -> ICCDeviceSession {
        await waitForEnumeration()
        guard let camera = cameras.first(where: { Self.deviceID(of: $0) == id }) else {
            throw .notFound
        }
        let session = ICCDeviceSession(camera: camera, info: Self.info(for: camera))
        try await session.open(unlockTimeout: unlockTimeout)
        return session
    }

    /// Waits for the initial device enumeration. The browser reports local devices quickly,
    /// but an iPhone that was just plugged in may need a moment longer.
    private func waitForEnumeration() async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !enumerated, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if cameras.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    static func deviceID(of device: ICDevice) -> DeviceID {
        DeviceID(device.persistentIDString ?? device.uuidString ?? device.serialNumberString ?? device.name ?? "unknown")
    }

    static func info(for camera: ICCameraDevice) -> DeviceInfo {
        DeviceInfo(
            id: deviceID(of: camera),
            name: camera.name ?? "Unnamed device",
            productKind: camera.productKind,
            access: camera.isAccessRestrictedAppleDevice ? .restricted : .available
        )
    }
}

extension ICCDeviceBrowser: @preconcurrency ICDeviceBrowserDelegate {
    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice, camera.usbVendorID == Self.appleVendorID else { return }
        cameras.append(camera)
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        cameras.removeAll { $0 === device }
    }

    public func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        enumerated = true
    }
}
