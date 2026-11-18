// swift-tools-version:5.10
import PackageDescription

// qpdf und libjpeg-turbo werden von Scripts/fetch-qpdf.sh aus Quellcode gebaut und nach Vendor/qpdf gelegt.
// Vendor/ ist nicht im Repo.
// Fehlt Vendor/qpdf, meldet Sources/QPDFKit/QPDFKit.cc das beim Bauen mit einem Hinweis auf das Skript.
let vendor = Context.packageDirectory + "/Vendor/qpdf"

let package = Package(
    name: "PDFToMe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PDFToMeCore", targets: ["PDFToMeCore"]),
        .executable(name: "PDFToMeApp", targets: ["PDFToMeApp"]),
    ],
    dependencies: [
        // Gemeinsamer Code mit Scan to me (Lokalisierung, später Texterkennung).
        // Vorerst lokal; mit der ersten DocKit-Version über die URL eingebunden.
        .package(path: "../doc-kit"),
    ],
    targets: [
        // C-Schnittstelle zu qpdf (C++), statisch gelinkt.
        .target(
            name: "QPDFKit",
            cxxSettings: [.unsafeFlags(["-I", vendor + "/include"])],
            linkerSettings: [
                .unsafeFlags(["-L", vendor + "/lib"]),
                .linkedLibrary("qpdf"),
                .linkedLibrary("jpeg"),
                .linkedLibrary("z"),
            ]),
        // Die gesamte Logik, testbar und ohne Oberfläche.
        .target(name: "PDFToMeCore", dependencies: ["QPDFKit", .product(name: "DocKit", package: "doc-kit")]),
        // AppKit/SwiftUI-App, bleibt dünn.
        .executableTarget(name: "PDFToMeApp", dependencies: ["PDFToMeCore", .product(name: "DocKit", package: "doc-kit")]),
        .testTarget(name: "PDFToMeCoreTests", dependencies: ["PDFToMeCore", "QPDFKit", .product(name: "DocKit", package: "doc-kit")]),
    ],
    cxxLanguageStandard: .cxx17
)
