import XCTest
import Foundation
@testable import App

final class PrivateImageProcessorLimitsTests: XCTestCase {
    /// A photo within the documented 40-megapixel ceiling must decode on the Linux runtime,
    /// which needs the ImageMagick pixel cache to be allowed to spill beyond RAM.
    func testResourceLimitsLetALargePhotoDecodeInsteadOfBecomingOpaque() throws {
        let limits = PrivateImageProcessor.magickLimits
        func value(_ name: String) -> String? { limits.firstIndex(of: name).flatMap { limits.indices.contains($0 + 1) ? limits[$0 + 1] : nil } }
        XCTAssertNotEqual(value("map"), "0", "a zero map limit confines the pixel cache to RAM and large photos fail to decode")
        XCTAssertNotEqual(value("disk"), "0")
        XCTAssertEqual(value("thread"), "1")
        XCTAssertNotNil(value("time"))
        #if canImport(ImageIO)
        throw XCTSkip("ImageMagick path is only used on the Linux runtime")
        #else
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/convert") else { throw XCTSkip("ImageMagick not installed") }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("large-photo-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.jpg")
        let make = Process(); make.executableURL = URL(fileURLWithPath: "/usr/bin/convert")
        make.arguments = ["-size", "5000x4000", "gradient:gray20-gray80", "-quality", "80", "jpeg:\(source.path)"]
        try make.run(); make.waitUntilExit()
        XCTAssertEqual(make.terminationStatus, 0)
        let data = try Data(contentsOf: source)
        let result = try PrivateImageProcessor.process(data, mime: "image/jpeg")
        XCTAssertEqual(result.sourceWidth, 5000); XCTAssertEqual(result.sourceHeight, 4000)
        XCTAssertEqual(max(result.width, result.height), PrivateImageProcessor.maximumPixelSize)
        #endif
    }
}
