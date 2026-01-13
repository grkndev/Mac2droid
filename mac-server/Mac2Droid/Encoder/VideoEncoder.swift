import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

// MARK: - Video Encoder
final class VideoEncoder {
    // MARK: - Types
    struct EncoderConfig {
        var width: Int32
        var height: Int32
        var frameRate: Int32
        var bitRate: Int32
        var keyFrameInterval: Int32
        var profileLevel: CFString
        var realTime: Bool
        var allowFrameReordering: Bool

        static func from(_ config: StreamConfig) -> EncoderConfig {
            return EncoderConfig(
                width: Int32(config.captureWidth),
                height: Int32(config.captureHeight),
                frameRate: Int32(config.frameRate),
                bitRate: Int32(config.bitRate),
                keyFrameInterval: Int32(config.keyFrameInterval),
                profileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
                realTime: true,
                allowFrameReordering: false  // Critical for low latency
            )
        }
    }

    /// Encoded frame callback
    typealias EncodedFrameHandler = (Data, CMTime, Bool, Bool) -> Void  // (data, pts, isKeyframe, isConfig)

    // MARK: - Properties
    private var compressionSession: VTCompressionSession?
    private var encodedFrameHandler: EncodedFrameHandler?
    private var config: EncoderConfig?

    // Parameter sets (SPS/PPS)
    private var spsData: Data?
    private var ppsData: Data?
    private var hasSentConfig = false

    private let encoderQueue = DispatchQueue(label: "com.mac2droid.encoder", qos: .userInteractive)

    // MARK: - Public Methods

    /// Configure encoder with specified settings
    func configure(config: EncoderConfig, frameHandler: @escaping EncodedFrameHandler) throws {
        self.config = config
        self.encodedFrameHandler = frameHandler
        self.hasSentConfig = false

        // Invalidate existing session
        invalidate()

        // Encoder specification - require hardware encoder
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]

        // Create compression session
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: config.width,
            height: config.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,  // Using block-based API instead
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            throw EncoderError.sessionCreationFailed(status)
        }

        // Configure session properties
        try configureSession(session, with: config)

        // Prepare to encode
        VTCompressionSessionPrepareToEncodeFrames(session)

        self.compressionSession = session
        print("[VideoEncoder] Configured: \(config.width)x\(config.height) @ \(config.frameRate)fps, \(config.bitRate / 1_000_000)Mbps")
    }

    /// Encode a sample buffer
    func encode(sampleBuffer: CMSampleBuffer, forceKeyFrame: Bool = false) throws {
        guard let session = compressionSession else {
            throw EncoderError.notConfigured
        }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw EncoderError.invalidInput
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        // Frame properties
        var frameProperties: [CFString: Any]? = nil
        if forceKeyFrame {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
        }

        // Encode with block-based callback
        var infoFlags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties as CFDictionary?,
            infoFlagsOut: &infoFlags
        ) { [weak self] status, flags, sampleBuffer in
            self?.handleEncodedFrame(status: status, flags: flags, sampleBuffer: sampleBuffer)
        }

        if status != noErr {
            throw EncoderError.encodingFailed(status)
        }
    }

    /// Force a keyframe on next encode
    func forceKeyFrame() {
        // Will be handled in next encode call
    }

    /// Flush any pending frames
    func flush() throws {
        guard let session = compressionSession else { return }

        let status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        if status != noErr {
            throw EncoderError.flushFailed(status)
        }
    }

    /// Invalidate encoder and release resources
    func invalidate() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
        }
        compressionSession = nil
        spsData = nil
        ppsData = nil
        hasSentConfig = false
    }

    // MARK: - Private Methods

    private func configureSession(_ session: VTCompressionSession, with config: EncoderConfig) throws {
        // Real-time encoding
        var status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_RealTime,
            value: config.realTime ? kCFBooleanTrue : kCFBooleanFalse
        )
        guard status == noErr else { throw EncoderError.configurationFailed(status) }

        // Disable frame reordering (B-frames) for lowest latency
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: config.allowFrameReordering ? kCFBooleanTrue : kCFBooleanFalse
        )
        guard status == noErr else { throw EncoderError.configurationFailed(status) }

        // Profile level (Baseline for compatibility and lowest decoder latency)
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: config.profileLevel
        )
        guard status == noErr else { throw EncoderError.configurationFailed(status) }

        // Bitrate
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: config.bitRate as CFNumber
        )
        guard status == noErr else { throw EncoderError.configurationFailed(status) }

        // Data rate limits (peak = 1.5x average)
        let dataRateLimits: [Int] = [Int(Double(config.bitRate) * 1.5), 1]
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: dataRateLimits as CFArray
        )

        // Expected frame rate
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: config.frameRate as CFNumber
        )

        // Max keyframe interval
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: config.keyFrameInterval as CFNumber
        )
        guard status == noErr else { throw EncoderError.configurationFailed(status) }

        // Max keyframe interval duration (seconds)
        let keyFrameDuration = Double(config.keyFrameInterval) / Double(config.frameRate)
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: keyFrameDuration as CFNumber
        )
    }

    private func handleEncodedFrame(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr else {
            print("[VideoEncoder] Encoding error: \(status)")
            return
        }

        guard let sampleBuffer = sampleBuffer else { return }

        // Check if this is a keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        // Get format description
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        // Extract and send SPS/PPS if this is a keyframe and we haven't sent config yet
        if isKeyframe && !hasSentConfig {
            if let (sps, pps) = extractParameterSets(from: formatDesc) {
                self.spsData = sps
                self.ppsData = pps

                // Create config data with SPS and PPS
                var configData = Data()
                configData.append(contentsOf: M2DProtocol.nalStartCode)
                configData.append(sps)
                configData.append(contentsOf: M2DProtocol.nalStartCode)
                configData.append(pps)

                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                encodedFrameHandler?(configData, pts, false, true)
                hasSentConfig = true
            }
        }

        // Convert AVCC to Annex B format
        guard let nalData = convertToAnnexB(sampleBuffer: sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encodedFrameHandler?(nalData, pts, isKeyframe, false)
    }

    /// Extract SPS and PPS from format description
    private func extractParameterSets(from formatDesc: CMFormatDescription) -> (sps: Data, pps: Data)? {
        var spsSize = 0
        var spsCount = 0
        var ppsSize = 0
        var ppsCount = 0

        // Get SPS
        var spsPointer: UnsafePointer<UInt8>?
        var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: nil
        )
        guard status == noErr, let sps = spsPointer else { return nil }

        // Get PPS
        var ppsPointer: UnsafePointer<UInt8>?
        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: &ppsCount,
            nalUnitHeaderLengthOut: nil
        )
        guard status == noErr, let pps = ppsPointer else { return nil }

        return (
            sps: Data(bytes: sps, count: spsSize),
            pps: Data(bytes: pps, count: ppsSize)
        )
    }

    /// Convert AVCC format (length-prefixed) to Annex B format (start code prefixed)
    private func convertToAnnexB(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let pointer = dataPointer else { return nil }

        var result = Data()
        var offset = 0

        // NAL unit length is 4 bytes (AVCC format)
        let nalLengthSize = 4

        while offset < totalLength {
            // Read NAL unit length (big-endian)
            var nalLength: UInt32 = 0
            memcpy(&nalLength, pointer.advanced(by: offset), nalLengthSize)
            nalLength = nalLength.bigEndian
            offset += nalLengthSize

            guard offset + Int(nalLength) <= totalLength else { break }

            // Append start code
            result.append(contentsOf: M2DProtocol.nalStartCode)

            // Append NAL unit data
            result.append(Data(bytes: pointer.advanced(by: offset), count: Int(nalLength)))
            offset += Int(nalLength)
        }

        return result
    }
}

// MARK: - Encoder Errors
enum EncoderError: LocalizedError {
    case sessionCreationFailed(OSStatus)
    case configurationFailed(OSStatus)
    case encodingFailed(OSStatus)
    case flushFailed(OSStatus)
    case notConfigured
    case invalidInput

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let status):
            return "Failed to create compression session: \(status)"
        case .configurationFailed(let status):
            return "Failed to configure encoder: \(status)"
        case .encodingFailed(let status):
            return "Encoding failed: \(status)"
        case .flushFailed(let status):
            return "Flush failed: \(status)"
        case .notConfigured:
            return "Encoder not configured"
        case .invalidInput:
            return "Invalid input sample buffer"
        }
    }
}
