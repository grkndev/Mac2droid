import Foundation
import CoreGraphics
import Cocoa

// MARK: - Virtual Display Manager
/// Creates and manages a virtual display for use as a second monitor
/// Note: CGVirtualDisplay API requires macOS 14.0+ and may need special entitlements
@MainActor
final class VirtualDisplayManager: ObservableObject {
    // MARK: - Singleton
    static let shared = VirtualDisplayManager()

    // MARK: - Published Properties
    @Published private(set) var isActive = false
    @Published private(set) var displayID: CGDirectDisplayID?
    @Published private(set) var error: Error?

    // MARK: - Private Properties
    // Store reference to prevent deallocation
    private var displayRef: AnyObject?
    private var descriptorRef: AnyObject?
    private var settingsRef: AnyObject?
    private var currentConfig: DisplayConfig?

    // MARK: - Configuration
    struct DisplayConfig: Equatable {
        let width: Int
        let height: Int
        let ppi: Int
        let name: String

        init(width: Int = 1920, height: Int = 1080, ppi: Int = 144, name: String = "Mac2Droid") {
            self.width = width
            self.height = height
            self.ppi = ppi
            self.name = name
        }

        static let hd720 = DisplayConfig(width: 1280, height: 720, ppi: 110, name: "Mac2Droid")
        static let hd1080 = DisplayConfig(width: 1920, height: 1080, ppi: 144, name: "Mac2Droid")
        static let qhd = DisplayConfig(width: 2560, height: 1440, ppi: 192, name: "Mac2Droid")
    }

    // Private init for singleton
    private init() {}

    // MARK: - Public Methods

    /// Get or create a virtual display with the specified configuration
    /// Returns existing display if already created with same config
    @discardableResult
    func getOrCreateDisplay(config: DisplayConfig = .hd1080) throws -> CGDirectDisplayID {
        // If display already exists with same config, return it
        if isActive, let existingID = displayID, currentConfig == config {
            print("[VirtualDisplay] Reusing existing display ID: \(existingID)")
            return existingID
        }

        // If display exists but config is different, destroy and recreate
        if isActive, displayID != nil, currentConfig != config {
            print("[VirtualDisplay] Config changed, destroying old display and creating new one")
            destroyDisplay()
        }

        // Create new display
        return try createDisplay(config: config)
    }

    /// Destroy the current virtual display
    func destroyDisplay() {
        print("[VirtualDisplay] Destroying virtual display")
        displayRef = nil
        descriptorRef = nil
        settingsRef = nil
        displayID = nil
        isActive = false
        currentConfig = nil
    }

    /// Create a virtual display with the specified configuration
    private func createDisplay(config: DisplayConfig) throws -> CGDirectDisplayID {
        // Check macOS version
        guard #available(macOS 14.0, *) else {
            throw VirtualDisplayError.notAvailable
        }

        print("[VirtualDisplay] Creating virtual display: \(config.width)x\(config.height)")

        // Use runtime lookup for CGVirtualDisplay API
        guard let newDisplayID = createVirtualDisplayRuntime(config: config) else {
            throw VirtualDisplayError.creationFailed
        }

        self.displayID = newDisplayID
        self.isActive = true
        self.currentConfig = config
        self.error = nil

        print("[VirtualDisplay] Created virtual display ID: \(newDisplayID)")

        return newDisplayID
    }

    /// Check if display is available for use
    var hasDisplay: Bool {
        return isActive && displayID != nil
    }

    // MARK: - Private Methods

    /// Create virtual display using runtime lookup
    @available(macOS 14.0, *)
    private func createVirtualDisplayRuntime(config: DisplayConfig) -> CGDirectDisplayID? {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type else {
            print("[VirtualDisplay] ERROR: CGVirtualDisplay classes not found")
            return nil
        }

        // Create descriptor
        let descriptor = descriptorClass.init()
        descriptorRef = descriptor

        // Set descriptor properties
        descriptor.setValue(config.name, forKey: "name")
        descriptor.setValue(config.width, forKey: "maxPixelsWide")
        descriptor.setValue(config.height, forKey: "maxPixelsHigh")

        let physicalSize = calculatePhysicalSize(width: config.width, height: config.height, ppi: config.ppi)
        descriptor.setValue(NSValue(size: physicalSize), forKey: "sizeInMillimeters")

        // Use fixed serial number so display is consistent
        descriptor.setValue(NSNumber(value: 0x4D3244), forKey: "serialNum")  // "M2D" in hex
        descriptor.setValue(NSNumber(value: 0x1234), forKey: "vendorID")
        descriptor.setValue(NSNumber(value: 0x5678), forKey: "productID")

        // Create display
        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString("initWithDescriptor:")

        guard let allocResult = displayClass.perform(allocSelector),
              let initResult = (allocResult.takeUnretainedValue() as! NSObject).perform(initSelector, with: descriptor) else {
            print("[VirtualDisplay] ERROR: Failed to create display")
            return nil
        }

        let display = initResult.takeUnretainedValue() as! NSObject
        displayRef = display

        // Create and apply settings
        let settings = settingsClass.init()
        settingsRef = settings
        settings.setValue(NSNumber(value: 0), forKey: "hiDPI")

        // Create mode
        if let modeAllocResult = modeClass.perform(allocSelector) {
            let mode = modeAllocResult.takeUnretainedValue() as! NSObject
            _ = mode.perform(NSSelectorFromString("init"))
            mode.setValue(NSNumber(value: config.width), forKey: "width")
            mode.setValue(NSNumber(value: config.height), forKey: "height")
            mode.setValue(NSNumber(value: 60.0), forKey: "refreshRate")
            settings.setValue([mode], forKey: "modes")
        }

        // Apply settings
        let applySelector = NSSelectorFromString("applySettings:")
        if display.responds(to: applySelector) {
            _ = display.perform(applySelector, with: settings)
        }

        // Get display ID
        guard let displayIDValue = display.value(forKey: "displayID") as? UInt32, displayIDValue != 0 else {
            print("[VirtualDisplay] ERROR: Invalid display ID")
            return nil
        }

        return displayIDValue
    }

    private func calculatePhysicalSize(width: Int, height: Int, ppi: Int) -> CGSize {
        let mmPerInch = 25.4
        return CGSize(
            width: Double(width) / Double(ppi) * mmPerInch,
            height: Double(height) / Double(ppi) * mmPerInch
        )
    }
}

// MARK: - Virtual Display Errors
enum VirtualDisplayError: LocalizedError {
    case creationFailed
    case notAvailable
    case alreadyExists

    var errorDescription: String? {
        switch self {
        case .creationFailed:
            return "Virtual display oluşturulamadı."
        case .notAvailable:
            return "Virtual display macOS 14.0+ gerektirir."
        case .alreadyExists:
            return "Virtual display zaten mevcut."
        }
    }
}

// MARK: - Availability Helper
func isVirtualDisplayAvailable() -> Bool {
    guard #available(macOS 14.0, *) else { return false }
    return NSClassFromString("CGVirtualDisplayDescriptor") != nil
}
