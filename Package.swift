// swift-tools-version:6.0
import PackageDescription

// NotesCore deliberately has ZERO dependencies and imports no Apple-only
// framework. That is what lets it build and test on Windows, which is the only
// local feedback available on this machine. Everything platform-specific lives
// in the app target instead.
let package = Package(
    name: "NotesCore",
    products: [
        .library(name: "NotesCore", targets: ["NotesCore"])
    ],
    targets: [
        .target(name: "NotesCore"),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore"])
    ]
)
