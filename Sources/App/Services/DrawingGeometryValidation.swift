import Foundation
import Vapor

/// `sourceToDisplay` uses [a,b,c,d,tx,ty]: x'=a*x+c*y+tx, y'=b*x+d*y+ty.
/// PDFs use raw unrotated PDF user-space coordinates (y up); boxes retain those
/// units. Positive UserUnit changes physical scale, not the normalised result.
/// Raster sources use upright decoded pixel coordinates (y down), with zero-origin
/// equal boxes and no PDF rotation. The future processor must prove those byte facts.
struct DrawingGeometryValidation {
    static func validate(_ g: DrawingPageGeometry, mime: String) throws {
        guard [0,90,180,270].contains(g.rotation), g.userUnit.isFinite, g.userUnit > 0, g.userUnit <= 75000,
              (1...12000).contains(g.width), (1...12000).contains(g.height), g.width * g.height <= 40000000,
              g.coordinateSystem == "display_top_left_v1", g.sourceToDisplay.count == 6,
              g.sourceToDisplay.allSatisfy(\.isFinite) else { throw invalid() }
        for b in [g.mediaBox,g.cropBox,g.displayBox] {
            guard [b.x,b.y,b.width,b.height,b.x+b.width,b.y+b.height].allSatisfy(\.isFinite),
                  b.width > 0, b.height > 0, b.x+b.width > b.x, b.y+b.height > b.y else { throw invalid() }
        }
        let b = g.displayBox, w = b.width, h = b.height
        let expected: [Double], corners: [(Double,Double)]
        if mime == "application/pdf" {
            // The published display rectangle is the effective crop inside media.
            let x = max(g.mediaBox.x,g.cropBox.x), y = max(g.mediaBox.y,g.cropBox.y)
            let right = min(g.mediaBox.x+g.mediaBox.width,g.cropBox.x+g.cropBox.width)
            let top = min(g.mediaBox.y+g.mediaBox.height,g.cropBox.y+g.cropBox.height)
            guard right > x, top > y else { throw invalid() }
            let sourceW = right-x, sourceH = top-y
            // Compare position in page fractions, never relative to a possibly huge
            // world origin. A shifted crop must not become valid at large coordinates.
            guard abs((b.x-x)/sourceW) <= 1e-10, abs((b.y-y)/sourceH) <= 1e-10,
                  abs(w/sourceW-1) <= 1e-10, abs(h/sourceH-1) <= 1e-10 else { throw invalid() }
            switch g.rotation {
            case 0:
                expected = [1/w,0,0,-1/h,-b.x/w,1+b.y/h]
                corners = [(0,1),(1,1),(1,0),(0,0)]
            case 90:
                expected = [0,1/w,1/h,0,-b.y/h,-b.x/w]
                corners = [(0,0),(0,1),(1,1),(1,0)]
            case 180:
                expected = [-1/w,0,0,1/h,1+b.x/w,-b.y/h]
                corners = [(1,0),(0,0),(0,1),(1,1)]
            default:
                expected = [0,-1/w,-1/h,0,1+b.y/h,1+b.x/w]
                corners = [(1,1),(1,0),(0,0),(0,1)]
            }
        } else {
            guard ["image/jpeg","image/png"].contains(mime), g.rotation == 0, g.userUnit == 1,
                  g.mediaBox == b, g.cropBox == b, b.x == 0, b.y == 0,
                  w.rounded() == w, h.rounded() == h else { throw invalid() }
            expected = [1/w,0,0,1/h,0,0]
            corners = [(0,0),(1,0),(1,1),(0,1)]
        }
        guard expected.allSatisfy(\.isFinite) else { throw invalid() }
        let t = g.sourceToDisplay
        // Coefficient errors are measured over the page extent; translation errors
        // are already in normalised display units. No absolute source-unit floor.
        for (index,scale) in [(0,w),(1,w),(2,h),(3,h),(4,1),(5,1)] {
            guard abs((t[index]-expected[index])*scale) <= 1e-10 else { throw invalid() }
        }
        let determinant = t[0]*t[3]-t[1]*t[2]
        guard determinant.isFinite, determinant != 0 else { throw invalid() }
        let points = [(b.x,b.y),(b.x+w,b.y),(b.x+w,b.y+h),(b.x,b.y+h)]
        for (point,corner) in zip(points,corners) {
            let x = t[0]*point.0+t[2]*point.1+t[4], y = t[1]*point.0+t[3]*point.1+t[5]
            guard x.isFinite, y.isFinite, abs(x-corner.0) <= 1e-7, abs(y-corner.1) <= 1e-7 else { throw invalid() }
        }
        let swapped = [90,270].contains(g.rotation), orientedW = swapped ? h : w, orientedH = swapped ? w : h
        let aspect = orientedW/orientedH, error = abs(Double(g.width)-Double(g.height)*aspect)
        // Pixel-space tolerance remains meaningful for tiny or huge source boxes.
        // Uniform rendering permits at most one pixel of aspect rounding.
        guard aspect.isFinite, aspect > 0, error.isFinite, error <= max(1,aspect)+1e-10 else { throw invalid() }
    }
    private static func invalid() -> Abort { .init(.badRequest,reason:"Drawing geometry must match its source box, orientation and rendered page") }
}
