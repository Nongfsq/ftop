import AppKit
import Testing

@testable import FtopUI

/// Writes the app icon as an `.iconset` folder; `scripts/icon.sh` turns it into
/// `Support/AppIcon.icns`. Runs only when asked:
///
///     FTOP_ICON_DIR=/tmp/AppIcon.iconset swift test --filter IconTests
private let iconDirectory = ProcessInfo.processInfo.environment["FTOP_ICON_DIR"]

@MainActor
@Suite struct IconTests {
    @Test(.enabled(if: iconDirectory != nil))
    func writeIconSet() throws {
        let directory = URL(fileURLWithPath: iconDirectory!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let image = try #require(Logo.appIcon(pixels: points * scale))
                let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: directory.appending(path: "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
            }
        }
    }
}
