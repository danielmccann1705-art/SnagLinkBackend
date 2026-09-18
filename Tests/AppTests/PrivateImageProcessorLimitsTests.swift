import XCTest
import Foundation
import Vapor
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
        let time = Int(value("time") ?? "0") ?? 0
        XCTAssertGreaterThanOrEqual(time, 60, "a 25-megapixel sheet takes about 21 s on a quarter of a core; a 30 s ceiling made it an opaque file")
        XCTAssertGreaterThan(PrivateImageProcessor.magickWait, Double(time), "the wall-clock wait must outlast the resource limit")
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

    /// The distinction the whole retry rests on: a file that carries an image
    /// signature we claim to handle and still will not decode is *our* failure, and is
    /// retryable; a file with no image signature is a settled fact about the file and
    /// must never be processed again. Collapsing the two made a processor bug permanent.
    func testASignedImageThatWillNotDecodeIsOurFailureNotASettledOutcome() throws {
        var signedButBroken = Data([137, 80, 78, 71, 13, 10, 26, 10])
        signedButBroken.append(Data(repeating: 0x41, count: 1024))
        XCTAssertEqual(PrivateImageProcessor.detectMime(signedButBroken), "image/png",
                       "the bytes claim to be a PNG, so this reaches the processor")
        XCTAssertThrowsError(try PrivateImageProcessor.process(signedButBroken, mime: "image/png"))

        var truncatedJPEG = Data([255, 216, 255, 224])
        truncatedJPEG.append(Data(repeating: 0x00, count: 64))
        XCTAssertEqual(PrivateImageProcessor.detectMime(truncatedJPEG), "image/jpeg")
        XCTAssertThrowsError(try PrivateImageProcessor.process(truncatedJPEG, mime: "image/jpeg"))

        // No signature: never offered to the processor, so never retried either.
        XCTAssertNil(PrivateImageProcessor.detectMime(Data("%PDF-1.7\n".utf8)))
        XCTAssertNil(PrivateImageProcessor.detectMime(Data("Site notes, 12 March.".utf8)))
        XCTAssertNil(PrivateImageProcessor.detectMime(Data()))

        // The classification recorded against an attempt is a fixed token, never a message.
        XCTAssertEqual(LegacyImportProcessingService.OpaqueReason.processorFailed.rawValue, "image_processing_failed")
        XCTAssertEqual(LegacyImportProcessingService.OpaqueReason.notAnImage.rawValue, "not_an_image")
        XCTAssertEqual(LegacyImportProcessingService.failureKind(Abort(.serviceUnavailable, reason: "s3://bucket/path?signature=secret", identifier: "staged_original_storage_unavailable")), "staged_original_storage_unavailable")
        XCTAssertEqual(LegacyImportProcessingService.failureKind(Abort(.internalServerError, reason: "s3://bucket/path?signature=secret")), "unknown")
    }
}
