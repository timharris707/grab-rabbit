import Foundation

public struct StableCameraSource: Codable, Equatable, Sendable {
    public let uniqueID: String
    public let name: String
    public let deviceType: String

    public init(uniqueID: String, name: String, deviceType: String) {
        self.uniqueID = uniqueID
        self.name = name
        self.deviceType = deviceType
    }
}

public struct CapturableWindowSource: Codable, Equatable, Sendable {
    public let windowID: UInt32
    public let title: String
    public let applicationName: String
    public let bundleIdentifier: String?
    public let width: Int
    public let height: Int

    public init(
        windowID: UInt32,
        title: String,
        applicationName: String,
        bundleIdentifier: String?,
        width: Int,
        height: Int
    ) {
        self.windowID = windowID
        self.title = title
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.width = width
        self.height = height
    }
}

public enum LiveSourceSelectionError: Error, Equatable, CustomStringConvertible {
    case noCameras
    case cameraNotFound(String)
    case noCapturableWindows
    case windowNotFound(UInt32)

    public var description: String {
        switch self {
        case .noCameras:
            "No real camera is currently enumerated. Connect the selected camera and retry."
        case .cameraNotFound(let uniqueID):
            "The exact camera unique ID is unavailable: \(uniqueID). No substitute was selected."
        case .noCapturableWindows:
            "No real capturable windows are available. A display or desktop will not be substituted."
        case .windowNotFound(let windowID):
            "The exact window ID is unavailable: \(windowID). A display or desktop will not be substituted."
        }
    }
}

public enum LiveSourceSelection {
    public static func camera(
        uniqueID: String,
        from cameras: [StableCameraSource]
    ) throws -> StableCameraSource {
        guard !cameras.isEmpty else { throw LiveSourceSelectionError.noCameras }
        guard let selected = cameras.first(where: { $0.uniqueID == uniqueID }) else {
            throw LiveSourceSelectionError.cameraNotFound(uniqueID)
        }
        return selected
    }

    public static func window(
        windowID: UInt32,
        from windows: [CapturableWindowSource]
    ) throws -> CapturableWindowSource {
        guard !windows.isEmpty else { throw LiveSourceSelectionError.noCapturableWindows }
        guard let selected = windows.first(where: { $0.windowID == windowID }) else {
            throw LiveSourceSelectionError.windowNotFound(windowID)
        }
        return selected
    }

    public static func afterValidatedSources<T>(
        cameraID: String,
        cameras: [StableCameraSource],
        windowID: UInt32?,
        windows: [CapturableWindowSource],
        createOutput: () throws -> T
    ) throws -> T {
        _ = try camera(uniqueID: cameraID, from: cameras)
        if let windowID { _ = try window(windowID: windowID, from: windows) }
        return try createOutput()
    }
}
