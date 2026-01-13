import Foundation
import CoreGraphics

// MARK: - Stream Configuration
struct StreamConfig {
    // Display settings
    var displayID: CGDirectDisplayID
    var captureWidth: Int
    var captureHeight: Int

    // Encoding settings
    var frameRate: Int
    var bitRate: Int
    var codec: M2DCodec
    var keyFrameInterval: Int

    // Capture options
    var showCursor: Bool
    var captureSystemAudio: Bool

    // Network settings
    var serverPort: UInt16

    init(
        displayID: CGDirectDisplayID = CGMainDisplayID(),
        quality: M2DQuality = .balanced
    ) {
        self.displayID = displayID
        self.captureWidth = quality.width
        self.captureHeight = quality.height
        self.frameRate = quality.frameRate
        self.bitRate = quality.bitRate
        self.codec = .h264
        self.keyFrameInterval = quality.frameRate * 2  // Keyframe every 2 seconds
        self.showCursor = true
        self.captureSystemAudio = false
        self.serverPort = M2DProtocol.defaultPort
    }

    /// Update configuration from quality preset
    mutating func apply(quality: M2DQuality) {
        self.captureWidth = quality.width
        self.captureHeight = quality.height
        self.frameRate = quality.frameRate
        self.bitRate = quality.bitRate
        self.keyFrameInterval = quality.frameRate * 2
    }

    /// Create handshake packet from config
    func createHandshake() -> M2DHandshake {
        return M2DHandshake(
            width: captureWidth,
            height: captureHeight,
            frameRate: frameRate,
            codec: codec
        )
    }
}

// MARK: - Display Info
struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
    let isMain: Bool

    var resolution: String {
        "\(width) x \(height)"
    }

    static func fromDisplay(_ displayID: CGDirectDisplayID) -> DisplayInfo {
        let bounds = CGDisplayBounds(displayID)
        let isMain = CGDisplayIsMain(displayID) != 0

        // Try to get display name from IOKit
        let name = DisplayInfo.getDisplayName(for: displayID) ?? "Display \(displayID)"

        return DisplayInfo(
            id: displayID,
            name: name,
            width: Int(bounds.width),
            height: Int(bounds.height),
            isMain: isMain
        )
    }

    private static func getDisplayName(for displayID: CGDirectDisplayID) -> String? {
        var object: io_object_t
        var iter = io_iterator_t()

        let matching = IOServiceMatching("IODisplayConnect")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)

        guard result == kIOReturnSuccess else { return nil }

        defer { IOObjectRelease(iter) }

        while true {
            object = IOIteratorNext(iter)
            guard object != 0 else { break }
            defer { IOObjectRelease(object) }

            if let info = IODisplayCreateInfoDictionary(object, IOOptionBits(kIODisplayOnlyPreferredName)).takeRetainedValue() as? [String: Any],
               let names = info[kDisplayProductName] as? [String: String],
               let name = names.values.first {
                return name
            }
        }

        return nil
    }
}

// MARK: - Connection State
enum ConnectionState: Equatable {
    case idle
    case listening
    case connected(clientInfo: String)
    case streaming(fps: Int, bitrate: Int)
    case error(String)

    var isActive: Bool {
        switch self {
        case .listening, .connected, .streaming:
            return true
        default:
            return false
        }
    }

    var statusText: String {
        switch self {
        case .idle:
            return "Ready"
        case .listening:
            return "Waiting for connection..."
        case .connected(let info):
            return "Connected: \(info)"
        case .streaming(let fps, let bitrate):
            let mbps = Double(bitrate) / 1_000_000.0
            return "Streaming \(fps)fps @ \(String(format: "%.1f", mbps))Mbps"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}
