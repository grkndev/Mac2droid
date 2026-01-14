import SwiftUI
import ScreenCaptureKit

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

    // MARK: - Private Properties
    private let pipeline = StreamPipeline()

    // MARK: - Initialization
    init() {
        Task {
            await loadDisplays()
        }

        // Register for app termination to cleanup virtual display
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.destroyVirtualDisplay()
            }
        }
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

        // First remove any existing forward (ignore errors if not exists)
        do {
            let removeResult = try await runCommand("adb", arguments: ["reverse", "--remove", "tcp:\(port)"])
            print("[ADB] Remove result: \(removeResult)")
        } catch {
            // Ignore - reverse might not exist yet
            print("[ADB] No existing reverse to remove (this is OK)")
        }

        // Start reverse port forwarding
        do {
            let result = try await runCommand("adb", arguments: ["reverse", "tcp:\(port)", "tcp:\(port)"])
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
            let result = try await runCommand("adb", arguments: ["reverse", "--remove", "tcp:\(port)"])
            print("[ADB] Stop result: \(result)")
        } catch {
            print("[ADB] Stop error: \(error)")
        }

        isAdbActive = false
    }

    private func runCommand(_ command: String, arguments: [String]) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [command] + arguments
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(throwing: NSError(
                            domain: "ADB",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "Command failed" : output]
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
            // Header
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(appState.connectionStatus)
                    .font(.headline)
            }
            .padding(.bottom, 4)

            Divider()

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
                color: appState.isStreaming ? .red : .accentColor
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
        .task {
            await appState.loadDisplays()
        }
    }

    private var statusColor: Color {
        if appState.isStreaming {
            return .green
        }
        return appState.connectionStatus == "Ready" ? .gray : .orange
    }

    private func displayName(for display: SCDisplay) -> String {
        let isMain = display.displayID == CGMainDisplayID()
        let suffix = isMain ? " (Main)" : ""
        return "\(display.width)x\(display.height)\(suffix)"
    }
}

// MARK: - Menu Row Button
struct MenuRowButton: View {
    let title: String
    var icon: String? = nil
    var shortcut: String? = nil
    var color: Color = .accentColor
    let action: () -> Void

    @State private var isHovered = false

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
                        .foregroundColor(isHovered ? .white.opacity(0.7) : .secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? color.opacity(0.85) : Color.clear)
            )
            .foregroundColor(isHovered ? .white : .primary)
        }
        .buttonStyle(.plain)
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
