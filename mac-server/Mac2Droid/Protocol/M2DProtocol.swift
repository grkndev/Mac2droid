import Foundation

// MARK: - Protocol Constants
enum M2DProtocol {
    /// Magic bytes for handshake: "M2D\0"
    static let magic: [UInt8] = [0x4D, 0x32, 0x44, 0x00]

    /// Protocol version: 1.0.0 = 0x00010000
    static let version: UInt32 = 0x00010000

    /// Default server port
    static let defaultPort: UInt16 = 5555

    /// Handshake size in bytes
    static let handshakeSize = 24

    /// Frame header size in bytes
    static let frameHeaderSize = 12

    /// NAL start code (4 bytes)
    static let nalStartCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
}

// MARK: - Codec Types
enum M2DCodec: UInt32 {
    case h264 = 1
    case hevc = 2
}

// MARK: - Frame Flags
struct M2DFrameFlags: OptionSet {
    let rawValue: UInt8

    /// Frame contains codec configuration (SPS/PPS)
    static let config = M2DFrameFlags(rawValue: 0x80)

    /// Frame is a keyframe (IDR)
    static let keyframe = M2DFrameFlags(rawValue: 0x40)

    /// End of stream marker
    static let endOfStream = M2DFrameFlags(rawValue: 0x20)
}

// MARK: - Quality Presets
enum M2DQuality {
    case performance  // 720p, 30fps, 4Mbps
    case balanced     // 1080p, 30fps, 6Mbps
    case quality      // 1080p, 60fps, 10Mbps

    var width: Int {
        switch self {
        case .performance: return 1280
        case .balanced, .quality: return 1920
        }
    }

    var height: Int {
        switch self {
        case .performance: return 720
        case .balanced, .quality: return 1080
        }
    }

    var frameRate: Int {
        switch self {
        case .performance, .balanced: return 30
        case .quality: return 60
        }
    }

    var bitRate: Int {
        switch self {
        case .performance: return 4_000_000
        case .balanced: return 6_000_000
        case .quality: return 10_000_000
        }
    }
}
