import Foundation
import CoreMedia
import ScreenCaptureKit

// MARK: - Frame Packetizer
/// Packages encoded video frames with protocol headers for transmission
final class FramePacketizer {
    // MARK: - Properties
    private let server: StreamServer
    private var frameCount: UInt64 = 0
    private var lastKeyframeTime: CFAbsoluteTime = 0
    private let keyframeInterval: CFTimeInterval = 2.0  // Force keyframe every 2 seconds

    // Statistics
    private(set) var totalFramesSent: UInt64 = 0
    private(set) var totalBytesSent: UInt64 = 0

    // MARK: - Initialization

    init(server: StreamServer) {
        self.server = server
    }

    // MARK: - Public Methods

    /// Send encoded frame data
    /// - Parameters:
    ///   - data: Encoded NAL data (Annex B format)
    ///   - pts: Presentation timestamp
    ///   - isKeyframe: Whether this is a keyframe
    ///   - isConfig: Whether this contains codec configuration (SPS/PPS)
    func sendFrame(data: Data, pts: CMTime, isKeyframe: Bool, isConfig: Bool) {
        guard server.isConnected else { return }

        // Convert PTS to microseconds
        let ptsUs = UInt64(CMTimeGetSeconds(pts) * 1_000_000)

        // Create frame header
        let header = M2DFrameHeader.videoFrame(
            pts: ptsUs,
            payloadSize: data.count,
            isKeyframe: isKeyframe,
            isConfig: isConfig
        )

        // Send to server
        server.sendFrame(header: header, payload: data)

        // Update statistics
        frameCount += 1
        totalFramesSent += 1
        totalBytesSent += UInt64(M2DProtocol.frameHeaderSize + data.count)

        if isKeyframe {
            lastKeyframeTime = CFAbsoluteTimeGetCurrent()
        }
    }

    /// Check if a keyframe should be forced
    var shouldForceKeyframe: Bool {
        let elapsed = CFAbsoluteTimeGetCurrent() - lastKeyframeTime
        return elapsed >= keyframeInterval
    }

    /// Reset statistics
    func resetStats() {
        frameCount = 0
        totalFramesSent = 0
        totalBytesSent = 0
        lastKeyframeTime = CFAbsoluteTimeGetCurrent()
    }

    /// Get current bitrate in bits per second
    func getCurrentBitrate(overSeconds: TimeInterval = 1.0) -> Int {
        // This would need a sliding window implementation for accuracy
        // For now, return server's bytes sent
        return Int(Double(server.bytesSent) * 8.0 / overSeconds)
    }
}

// MARK: - Stream Pipeline
/// Coordinates capture, encoding, and streaming
@MainActor
final class StreamPipeline: ObservableObject {
    // MARK: - Published Properties
    @Published private(set) var isStreaming = false
    @Published private(set) var currentFPS: Int = 0
    @Published private(set) var currentBitrate: Int = 0
    @Published private(set) var error: Error?

    // MARK: - Components
    private let captureManager = ScreenCaptureManager()
    private let encoder = VideoEncoder()
    private let server = StreamServer()
    private var packetizer: FramePacketizer?

    // MARK: - Configuration
    private var config: StreamConfig?

    // FPS tracking
    private var frameTimestamps: [CFAbsoluteTime] = []
    private var fpsUpdateTimer: Timer?

    // MARK: - Public Properties

    var connectionState: ConnectionState {
        switch server.state {
        case .idle:
            return .idle
        case .starting, .listening:
            return .listening
        case .connected(let client):
            return isStreaming ? .streaming(fps: currentFPS, bitrate: currentBitrate) : .connected(clientInfo: client)
        case .error(let err):
            return .error(err.localizedDescription)
        }
    }

    func getAvailableDisplays() async throws -> [SCDisplay] {
        try await captureManager.refreshDisplays()
        return captureManager.availableDisplays
    }

    // MARK: - Public Methods

    /// Start the streaming pipeline
    func start(config: StreamConfig) async throws {
        guard !isStreaming else { return }

        self.config = config
        self.error = nil

        // Request screen recording permission
        _ = try await captureManager.requestPermission()

        // Start server
        try server.start(port: config.serverPort)

        // Wait for client connection
        server.onClientConnected = { [weak self] in
            Task { @MainActor in
                try await self?.startStreaming()
            }
        }

        server.onClientDisconnected = { [weak self] in
            Task { @MainActor in
                await self?.stopStreaming()
            }
        }

        print("[StreamPipeline] Started, waiting for client...")
    }

    /// Stop the streaming pipeline
    func stop() async {
        await stopStreaming()
        server.stop()
        print("[StreamPipeline] Stopped")
    }

    // MARK: - Private Methods

    private func startStreaming() async throws {
        guard let config = config else { return }

        // Initialize packetizer
        packetizer = FramePacketizer(server: server)

        // Configure encoder
        let encoderConfig = VideoEncoder.EncoderConfig.from(config)
        try encoder.configure(config: encoderConfig) { [weak self] data, pts, isKeyframe, isConfig in
            guard let self = self else { return }
            Task { @MainActor in
                self.packetizer?.sendFrame(data: data, pts: pts, isKeyframe: isKeyframe, isConfig: isConfig)
                self.recordFrame()
            }
        }

        // Send handshake to client
        try server.sendHandshake(config: config)

        // Start capturing
        try await captureManager.startCapture(config: config) { [weak self] sampleBuffer in
            guard let self = self else { return }
            do {
                let forceKeyframe = self.packetizer?.shouldForceKeyframe ?? false
                try self.encoder.encode(sampleBuffer: sampleBuffer, forceKeyFrame: forceKeyframe)
            } catch {
                print("[StreamPipeline] Encoding error: \(error)")
            }
        }

        isStreaming = true
        startFPSTimer()

        print("[StreamPipeline] Streaming started")
    }

    private func stopStreaming() async {
        stopFPSTimer()

        // Stop capture
        try? await captureManager.stopCapture()

        // Flush encoder
        try? encoder.flush()

        // Send end of stream
        server.sendEndOfStream()

        // Cleanup
        encoder.invalidate()
        packetizer = nil
        isStreaming = false

        print("[StreamPipeline] Streaming stopped")
    }

    private func recordFrame() {
        let now = CFAbsoluteTimeGetCurrent()
        frameTimestamps.append(now)

        // Keep only last 2 seconds of timestamps
        let cutoff = now - 2.0
        frameTimestamps.removeAll { $0 < cutoff }
    }

    private func startFPSTimer() {
        fpsUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStats()
            }
        }
    }

    private func stopFPSTimer() {
        fpsUpdateTimer?.invalidate()
        fpsUpdateTimer = nil
        currentFPS = 0
        currentBitrate = 0
    }

    private func updateStats() {
        // Calculate FPS from last second of frames
        let now = CFAbsoluteTimeGetCurrent()
        let recentFrames = frameTimestamps.filter { $0 > now - 1.0 }
        currentFPS = recentFrames.count

        // Calculate bitrate
        currentBitrate = packetizer?.getCurrentBitrate() ?? 0
    }
}
