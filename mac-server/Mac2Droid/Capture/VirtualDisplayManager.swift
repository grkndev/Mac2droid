import Foundation
import CoreGraphics
import Cocoa

// MARK: - Virtual Display Manager
/// Creates and manages a virtual display for use as a second monitor
/// Note: CGVirtualDisplay API requires macOS 14.0+ and may need special entitlements
@MainActor
final class VirtualDisplayManager: ObservableObject {
    // MARK: - Published Properties
    @Published private(set) var isActive = false
    @Published private(set) var displayID: CGDirectDisplayID?
    @Published private(set) var error: Error?

    // MARK: - Private Properties
    // Store reference to prevent deallocation
    private var displayRef: AnyObject?
    private var descriptorRef: AnyObject?
    private var settingsRef: AnyObject?

    // MARK: - Configuration
    struct DisplayConfig {
        let width: Int
        let height: Int
        let ppi: Int
        let name: String

        init(width: Int = 1920, height: Int = 1080, ppi: Int = 144, name: String = "Mac2Droid Display") {
            self.width = width
            self.height = height
            self.ppi = ppi
            self.name = name
        }

        static let hd720 = DisplayConfig(width: 1280, height: 720, ppi: 110, name: "Mac2Droid 720p")
        static let hd1080 = DisplayConfig(width: 1920, height: 1080, ppi: 144, name: "Mac2Droid 1080p")
        static let qhd = DisplayConfig(width: 2560, height: 1440, ppi: 192, name: "Mac2Droid QHD")
    }

    // MARK: - Public Methods

    /// Create a virtual display with the specified configuration
    /// - Parameter config: Display configuration
    /// - Returns: The display ID if successful
    @discardableResult
    func createDisplay(config: DisplayConfig = .hd1080) throws -> CGDirectDisplayID {
        // Stop any existing display
        if isActive {
            destroyDisplay()
        }

        // Check macOS version
        guard #available(macOS 14.0, *) else {
            throw VirtualDisplayError.notAvailable
        }

        print("[VirtualDisplay] Attempting to create virtual display: \(config.width)x\(config.height)")

        // Use runtime lookup for CGVirtualDisplay API
        guard let displayID = createVirtualDisplayRuntime(config: config) else {
            throw VirtualDisplayError.creationFailed
        }

        self.displayID = displayID
        self.isActive = true
        self.error = nil

        print("[VirtualDisplay] Successfully created virtual display: \(config.width)x\(config.height) @ \(config.ppi)ppi, ID: \(displayID)")

        return displayID
    }

    /// Destroy the current virtual display
    func destroyDisplay() {
        guard isActive else { return }

        let oldID = displayID

        // Clear references to trigger cleanup
        displayRef = nil
        descriptorRef = nil
        settingsRef = nil
        displayID = nil
        isActive = false

        if let oldID = oldID {
            print("[VirtualDisplay] Destroyed virtual display ID: \(oldID)")
        }
    }

    // MARK: - Private Methods

    /// Create virtual display using runtime lookup
    @available(macOS 14.0, *)
    private func createVirtualDisplayRuntime(config: DisplayConfig) -> CGDirectDisplayID? {
        // Load CGVirtualDisplay classes dynamically
        print("[VirtualDisplay] Looking up CGVirtualDisplay classes...")

        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type else {
            print("[VirtualDisplay] ERROR: CGVirtualDisplayDescriptor class not found")
            return nil
        }
        print("[VirtualDisplay] Found CGVirtualDisplayDescriptor")

        guard let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type else {
            print("[VirtualDisplay] ERROR: CGVirtualDisplay class not found")
            return nil
        }
        print("[VirtualDisplay] Found CGVirtualDisplay")

        guard let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type else {
            print("[VirtualDisplay] ERROR: CGVirtualDisplaySettings class not found")
            return nil
        }
        print("[VirtualDisplay] Found CGVirtualDisplaySettings")

        guard let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type else {
            print("[VirtualDisplay] ERROR: CGVirtualDisplayMode class not found")
            return nil
        }
        print("[VirtualDisplay] Found CGVirtualDisplayMode")

        // Create descriptor
        print("[VirtualDisplay] Creating descriptor...")
        let descriptor = descriptorClass.init()
        descriptorRef = descriptor  // Keep reference

        // Set descriptor properties using KVC
        do {
            descriptor.setValue(config.name, forKey: "name")
            descriptor.setValue(config.width, forKey: "maxPixelsWide")
            descriptor.setValue(config.height, forKey: "maxPixelsHigh")

            // Calculate physical size
            let physicalSize = calculatePhysicalSize(width: config.width, height: config.height, ppi: config.ppi)
            descriptor.setValue(NSValue(size: physicalSize), forKey: "sizeInMillimeters")

            // Set identifiers
            let serialNum = UInt32(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 16777216))
            descriptor.setValue(NSNumber(value: serialNum), forKey: "serialNum")
            descriptor.setValue(NSNumber(value: 0x1234), forKey: "vendorID")
            descriptor.setValue(NSNumber(value: 0x5678), forKey: "productID")

            print("[VirtualDisplay] Descriptor configured: name=\(config.name), size=\(config.width)x\(config.height)")
        } catch {
            print("[VirtualDisplay] ERROR setting descriptor properties: \(error)")
            return nil
        }

        // Create virtual display using NSInvocation-style approach
        print("[VirtualDisplay] Creating CGVirtualDisplay instance...")

        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString("initWithDescriptor:")

        guard displayClass.responds(to: allocSelector) else {
            print("[VirtualDisplay] ERROR: CGVirtualDisplay doesn't respond to alloc")
            return nil
        }

        guard let allocResult = displayClass.perform(allocSelector) else {
            print("[VirtualDisplay] ERROR: alloc returned nil")
            return nil
        }

        let allocatedDisplay = allocResult.takeUnretainedValue() as! NSObject

        guard allocatedDisplay.responds(to: initSelector) else {
            print("[VirtualDisplay] ERROR: CGVirtualDisplay doesn't respond to initWithDescriptor:")
            return nil
        }

        guard let initResult = allocatedDisplay.perform(initSelector, with: descriptor) else {
            print("[VirtualDisplay] ERROR: initWithDescriptor: returned nil")
            return nil
        }

        let initializedDisplay = initResult.takeUnretainedValue() as! NSObject
        displayRef = initializedDisplay  // Keep reference

        print("[VirtualDisplay] CGVirtualDisplay instance created")

        // Create settings
        print("[VirtualDisplay] Creating display settings...")
        let settings = settingsClass.init()
        settingsRef = settings  // Keep reference

        settings.setValue(NSNumber(value: 0), forKey: "hiDPI")

        // Create mode
        print("[VirtualDisplay] Creating display mode...")
        let modeAllocResult = modeClass.perform(allocSelector)
        guard let modeAlloc = modeAllocResult else {
            print("[VirtualDisplay] ERROR: Mode alloc returned nil")
            return nil
        }

        let allocatedMode = modeAlloc.takeUnretainedValue() as! NSObject

        // Try different initialization approaches for mode
        let modeInitSelector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        if allocatedMode.responds(to: modeInitSelector) {
            // This selector takes multiple arguments, need to use NSInvocation or alternative
            // For simplicity, try setting properties directly after init
            let simpleInitSelector = NSSelectorFromString("init")
            if allocatedMode.responds(to: simpleInitSelector) {
                _ = allocatedMode.perform(simpleInitSelector)
                allocatedMode.setValue(NSNumber(value: config.width), forKey: "width")
                allocatedMode.setValue(NSNumber(value: config.height), forKey: "height")
                allocatedMode.setValue(NSNumber(value: 60.0), forKey: "refreshRate")
                settings.setValue([allocatedMode], forKey: "modes")
                print("[VirtualDisplay] Mode configured: \(config.width)x\(config.height) @ 60Hz")
            }
        }

        // Apply settings
        print("[VirtualDisplay] Applying settings...")
        let applySelector = NSSelectorFromString("applySettings:")
        if initializedDisplay.responds(to: applySelector) {
            _ = initializedDisplay.perform(applySelector, with: settings)
            print("[VirtualDisplay] Settings applied")
        } else {
            print("[VirtualDisplay] WARNING: Display doesn't respond to applySettings:")
        }

        // Get display ID
        print("[VirtualDisplay] Getting display ID...")
        guard let displayIDValue = initializedDisplay.value(forKey: "displayID") as? UInt32 else {
            print("[VirtualDisplay] ERROR: Failed to get display ID from instance")
            return nil
        }

        if displayIDValue == 0 {
            print("[VirtualDisplay] WARNING: Display ID is 0, display may not be active")
        }

        print("[VirtualDisplay] Got display ID: \(displayIDValue)")

        return displayIDValue
    }

    /// Calculate physical size in millimeters from pixels and PPI
    private func calculatePhysicalSize(width: Int, height: Int, ppi: Int) -> CGSize {
        let mmPerInch = 25.4
        let widthMm = Double(width) / Double(ppi) * mmPerInch
        let heightMm = Double(height) / Double(ppi) * mmPerInch
        return CGSize(width: widthMm, height: heightMm)
    }
}

// MARK: - Virtual Display Errors
enum VirtualDisplayError: LocalizedError {
    case creationFailed
    case notAvailable
    case alreadyExists
    case classNotFound(String)

    var errorDescription: String? {
        switch self {
        case .creationFailed:
            return "Virtual display oluşturulamadı. Bu özellik macOS 14+ ve özel sistem izinleri gerektirebilir."
        case .notAvailable:
            return "Virtual display özelliği macOS 14.0 (Sonoma) veya üstü gerektirir."
        case .alreadyExists:
            return "Zaten bir virtual display mevcut."
        case .classNotFound(let name):
            return "CGVirtualDisplay API bulunamadı: \(name)"
        }
    }
}

// MARK: - Availability Helper
/// Check if virtual display feature is available
func isVirtualDisplayAvailable() -> Bool {
    guard #available(macOS 14.0, *) else {
        return false
    }
    // Check if CGVirtualDisplay class exists at runtime
    let available = NSClassFromString("CGVirtualDisplayDescriptor") != nil
    print("[VirtualDisplay] Availability check: \(available ? "Available" : "Not available")")
    return available
}
