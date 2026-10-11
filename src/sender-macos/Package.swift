// swift-tools-version:5.10
import PackageDescription

// PaneCast macOS yayıncısı.
// Amaç: ScreenCaptureKit ile SEÇİLİ PENCEREYİ yakala → VideoToolbox ile H.264 kodla
//       → RFC 6184 RTP/UDP olarak TV alıcısına gönder. Kontrol kanalı TCP/JSON-lines.
// Ekran kaydı izni (TCC) yalnızca gerçek bir .app bundle içinde sorulur;
// bu yüzden ikiliyi scripts/build-sender-app.sh bundle'lar.
let package = Package(
    name: "atvm-sender",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "atvm-sender",
            path: "Sources/ATVMSender",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("Network"),
            ]
        ),
        .testTarget(
            name: "ATVMSenderTests",
            dependencies: ["atvm-sender"],
            path: "Tests/ATVMSenderTests"
        ),
    ]
)
