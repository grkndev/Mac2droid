import SwiftUI
import ScreenCaptureKit

// MARK: - Stream Mode
enum StreamMode: String, CaseIterable {
    case mirror = "Yinele"      // Mirror existing display
    case extend = "Genişlet"    // Extend with virtual display

    var description: String {
        switch self {
        case .mirror:
            return "Mevcut ekranı Android'e yansıt"
        case .extend:
            return "Android'i ikinci monitör olarak kullan"
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
    private var virtualDisplayManager: Any?  // Type-erased for macOS 14+ compatibility

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
        // For extend mode, create virtual display first
        if streamMode == .extend && !hasVirtualDisplay {
            connectionStatus = "Creating virtual display..."
            await createVirtualDisplay(
                width: selectedQuality.width,
                height: selectedQuality.height
            )

            // Check if virtual display was created
            if !hasVirtualDisplay {
                connectionStatus = virtualDisplayError ?? "Failed to create virtual display"
                return
            }
        }

        guard let display = selectedDisplay else {
            connectionStatus = "No display selected"
            return
        }

        var config = StreamConfig(displayID: display.displayID, quality: selectedQuality)
        config.showCursor = showCursor

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
        }
    }

    func stopStreaming() async {
        await pipeline.stop()
        isStreaming = false
        connectionStatus = "Ready"
        stopMonitoring()

        // Clean up virtual display when stopping extend mode
        if streamMode == .extend && hasVirtualDisplay {
            destroyVirtualDisplay()
        }
    }

    // MARK: - Virtual Display Methods

    /// Check if virtual display feature is available (macOS 14+)
    var canCreateVirtualDisplay: Bool {
        isVirtualDisplayAvailable()
    }

    /// Create a virtual display for use as a second monitor
    func createVirtualDisplay(width: Int = 1920, height: Int = 1080) async {
        virtualDisplayError = nil

        guard canCreateVirtualDisplay else {
            virtualDisplayError = "Virtual display requires macOS 14.0 or later"
            print("[AppState] \(virtualDisplayError!)")
            return
        }

        if #available(macOS 14.0, *) {
            let manager = VirtualDisplayManager()
            virtualDisplayManager = manager

            do {
                let config = VirtualDisplayManager.DisplayConfig(width: width, height: height)
                let displayID = try manager.createDisplay(config: config)

                virtualDisplayID = displayID
                hasVirtualDisplay = true
                virtualDisplayError = nil

                // Wait a moment for the display to register with the system
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second

                // Refresh display list and auto-select the virtual display
                await loadDisplays()

                // Find and select the virtual display
                if let virtualDisplay = availableDisplays.first(where: { $0.displayID == displayID }) {
                    selectedDisplay = virtualDisplay
                    print("[AppState] Virtual display created and selected: \(displayID)")
                } else {
                    // Virtual display created but not found in ScreenCaptureKit
                    // This might happen if the display needs more time to register
                    print("[AppState] Virtual display created (ID: \(displayID)) but not yet visible in ScreenCaptureKit")

                    // Try to find any non-main display
                    if let nonMainDisplay = availableDisplays.first(where: { $0.displayID != CGMainDisplayID() }) {
                        selectedDisplay = nonMainDisplay
                        print("[AppState] Selected alternative display: \(nonMainDisplay.displayID)")
                    }
                }

            } catch {
                virtualDisplayError = error.localizedDescription
                print("[AppState] Failed to create virtual display: \(error)")
            }
        }
    }

    /// Remove the virtual display
    func destroyVirtualDisplay() {
        if #available(macOS 14.0, *) {
            if let manager = virtualDisplayManager as? VirtualDisplayManager {
                manager.destroyDisplay()
            }
        }

        virtualDisplayManager = nil
        virtualDisplayID = nil
        hasVirtualDisplay = false

        // Refresh displays and select main display
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
                        HStack {
                            Image(systemName: mode.icon)
                            Text(mode.rawValue)
                        }
                        .tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Text(appState.streamMode.description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                // Display picker (only for Mirror mode)
                if appState.streamMode == .mirror {
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

                // Virtual display status (for Extend mode)
                if appState.streamMode == .extend {
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
            Button(appState.isStreaming ? "Stop Streaming" : "Start Streaming") {
                Task {
                    await appState.toggleStreaming()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(appState.isStreaming ? .red : .accentColor)

            Divider()

            // Footer
            HStack {
                Button("Settings...") {
                    openSettings()
                }

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
        .padding()
        .frame(width: 260)
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
