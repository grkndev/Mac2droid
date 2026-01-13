┌─────────────────────────────────────────────────────────────────────┐
│  FAZ 1: Temel Altyapı                                               │
│  ────────────────────                                               │
│  ☐ Mac: ScreenCaptureKit ile ekran yakalama (macOS 12.3+)           │
│  ☐ Mac: VideoToolbox ile H.264/HEVC hardware encoding               │
│  ☐ Mac: TCP/USB server (ADB forward veya WiFi)                      │
│  ☐ Mac: Frame pacing ve buffer yönetimi                             │
│  ☐ Test: Yakalanan stream'i dosyaya kaydet, FFplay ile kontrol et   │
├─────────────────────────────────────────────────────────────────────┤
│  FAZ 2: Android Client                                              │
│  ─────────────────────                                              │
│  ☐ Android: TCP client (ADB üzerinden veya WiFi)                    │
│  ☐ Android: MediaCodec ile hardware decoding                        │
│  ☐ Android: SurfaceView/TextureView üzerinde gösterim               │
│  ☐ Android: Tam ekran, düşük latency modları                        │
│  ☐ Android: NAL unit parsing ve frame assembly                      │
│  Teknoloji: Kotlin (Native) veya React Native                       │
├─────────────────────────────────────────────────────────────────────┤
│  FAZ 3: Optimizasyon & UX                                           │
│  ────────────────────────                                           │
│  ☐ Dinamik bitrate ayarlama (network feedback)                      │
│  ☐ Bağlantı durumu göstergesi                                       │
│  ☐ Çözünürlük ve FPS seçenekleri                                    │
│  ☐ Latency ölçümü ve optimizasyonu                                  │
│  ☐ Mac menubar uygulaması (SwiftUI)                                 │
│  ☐ Android: Bağlantı yönetimi UI                                    │
├─────────────────────────────────────────────────────────────────────┤
│  FAZ 4: Sanal Ekran - Extend Mode                                   │
│  ────────────────────────────────                                   │
│  ☐ CGVirtualDisplay API (macOS 14+) araştırması                     │
│  ☐ Alternatif: Dummy display adapter yaklaşımı                      │
│  ☐ Sanal ekranı ScreenCaptureKit ile yakala                         │
│  ☐ macOS System Preferences'ta görünmesi                            │
│  ☐ Çözünürlük ve yenileme hızı ayarları                             │
├─────────────────────────────────────────────────────────────────────┤
│  FAZ 5: İleri Özellikler (opsiyonel)                                │
│  ───────────────────────────────────                                │
│  ☐ Touch input → Mac mouse/trackpad olarak geri gönderme            │
│  ☐ Ses aktarımı (AAC encoding)                                      │
│  ☐ WiFi Direct veya Bonjour ile cihaz keşfi                         │
│  ☐ Multi-display desteği                                            │
│  ☐ Stylus/Apple Pencil desteği (tablet için)                        │
└─────────────────────────────────────────────────────────────────────┘

## Dizin Yapısı

```
mac2droid/
├── mac-server/                    # Swift macOS uygulaması (SwiftUI + AppKit)
│   ├── Mac2Droid.xcodeproj
│   └── Mac2Droid/
│       ├── App/
│       │   ├── Mac2DroidApp.swift
│       │   └── AppDelegate.swift
│       ├── Views/
│       │   ├── MenuBarView.swift
│       │   └── SettingsView.swift
│       ├── Capture/
│       │   ├── ScreenCaptureManager.swift
│       │   └── VirtualDisplayManager.swift
│       ├── Encoder/
│       │   └── VideoEncoder.swift      # H.264/HEVC VideoToolbox
│       ├── Network/
│       │   ├── StreamServer.swift      # TCP server
│       │   └── ConnectionManager.swift
│       ├── Models/
│       │   └── StreamConfig.swift
│       └── Resources/
│           └── Assets.xcassets
│
├── android-client/                # Kotlin veya React Native
│   │
│   ├── [Kotlin Native]
│   │   ├── app/
│   │   │   └── src/main/
│   │   │       ├── kotlin/com/mac2droid/
│   │   │       │   ├── MainActivity.kt
│   │   │       │   ├── ui/
│   │   │       │   │   └── StreamView.kt
│   │   │       │   ├── decoder/
│   │   │       │   │   └── VideoDecoder.kt
│   │   │       │   └── network/
│   │   │       │       └── StreamClient.kt
│   │   │       └── res/
│   │   └── build.gradle.kts
│   │
│   └── [React Native - Alternatif]
│       ├── src/
│       │   ├── App.tsx
│       │   ├── screens/
│       │   └── native/              # Native module bridge
│       ├── android/
│       └── package.json
│
├── shared/
│   └── protocol.md                # Stream protokolü dokümantasyonu
│
├── scripts/
│   ├── connect.sh                 # ADB forward + başlatma
│   └── build-all.sh
│
├── RoadMap.md
└── README.md
```