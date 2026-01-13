# Mac2Droid

Stream your Mac display to Android devices over USB or WiFi. Similar to SpaceDesk or Duet Display.

## Features

- **Low-latency streaming** using hardware H.264 encoding/decoding
- **USB connection** via ADB port forwarding (lowest latency)
- **WiFi connection** (planned for future release)
- **Multiple displays** - stream any connected display
- **Virtual display** - extend your desktop (macOS 14+)

## Requirements

### Mac
- macOS 14.0 (Sonoma) or later
- Xcode 15+ for building

### Android
- Android 8.0 (API 26) or later
- USB debugging enabled
- ADB installed on Mac

## Quick Start

### 1. Build & Install

**Mac App:**
```bash
cd mac-server
open Mac2Droid.xcodeproj  # Or build with Xcode
# Or use Swift Package Manager:
swift build
```

**Android App:**
```bash
cd android-client
./gradlew installDebug
```

### 2. Connect via USB

```bash
# Connect your Android device via USB
# Run the connection script:
./scripts/connect.sh

# Or manually:
adb forward tcp:5555 tcp:5555
```

### 3. Start Streaming

1. Launch **Mac2Droid** on your Mac (menu bar icon)
2. Select display and quality settings
3. Click **Start Streaming**
4. Launch **Mac2Droid** on Android
5. Tap **Connect**

## Architecture

```
┌─────────────────── MAC ───────────────────┐
│  ScreenCaptureKit → VideoToolbox → TCP    │
└─────────────────────┬─────────────────────┘
                      │ USB/WiFi
┌─────────────────── ANDROID ───────────────┐
│  TCP → MediaCodec → SurfaceView           │
└───────────────────────────────────────────┘
```

## Project Structure

```
mac2droid/
├── mac-server/           # Swift macOS app
│   └── Mac2Droid/
│       ├── App/          # SwiftUI MenuBar app
│       ├── Capture/      # ScreenCaptureKit
│       ├── Encoder/      # VideoToolbox H.264
│       ├── Network/      # TCP server
│       └── Protocol/     # Streaming protocol
│
├── android-client/       # Kotlin Android app
│   └── app/src/main/
│       ├── kotlin/com/mac2droid/
│       │   ├── decoder/  # MediaCodec
│       │   ├── network/  # TCP client
│       │   ├── protocol/ # Protocol parsing
│       │   └── ui/       # Compose UI
│       └── res/
│
├── scripts/              # Helper scripts
└── RoadMap.md           # Development roadmap
```

## Streaming Protocol

### Handshake (24 bytes)
| Field | Size | Description |
|-------|------|-------------|
| Magic | 4B | "M2D\0" |
| Version | 4B | 0x00010000 |
| Codec | 4B | 1=H.264 |
| Width | 4B | Video width |
| Height | 4B | Video height |
| FPS | 4B | Frame rate |

### Frame Header (12 bytes)
| Field | Size | Description |
|-------|------|-------------|
| Flags | 1B | Config/Keyframe/EOS |
| Reserved | 1B | - |
| PTS | 6B | Timestamp (μs) |
| Size | 4B | Payload size |

## Performance Targets

| Metric | USB | WiFi |
|--------|-----|------|
| Latency | <50ms | <100ms |
| Resolution | 1080p | 1080p |
| Frame Rate | 60fps | 30-60fps |
| Bitrate | 6-10 Mbps | 4-8 Mbps |

## Troubleshooting

### Connection fails
- Ensure USB debugging is enabled on Android
- Check `adb devices` shows your device
- Run `./scripts/connect.sh` again

### High latency
- Use USB instead of WiFi
- Lower quality setting to "Performance"
- Close other apps using camera/screen

### Black screen on Android
- Wait for Mac to start streaming first
- Check Mac app shows "Streaming" status
- Restart both apps

## License

MIT License
