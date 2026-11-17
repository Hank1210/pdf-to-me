// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PDFToMe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PDFToMeCore", targets: ["PDFToMeCore"]),
        .executable(name: "PDFToMeApp", targets: ["PDFToMeApp"]),
    ],
    targets: [
        // Die gesamte Logik, testbar und ohne Oberfläche.
        .target(name: "PDFToMeCore"),
        // SwiftUI/AppKit-App, bleibt dünn.
        .executableTarget(name: "PDFToMeApp", dependencies: ["PDFToMeCore"]),
        .testTarget(name: "PDFToMeCoreTests", dependencies: ["PDFToMeCore"]),
    ]
)
