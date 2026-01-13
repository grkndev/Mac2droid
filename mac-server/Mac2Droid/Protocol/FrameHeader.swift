import Foundation

// MARK: - Handshake Packet
/// Initial handshake sent when client connects (24 bytes)
struct M2DHandshake {
    let magic: [UInt8]      // 4 bytes: "M2D\0"
    let version: UInt32     // 4 bytes: protocol version
    let codec: M2DCodec     // 4 bytes: codec type
    let width: UInt32       // 4 bytes: video width
    let height: UInt32      // 4 bytes: video height
    let frameRate: UInt32   // 4 bytes: target FPS

    init(width: Int, height: Int, frameRate: Int, codec: M2DCodec = .h264) {
        self.magic = M2DProtocol.magic
        self.version = M2DProtocol.version
        self.codec = codec
        self.width = UInt32(width)
        self.height = UInt32(height)
        self.frameRate = UInt32(frameRate)
    }

    /// Serialize handshake to Data (24 bytes)
    func serialize() -> Data {
        var data = Data(capacity: M2DProtocol.handshakeSize)

        // Magic (4 bytes)
        data.append(contentsOf: magic)

        // Version (4 bytes, big-endian)
        data.append(contentsOf: version.bigEndianBytes)

        // Codec (4 bytes, big-endian)
        data.append(contentsOf: codec.rawValue.bigEndianBytes)

        // Width (4 bytes, big-endian)
        data.append(contentsOf: width.bigEndianBytes)

        // Height (4 bytes, big-endian)
        data.append(contentsOf: height.bigEndianBytes)

        // Frame rate (4 bytes, big-endian)
        data.append(contentsOf: frameRate.bigEndianBytes)

        return data
    }
}

// MARK: - Frame Header
/// Header for each video frame packet (12 bytes)
struct M2DFrameHeader {
    let flags: M2DFrameFlags   // 1 byte: frame flags
    let reserved: UInt8        // 1 byte: reserved for future use
    let pts: UInt64            // 6 bytes: presentation timestamp (microseconds)
    let payloadSize: UInt32    // 4 bytes: size of NAL data following header

    init(flags: M2DFrameFlags, pts: UInt64, payloadSize: Int) {
        self.flags = flags
        self.reserved = 0
        self.pts = pts
        self.payloadSize = UInt32(payloadSize)
    }

    /// Create header for a video frame
    static func videoFrame(pts: UInt64, payloadSize: Int, isKeyframe: Bool, isConfig: Bool) -> M2DFrameHeader {
        var flags = M2DFrameFlags()
        if isKeyframe {
            flags.insert(.keyframe)
        }
        if isConfig {
            flags.insert(.config)
        }
        return M2DFrameHeader(flags: flags, pts: pts, payloadSize: payloadSize)
    }

    /// Create end-of-stream header
    static func endOfStream() -> M2DFrameHeader {
        return M2DFrameHeader(flags: .endOfStream, pts: 0, payloadSize: 0)
    }

    /// Serialize header to Data (12 bytes)
    func serialize() -> Data {
        var data = Data(capacity: M2DProtocol.frameHeaderSize)

        // Flags (1 byte)
        data.append(flags.rawValue)

        // Reserved (1 byte)
        data.append(reserved)

        // PTS (6 bytes, big-endian) - only use lower 48 bits
        let ptsBytes = pts.bigEndianBytes
        data.append(contentsOf: ptsBytes.suffix(6))

        // Payload size (4 bytes, big-endian)
        data.append(contentsOf: payloadSize.bigEndianBytes)

        return data
    }
}

// MARK: - Byte Conversion Extensions
extension UInt32 {
    var bigEndianBytes: [UInt8] {
        let value = self.bigEndian
        return withUnsafeBytes(of: value) { Array($0) }
    }
}

extension UInt64 {
    var bigEndianBytes: [UInt8] {
        let value = self.bigEndian
        return withUnsafeBytes(of: value) { Array($0) }
    }
}

extension Data {
    /// Read big-endian UInt32 from specified offset
    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        _ = copyBytes(to: UnsafeMutableBufferPointer(start: &value, count: 1), from: offset..<(offset + 4))
        return UInt32(bigEndian: value)
    }

    /// Read big-endian 6-byte value as UInt64 from specified offset
    func readUInt48(at offset: Int) -> UInt64 {
        guard offset + 6 <= count else { return 0 }
        var bytes = [UInt8](repeating: 0, count: 8)
        copyBytes(to: &bytes[2], from: offset..<(offset + 6))
        return bytes.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
    }
}
