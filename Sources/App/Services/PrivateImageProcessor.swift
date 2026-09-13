import Vapor
import Foundation
import Crypto
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#else
import Glibc
#endif

/// Decode and re-encode a bounded still image. Original bytes are retained privately;
/// only a fresh metadata-free JPEG is available through the shared gateway.
enum PrivateImageProcessor {
    struct Result: Sendable {
        let jpeg: Data; let width: Int; let height: Int
        /// Decoded source pixel size before any resize (upright orientation).
        var sourceWidth: Int = 0; var sourceHeight: Int = 0
    }
    static let maximumPixelSize = 4096
    static let maximumBytes = 10 * 1024 * 1024
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func validateSignature(_ data: Data, mime: String) throws {
        guard !data.isEmpty, data.count <= maximumBytes else { throw Abort(.payloadTooLarge, reason: "Choose a photo smaller than 10 MB") }
        let bytes = Array(data.prefix(12))
        let png = bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        let jpeg = bytes.starts(with: [255, 216, 255])
        guard (mime == "image/png" && png) || (mime == "image/jpeg" && jpeg) else {
            throw Abort(.unsupportedMediaType, reason: "Use a genuine JPEG or PNG photo", identifier: "invalid_image")
        }
    }
    /// Sniffs a supported still-image type from leading bytes; nil for anything else.
    static func detectMime(_ data: Data) -> String? {
        let bytes = Array(data.prefix(12))
        if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return "image/png" }
        if bytes.starts(with: [255, 216, 255]) { return "image/jpeg" }
        return nil
    }
    static func process(_ data: Data, mime: String, maximumPixelSize: Int = maximumPixelSize) throws -> Result {
        guard (16...Self.maximumPixelSize).contains(maximumPixelSize) else { throw invalid() }
        try validateSignature(data, mime: mime)
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw invalid() }
        try dimensions(width, height)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary), CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw invalid() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { throw invalid() }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else { throw invalid() }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let swapped = (5...8).contains(orientation)
        return .init(jpeg: output as Data, width: image.width, height: image.height, sourceWidth: swapped ? height : width, sourceHeight: swapped ? width : height)
        #else
        // The runtime image includes ImageMagick. No shell, URL, delegate-selected
        // input format, client filename or unbounded pixel/disk allocation is used.
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snaglist-image-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input"), output = root.appendingPathComponent("output.jpg")
        try data.write(to: input, options: .atomic)
        let format = mime == "image/png" ? "png" : "jpeg"
        let limits = ["-limit", "memory", "256MiB", "-limit", "map", "0", "-limit", "disk", "0", "-limit", "thread", "1", "-limit", "time", "15"]
        let info = try run("/usr/bin/identify", limits + ["-ping", "-format", "%w %h %n", "\(format):\(input.path)"])
        let values = String(decoding: info, as: UTF8.self).split(separator: " ").compactMap { Int($0) }
        guard values.count == 3, values[2] == 1 else { throw invalid() }
        try dimensions(values[0], values[1])
        // Upright source size follows the same auto-orient rule as the rendition.
        let orientation = try run("/usr/bin/identify", limits + ["-ping", "-format", "%[orientation]", "\(format):\(input.path)"])
        let swapped = ["LeftTop", "RightTop", "RightBottom", "LeftBottom"].contains(String(decoding: orientation, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        _ = try run("/usr/bin/convert", limits + ["\(format):\(input.path)", "-auto-orient", "-resize", "\(maximumPixelSize)x\(maximumPixelSize)>", "-background", "white", "-alpha", "remove", "-strip", "-quality", "90", "jpeg:\(output.path)"])
        let outputInfo = try run("/usr/bin/identify", limits + ["-ping", "-format", "%w %h %n", "jpeg:\(output.path)"])
        let size = String(decoding: outputInfo, as: UTF8.self).split(separator: " ").compactMap { Int($0) }
        let jpeg = try Data(contentsOf: output)
        guard size.count == 3, size[2] == 1, !jpeg.isEmpty, jpeg.count <= maximumBytes else { throw invalid() }
        return .init(jpeg: jpeg, width: size[0], height: size[1], sourceWidth: swapped ? values[1] : values[0], sourceHeight: swapped ? values[0] : values[1])
        #endif
    }
    private static func dimensions(_ width: Int, _ height: Int) throws {
        guard width > 0, height > 0, width <= 12000, height <= 12000, width * height <= 40_000_000 else {
            throw Abort(.unprocessableEntity, reason: "Choose a photo up to 40 megapixels and 12,000 pixels per side", identifier: "image_dimensions")
        }
    }
    private static func invalid() -> Abort { Abort(.unprocessableEntity, reason: "This photo could not be processed. Try another JPEG or PNG", identifier: "image_processing_failed") }
    #if !canImport(ImageIO)
    private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw Abort(.serviceUnavailable, reason: "Photo processing is temporarily unavailable") }
        let process = Process(), pipe = Pipe(), ended = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if ended.wait(timeout: .now() + 20) == .timedOut {
            process.terminate()
            if ended.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = ended.wait(timeout: .now() + 2) }
            throw invalid()
        }
        guard process.terminationStatus == 0 else { throw invalid() }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }
    #endif
}
