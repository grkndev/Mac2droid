import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

// MARK: - Screen Capture Manager
@MainActor
final class ScreenCaptureManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published private(set) var isCapturing = false
    @Published private(set) var availableDisplays: [SCDisplay] = []
    @Published private(set) var captureError: Error?

    // MARK: - Private Properties
    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private var frameHandler: ((CMSampleBuffer) -> Void)?

    // MARK: - Public Methods

    /// Request screen recording permission
    func requestPermission() async throws -> Bool {
        do {
            // This will trigger permission dialog if not already granted
            _ = try await SCShareableContent.current
            return true
        } catch {
            if let scError = error as? SCStreamError {
                switch scError.code {
                case .userDeclined:
                    throw CaptureError.permissionDenied
                default:
                    throw CaptureError.permissionDenied
                }
            }
            throw error
        }
    }

    /// Refresh list of available displays
    func refreshDisplays() async throws {
        let content = try await SCShareableContent.current
        availableDisplays = content.displays
    }

    /// Get display info for all available displays
    func getDisplayInfos() async throws -> [DisplayInfo] {
        try await refreshDisplays()
        return availableDisplays.map { display in
            DisplayInfo(
                id: display.displayID,
                name: "Display \(display.displayID)",
                width: display.width,
                height: display.height,
                isMain: display.displayID == CGMainDisplayID()
            )
        }
    }

    /// Start capturing specified display
    /// - Parameters:
    ///   - config: Stream configuration
    ///   - frameHandler: Callback for each captured frame
    func startCapture(
        config: StreamConfig,
        frameHandler: @escaping (CMSampleBuffer) -> Void
    ) async throws {
        guard !isCapturing else {
            throw CaptureError.alreadyCapturing
        }

        self.frameHandler = frameHandler

        // Get shareable content
        let content = try await SCShareableContent.current

        // Find the target display
        guard let display = content.displays.first(where: { $0.displayID == config.displayID }) else {
            throw CaptureError.displayNotFound
        }

        // Create content filter (capture entire display, exclude nothing)
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Configure stream
        let streamConfig = SCStreamConfiguration()

        // Resolution
        streamConfig.width = config.captureWidth
        streamConfig.height = config.captureHeight

        // Frame rate
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.frameRate))

        // Pixel format - NV12 for efficient hardware encoding
        streamConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        // Cursor visibility
        streamConfig.showsCursor = config.showCursor

        // Quality settings
        streamConfig.scalesToFit = true

        // Color space
        streamConfig.colorSpaceName = CGColorSpace.sRGB

        // Queue depth for low latency
        streamConfig.queueDepth = 3

        // Create stream output handler
        let output = CaptureStreamOutput()
        output.frameHandler = { [weak self] sampleBuffer in
            self?.frameHandler?(sampleBuffer)
        }
        self.streamOutput = output

        // Create and configure stream
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        self.stream = stream

        // Add stream output
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

        // Start capturing
        try await stream.startCapture()
        isCapturing = true

        print("[ScreenCapture] Started capturing display \(config.displayID) at \(config.captureWidth)x\(config.captureHeight) @ \(config.frameRate)fps")
    }

    /// Stop capturing
    func stopCapture() async throws {
        guard isCapturing, let stream = stream else {
            return
        }

        try await stream.stopCapture()
        self.stream = nil
        self.streamOutput = nil
        self.frameHandler = nil
        isCapturing = false

        print("[ScreenCapture] Stopped capturing")
    }
}

// MARK: - SCStreamDelegate
extension ScreenCaptureManager: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[ScreenCapture] Stream stopped with error: \(error)")
        Task { @MainActor in
            self.isCapturing = false
            self.captureError = error
        }
    }
}

// MARK: - Stream Output Handler
private class CaptureStreamOutput: NSObject, SCStreamOutput {
    var frameHandler: ((CMSampleBuffer) -> Void)?

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }

        // Validate sample buffer
        guard sampleBuffer.isValid else {
            print("[ScreenCapture] Invalid sample buffer received")
            return
        }

        // Check for display status
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusValue),
              status == .complete else {
            return
        }

        // Deliver frame
        frameHandler?(sampleBuffer)
    }
}

// MARK: - Capture Errors
enum CaptureError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case alreadyCapturing
    case notCapturing
    case streamFailed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen recording permission denied. Please enable in System Settings > Privacy & Security > Screen Recording."
        case .displayNotFound:
            return "The specified display was not found."
        case .alreadyCapturing:
            return "Screen capture is already in progress."
        case .notCapturing:
            return "No capture in progress."
        case .streamFailed(let error):
            return "Stream failed: \(error.localizedDescription)"
        }
    }
}
