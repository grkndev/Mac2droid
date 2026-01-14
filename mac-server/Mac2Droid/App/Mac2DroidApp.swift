import SwiftUI
import ScreenCaptureKit
import Combine

// MARK: - Stream Mode
enum StreamMode: String, CaseIterable {
    case mirror = "Repeat"      // Mirror existing display
    case extend = "Expand"    // Extend with virtual display

    var description: String {
        switch self {
        case .mirror:
            return "Mirror the current screen to Android"
        case .extend:
            return "Use Android as a second monitor"
        }
    }

    var icon: String {
        switch self {
        case .mirror:
            return "rectangle.on.rectangle"
        case .extend:
            return "rectangle.split.2x1"
        }
    }
}

// MARK: - Android Device
struct AndroidDevice: Equatable {
    let serialNumber: String
    let model: String
    let manufacturer: String
    let screenWidth: Int
    let screenHeight: Int
    let density: Int
    let androidVersion: String

    var displayName: String {
        if manufacturer.lowercased() == "samsung" {
            return "\(manufacturer) \(model)"
        }
        return model.isEmpty ? serialNumber : model
    }

    var resolution: String {
        "\(screenWidth)x\(screenHeight)"
    }

    var aspectRatio: Double {
        guard screenHeight > 0 else { return 0 }
        return Double(screenWidth) / Double(screenHeight)
    }

    /// Suggest best quality based on device resolution
    var suggestedQuality: M2DQuality {
        let maxDimension = max(screenWidth, screenHeight)
        if maxDimension >= 1920 {
            return .quality
        } else if maxDimension >= 1080 {
            return .balanced
        } else {
            return .performance
        }
    }
}

// MARK: - ADB Manager
@MainActor
final class ADBManager: ObservableObject {
    static let shared = ADBManager()

    @Published private(set) var connectedDevice: AndroidDevice?
    @Published private(set) var isMonitoring = false
    @Published private(set) var lastError: String?

    private var monitorTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public Methods

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        monitorTask = Task {
            while !Task.isCancelled {
                await refreshDevice()
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        isMonitoring = false
    }

    func refreshDevice() async {
        lastError = nil

        // Check if any device is connected
        guard let serial = await getConnectedDeviceSerial() else {
            connectedDevice = nil
            return
        }

        // If same device, skip refresh
        if connectedDevice?.serialNumber == serial {
            return
        }

        // Fetch device info
        do {
            let device = try await fetchDeviceInfo(serial: serial)
            connectedDevice = device
            print("[ADB] Device connected: \(device.displayName) (\(device.resolution))")
        } catch {
            lastError = error.localizedDescription
            connectedDevice = nil
            print("[ADB] Error fetching device info: \(error)")
        }
    }

    // MARK: - ADB Commands

    func runCommand(_ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["adb"] + arguments
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(throwing: ADBError.commandFailed(output))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Private Methods

    private func getConnectedDeviceSerial() async -> String? {
        do {
            let output = try await runCommand(["devices"])
            let lines = output.components(separatedBy: "\n")

            for line in lines {
                let parts = line.components(separatedBy: "\t")
                if parts.count >= 2 && parts[1] == "device" {
                    return parts[0]
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    private func fetchDeviceInfo(serial: String) async throws -> AndroidDevice {
        async let modelResult = runCommand(["-s", serial, "shell", "getprop", "ro.product.model"])
        async let manufacturerResult = runCommand(["-s", serial, "shell", "getprop", "ro.product.manufacturer"])
        async let versionResult = runCommand(["-s", serial, "shell", "getprop", "ro.build.version.release"])
        async let sizeResult = runCommand(["-s", serial, "shell", "wm", "size"])
        async let densityResult = runCommand(["-s", serial, "shell", "wm", "density"])

        let model = (try? await modelResult) ?? "Unknown"
        let manufacturer = (try? await manufacturerResult) ?? "Unknown"
        let version = (try? await versionResult) ?? "Unknown"
        let sizeOutput = (try? await sizeResult) ?? ""
        let densityOutput = (try? await densityResult) ?? ""

        // Parse screen size: "Physical size: 1200x1920"
        var width = 0, height = 0
        if let match = sizeOutput.range(of: #"(\d+)x(\d+)"#, options: .regularExpression) {
            let sizeStr = String(sizeOutput[match])
            let parts = sizeStr.components(separatedBy: "x")
            if parts.count == 2 {
                width = Int(parts[0]) ?? 0
                height = Int(parts[1]) ?? 0
            }
        }

        // Parse density: "Physical density: 240"
        var density = 0
        if let match = densityOutput.range(of: #"(\d+)"#, options: .regularExpression) {
            density = Int(densityOutput[match]) ?? 0
        }

        return AndroidDevice(
            serialNumber: serial,
            model: model,
            manufacturer: manufacturer,
            screenWidth: width,
            screenHeight: height,
            density: density,
            androidVersion: version
        )
    }
}

// MARK: - ADB Error
enum ADBError: LocalizedError {
    case commandFailed(String)
    case noDevice

    var errorDescription: String? {
        switch self {
        case .commandFailed(let output):
            return output.isEmpty ? "ADB command failed" : output
        case .noDevice:
            return "No Android device connected"
        }
    }
}

// MARK: - Main App
@main
struct Mac2DroidApp: App {
    @StateObject private var appState = AppState()

    /// Menu bar icon based on app state
    private var menuBarIcon: String {
        if appState.isStreaming {
            return "display.2"
        } else if appState.hasVirtualDisplay {
            return "rectangle.on.rectangle"
        } else {
            return "display"
        }
    }

    var body: some Scene {
        // Menu bar app
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView(appState: appState)
        }
    }
}

// MARK: - App State
@MainActor
final class AppState: ObservableObject {
    // MARK: - Published Properties
    @Published var selectedDisplay: SCDisplay?
    @Published var selectedQuality: M2DQuality = .balanced
    @Published var showCursor = true
    @Published var streamMode: StreamMode = .mirror
    @Published var autoAdjustQuality = true

    // ADB Settings
    @Published var adbPort: String = "5555"
    @Published private(set) var isAdbActive = false
    @Published private(set) var adbError: String?

    @Published private(set) var availableDisplays: [SCDisplay] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var connectionStatus = "Ready"
    @Published private(set) var stats = StreamStats()

    // Virtual display state
    @Published private(set) var hasVirtualDisplay = false
    @Published private(set) var virtualDisplayID: CGDirectDisplayID?
    @Published private(set) var virtualDisplayError: String?

    // Android device state
    let adbManager = ADBManager.shared
    var connectedDevice: AndroidDevice? { adbManager.connectedDevice }

    // MARK: - Private Properties
    private let pipeline = StreamPipeline()
    private var deviceObserver: AnyCancellable?
    private var lastKnownDeviceSerial: String?

    // MARK: - Initialization
    init() {
        Task {
            await loadDisplays()
        }

        // Start device monitoring
        adbManager.startMonitoring()

        // Observe device changes for auto quality adjustment
        deviceObserver = adbManager.$connectedDevice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] device in
                self?.handleDeviceChange(device)
            }

        // Register for app termination to cleanup
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adbManager.stopMonitoring()
                self?.destroyVirtualDisplay()
            }
        }
    }

    // MARK: - Device Handling

    private func handleDeviceChange(_ device: AndroidDevice?) {
        let previousSerial = lastKnownDeviceSerial
        lastKnownDeviceSerial = device?.serialNumber

        // Device disconnected
        guard let device = device else {
            if isStreaming {
                connectionStatus = "Device disconnected - waiting for reconnect..."
                print("[AppState] Device disconnected during stream")
            } else {
                connectionStatus = "No device"
            }
            return
        }

        // Device connected/reconnected
        let wasDisconnected = previousSerial == nil
        let isNewDevice = previousSerial != nil && previousSerial != device.serialNumber

        if isStreaming && (wasDisconnected || isNewDevice) {
            connectionStatus = "Reconnecting..."
            print("[AppState] Device reconnected during stream, re-establishing connection...")
            Task {
                // Small delay to let ADB stabilize
                try? await Task.sleep(nanoseconds: 500_000_000)
                // Re-establish ADB reverse
                await startAdb()
                if isAdbActive {
                    // Relaunch Android app
                    await launchAndroidApp()
                    connectionStatus = "Waiting for connection..."
                } else {
                    connectionStatus = "ADB failed - try again"
                }
            }
        } else if !isStreaming {
            connectionStatus = "Ready"
            // Auto-adjust quality based on device resolution
            if autoAdjustQuality {
                selectedQuality = device.suggestedQuality
                print("[AppState] Auto-adjusted quality to \(selectedQuality) for \(device.resolution)")
            }
        }

        objectWillChange.send()
    }

    // MARK: - Public Methods

    func loadDisplays() async {
        do {
            availableDisplays = try await pipeline.getAvailableDisplays()
            if selectedDisplay == nil {
                selectedDisplay = availableDisplays.first
            }
        } catch {
            print("[AppState] Failed to load displays: \(error)")
        }
    }

    func toggleStreaming() async {
        if isStreaming {
            await stopStreaming()
        } else {
            await startStreaming()
        }
    }

    func startStreaming() async {
        // For extend mode, ensure virtual display exists
        if streamMode == .extend {
            connectionStatus = "Preparing virtual display..."
            await ensureVirtualDisplay(
                width: selectedQuality.width,
                height: selectedQuality.height
            )

            // Check if virtual display is ready
            if !hasVirtualDisplay {
                connectionStatus = virtualDisplayError ?? "Failed to create virtual display"
                return
            }
        }

        guard let display = selectedDisplay else {
            connectionStatus = "No display selected"
            return
        }

        // Start ADB reverse
        connectionStatus = "Starting ADB..."
        await startAdb()
        if !isAdbActive {
            connectionStatus = adbError ?? "ADB failed"
            return
        }

        var config = StreamConfig(displayID: display.displayID, quality: selectedQuality)
        config.showCursor = showCursor
        config.serverPort = UInt16(adbPort) ?? M2DProtocol.defaultPort

        do {
            connectionStatus = "Starting..."
            try await pipeline.start(config: config)
            isStreaming = true
            connectionStatus = "Launching app..."

            // Launch Android app with auto-connect
            await launchAndroidApp()

            connectionStatus = "Waiting for connection..."

            // Start monitoring
            startMonitoring()
        } catch {
            connectionStatus = "Error: \(error.localizedDescription)"
            print("[AppState] Start error: \(error)")
            // Stop ADB if stream failed
            await stopAdb()
        }
    }

    /// Launch Android app with auto-connect intent
    func launchAndroidApp() async {
        let port = adbPort.isEmpty ? "5555" : adbPort

        do {
            // Launch app with auto_connect extra
            let result = try await adbManager.runCommand([
                "shell", "am", "start",
                "-n", "com.mac2droid/.MainActivity",
                "--es", "auto_connect", "true",
                "--es", "port", port
            ])
            print("[ADB] Launch app result: \(result)")
        } catch {
            print("[ADB] Failed to launch app: \(error)")
            // Non-fatal - user can manually open the app
        }
    }

    func stopStreaming() async {
        await pipeline.stop()
        isStreaming = false
        connectionStatus = "Ready"
        stopMonitoring()

        // Stop ADB reverse
        await stopAdb()

        // Virtual display is kept alive for reuse (CGVirtualDisplay limitation)
        // It will be cleaned up when app terminates
    }

    // MARK: - ADB Methods

    func startAdb() async {
        adbError = nil
        let port = adbPort.isEmpty ? "5555" : adbPort

        // Check if device is connected
        guard connectedDevice != nil else {
            adbError = "No Android device connected"
            isAdbActive = false
            return
        }

        // First remove any existing forward (ignore errors if not exists)
        do {
            let removeResult = try await adbManager.runCommand(["reverse", "--remove", "tcp:\(port)"])
            print("[ADB] Remove result: \(removeResult)")
        } catch {
            // Ignore - reverse might not exist yet
            print("[ADB] No existing reverse to remove (this is OK)")
        }

        // Start reverse port forwarding
        do {
            let result = try await adbManager.runCommand(["reverse", "tcp:\(port)", "tcp:\(port)"])
            print("[ADB] Reverse result: \(result)")

            isAdbActive = true
            print("[ADB] Started reverse on port \(port)")
        } catch {
            adbError = "ADB error: \(error.localizedDescription)"
            isAdbActive = false
            print("[ADB] Error: \(error)")
        }
    }

    func stopAdb() async {
        let port = adbPort.isEmpty ? "5555" : adbPort

        do {
            let result = try await adbManager.runCommand(["reverse", "--remove", "tcp:\(port)"])
            print("[ADB] Stop result: \(result)")
        } catch {
            print("[ADB] Stop error: \(error)")
        }

        isAdbActive = false
    }

    // MARK: - Virtual Display Methods

    /// Check if virtual display feature is available (macOS 14+)
    var canCreateVirtualDisplay: Bool {
        isVirtualDisplayAvailable()
    }

    /// Get or create virtual display for streaming
    func ensureVirtualDisplay(width: Int = 1920, height: Int = 1080) async {
        virtualDisplayError = nil

        guard canCreateVirtualDisplay else {
            virtualDisplayError = "Virtual display requires macOS 14.0 or later"
            return
        }

        if #available(macOS 14.0, *) {
            let manager = VirtualDisplayManager.shared

            // Check if display already exists
            if manager.hasDisplay, let existingID = manager.displayID {
                virtualDisplayID = existingID
                hasVirtualDisplay = true
                print("[AppState] Reusing existing virtual display: \(existingID)")

                // Make sure display is selected
                await loadDisplays()
                if let virtualDisplay = availableDisplays.first(where: { $0.displayID == existingID }) {
                    selectedDisplay = virtualDisplay
                }
                return
            }

            // Create new display
            do {
                let config = VirtualDisplayManager.DisplayConfig(width: width, height: height)
                let displayID = try manager.getOrCreateDisplay(config: config)

                virtualDisplayID = displayID
                hasVirtualDisplay = true
                virtualDisplayError = nil

                // Wait for display to register
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 second

                // Refresh and select display
                await loadDisplays()

                if let virtualDisplay = availableDisplays.first(where: { $0.displayID == displayID }) {
                    selectedDisplay = virtualDisplay
                    print("[AppState] Virtual display ready: \(displayID)")
                } else if let nonMainDisplay = availableDisplays.first(where: { $0.displayID != CGMainDisplayID() }) {
                    selectedDisplay = nonMainDisplay
                }

            } catch {
                virtualDisplayError = error.localizedDescription
                print("[AppState] Failed to create virtual display: \(error)")
            }
        }
    }

    /// Note: Virtual display persists until app quits (CGVirtualDisplay limitation)
    func destroyVirtualDisplay() {
        // CGVirtualDisplay cannot be destroyed at runtime
        // It only gets cleaned up when the app terminates
        // So we just update our state flags
        virtualDisplayID = nil
        hasVirtualDisplay = false

        // Select main display
        Task {
            await loadDisplays()
            selectedDisplay = availableDisplays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? availableDisplays.first
        }
    }

    // MARK: - Private Methods

    private var monitorTimer: Timer?

    private func startMonitoring() {
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatus()
            }
        }
    }

    private func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        stats = StreamStats()
    }

    private func updateStatus() {
        connectionStatus = pipeline.connectionState.statusText
        stats.fps = pipeline.currentFPS
        stats.bitrate = pipeline.currentBitrate
    }
}

// MARK: - Stream Stats
struct StreamStats {
    var fps: Int = 0
    var bitrate: Int = 0

    var bitrateText: String {
        let mbps = Double(bitrate) / 1_000_000.0
        return String(format: "%.1f Mbps", mbps)
    }
}

// MARK: - Menu Bar View
struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var isSettingsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with device info
            if let device = appState.connectedDevice {
                DeviceInfoCard(device: device)
            } else {
                // No device connected
                HStack(spacing: 8) {
                    Image(systemName: "iphone.slash")
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No Device")
                            .font(.headline)
                        Text("Connect Android via USB")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            // Status
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(appState.connectionStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Settings when not streaming
            if !appState.isStreaming {
                // Stream Mode picker (Yinele / Genişlet)
                Text("Mode")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("", selection: $appState.streamMode) {
                    ForEach(StreamMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: appState.streamMode) { oldValue, newValue in
                    // Clean up virtual display when switching to mirror mode
                    if newValue == .mirror && appState.hasVirtualDisplay {
                        appState.destroyVirtualDisplay()
                    }
                }

                Text(appState.streamMode.description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                // Display picker (only for Mirror mode)
                if appState.streamMode == .mirror {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Display")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("", selection: $appState.selectedDisplay) {
                            ForEach(appState.availableDisplays, id: \.displayID) { display in
                                Text(displayName(for: display))
                                    .tag(display as SCDisplay?)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
                }

                // Quality picker
                Text("Quality")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("", selection: $appState.selectedQuality) {
                    Text("Performance (720p 30fps)").tag(M2DQuality.performance)
                    Text("Balanced (1080p 30fps)").tag(M2DQuality.balanced)
                    Text("Quality (1080p 60fps)").tag(M2DQuality.quality)
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Toggle("Show cursor", isOn: $appState.showCursor)
                    .toggleStyle(.checkbox)

                // Collapsible Settings Section
                CollapsibleSection(title: "Settings", isExpanded: $isSettingsExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        // ADB Port
                        HStack {
                            Text("ADB Port:")
                                .font(.caption)
                            TextField("5555", text: $appState.adbPort)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                        }

                        // Auto quality toggle
                        Toggle("Auto quality", isOn: $appState.autoAdjustQuality)
                            .font(.caption)

                        // ADB Status
                        HStack {
                            Circle()
                                .fill(appState.isAdbActive ? Color.green : Color.gray)
                                .frame(width: 6, height: 6)
                            Text(appState.isAdbActive ? "ADB Active" : "ADB Inactive")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if let error = appState.adbError {
                            Text(error)
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.top, 4)
                }

                // Virtual display status (for Extend mode)
                if appState.streamMode == .extend {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()

                        if appState.hasVirtualDisplay {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Virtual display ready")
                                    .font(.caption)
                                Spacer()
                            }
                        } else if let error = appState.virtualDisplayError {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            HStack {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.blue)
                                Text("Virtual display will be created when streaming starts")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
                }
            }

            // Stats when streaming
            if appState.isStreaming {
                HStack {
                    Label("\(appState.stats.fps) FPS", systemImage: "speedometer")
                    Spacer()
                    Label(appState.stats.bitrateText, systemImage: "arrow.up")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Divider()

            // Action button
            MenuRowButton(
                title: appState.isStreaming ? "Stop Streaming" : "Start Streaming",
                icon: appState.isStreaming ? "stop.fill" : "play.fill",
                color: appState.isStreaming ? .red : .accentColor,
                disabled: !appState.isStreaming && appState.connectedDevice == nil
            ) {
                Task {
                    if appState.isStreaming {
                        await appState.stopStreaming()
                    } else {
                        await appState.startStreaming()
                    }
                }
            }

            Divider()

            // Footer
            MenuRowButton(title: "Quit", shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
        .frame(width: 260)
        .animation(.easeInOut(duration: 0.2), value: appState.streamMode)
        .animation(.easeInOut(duration: 0.2), value: appState.isStreaming)
        .animation(.easeInOut(duration: 0.2), value: isSettingsExpanded)
        .animation(.easeInOut(duration: 0.3), value: appState.connectedDevice)
        .task {
            await appState.loadDisplays()
        }
    }

    private var statusColor: Color {
        if appState.isStreaming {
            return .green
        }
        if appState.connectedDevice == nil {
            return .red
        }
        return appState.connectionStatus == "Ready" ? .gray : .orange
    }

    private func displayName(for display: SCDisplay) -> String {
        let isMain = display.displayID == CGMainDisplayID()
        let suffix = isMain ? " (Main)" : ""
        return "\(display.width)x\(display.height)\(suffix)"
    }
}

// MARK: - Device Info Card
struct DeviceInfoCard: View {
    let device: AndroidDevice

    var body: some View {
        HStack(spacing: 10) {
            // Device icon
            Image(systemName: deviceIcon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)

            // Device info
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(device.resolution, systemImage: "rectangle.dashed")
                    Label("Android \(device.androidVersion)", systemImage: "apple.logo")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var deviceIcon: String {
        // Use tablet icon for larger screens, phone for smaller
        if device.screenWidth > 1000 || device.screenHeight > 1000 {
            return "ipad"
        }
        return "iphone"
    }
}

// MARK: - Menu Row Button
struct MenuRowButton: View {
    let title: String
    var icon: String? = nil
    var shortcut: String? = nil
    var color: Color = .accentColor
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    private var effectiveHovered: Bool {
        isHovered && !disabled
    }

    var body: some View {
        Button(action: action) {
            HStack {
                if let icon = icon {
                    Image(systemName: icon)
                        .frame(width: 16)
                }
                Text(title)
                Spacer()
                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.caption)
                        .foregroundColor(effectiveHovered ? .white.opacity(0.7) : .secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(effectiveHovered ? color.opacity(0.85) : Color.clear)
            )
            .foregroundColor(disabled ? .secondary : (effectiveHovered ? .white : .primary))
            .opacity(disabled ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Collapsible Section
struct CollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header - clickable row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? Color.primary.opacity(0.1) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovered = hovering
            }

            // Content
            if isExpanded {
                content()
                    .padding(.leading, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Port") {
                    Text("\(M2DProtocol.defaultPort)")
                        .foregroundColor(.secondary)
                }
            }

            Section("Encoding") {
                Picker("Default Quality", selection: $appState.selectedQuality) {
                    Text("Performance").tag(M2DQuality.performance)
                    Text("Balanced").tag(M2DQuality.balanced)
                    Text("Quality").tag(M2DQuality.quality)
                }

                Toggle("Show cursor in stream", isOn: $appState.showCursor)
            }

            Section("About") {
                LabeledContent("Version") {
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 300)
    }
}
