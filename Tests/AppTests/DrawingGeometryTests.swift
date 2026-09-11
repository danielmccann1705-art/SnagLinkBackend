@testable import App
import XCTest
import Vapor

final class DrawingGeometryTests: XCTestCase {
    private func pdf(_ rotation: Int = 0, unit: Double = 1, transform: [Double]? = nil, width: Int? = nil, display: DrawingPageGeometry.Box? = nil) -> DrawingPageGeometry {
        let transforms: [Int:[Double]] = [
            0:[1.0/580,0,0,-1.0/780,-20.0/580,1+30.0/780],
            90:[0,1.0/580,1.0/780,0,-30.0/780,-20.0/580],
            180:[-1.0/580,0,0,1.0/780,1+20.0/580,-30.0/780],
            270:[0,-1.0/580,-1.0/780,0,1+30.0/780,1+20.0/580]
        ]
        return .init(mediaBox:.init(x:10,y:20,width:600,height:800),cropBox:.init(x:20,y:30,width:580,height:780),displayBox:display ?? .init(x:20,y:30,width:580,height:780),rotation:rotation,userUnit:unit,width:width ?? ([90,270].contains(rotation) ? 780 : 580),height:[90,270].contains(rotation) ? 580 : 780,sourceToDisplay:transform ?? transforms[rotation]!,coordinateSystem:"display_top_left_v1")
    }
    private func reject(_ geometry: DrawingPageGeometry, mime: String = "application/pdf", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try DrawingGeometryValidation.validate(geometry,mime:mime),file:file,line:line) { error in
            XCTAssertEqual((error as? Abort)?.status,.badRequest,file:file,line:line)
        }
    }
    func testRawPDFCornersAndAsymmetricPinMatchAllRotationsWithNonzeroOrigin() throws {
        let expected: [(Int,Double,Double)] = [(0,0.25,0.25),(90,0.75,0.25),(180,0.75,0.75),(270,0.25,0.75)]
        for (rotation,x,y) in expected {
            let g = pdf(rotation,unit:2.5), t = g.sourceToDisplay
            try DrawingGeometryValidation.validate(g,mime:"application/pdf")
            // Raw point (165,615) is u=.25,v=.75 inside crop(20,30,580,780).
            XCTAssertEqual(t[0]*165+t[2]*615+t[4],x,accuracy:1e-12)
            XCTAssertEqual(t[1]*165+t[3]*615+t[5],y,accuracy:1e-12)
        }
        let t = pdf().sourceToDisplay
        XCTAssertEqual(t[0]*20+t[2]*810+t[4],0,accuracy:1e-12)
        XCTAssertEqual(t[1]*20+t[3]*810+t[5],0,accuracy:1e-12)
    }
    func testUnscaledFlippedSingularAndNonfiniteTransformsReject() {
        reject(pdf(transform:[1,0,0,-1,0,1]))
        reject(pdf(transform:[1.0/580,0,0,1.0/780,-20.0/580,-30.0/780]))
        reject(pdf(transform:[0,0,0,0,0,0]))
        reject(pdf(transform:[Double.infinity,0,0,-1,0,1]))
        reject(pdf(transform:[1.0/580,0,0,-1.0/780,-20.0/580+0.001,1+30.0/780]))
    }
    func testRenderAspectRotationAndDisplayCropMismatchReject() {
        reject(pdf(90,width:580))
        reject(pdf(width:800))
        reject(pdf(display:.init(x:20,y:30,width:500,height:780)))
        reject(pdf(unit:0)); reject(pdf(unit:Double.nan))
    }
    func testEffectiveCropIsIntersectionAndNoIntersectionRejects() throws {
        let media = DrawingPageGeometry.Box(x:0,y:0,width:100,height:100)
        let g = DrawingPageGeometry(mediaBox:media,cropBox:.init(x:-10,y:-10,width:120,height:120),displayBox:media,rotation:0,userUnit:1,width:100,height:100,sourceToDisplay:[0.01,0,0,-0.01,0,1],coordinateSystem:"display_top_left_v1")
        try DrawingGeometryValidation.validate(g,mime:"application/pdf")
        reject(.init(mediaBox:media,cropBox:.init(x:200,y:200,width:100,height:100),displayBox:media,rotation:0,userUnit:1,width:100,height:100,sourceToDisplay:g.sourceToDisplay,coordinateSystem:g.coordinateSystem))
    }
    func testUprightRasterUsesPixelTopLeftAndRetainsLegacyPinSurface() throws {
        let box = DrawingPageGeometry.Box(x:0,y:0,width:1200,height:800)
        let g = DrawingPageGeometry(mediaBox:box,cropBox:box,displayBox:box,rotation:0,userUnit:1,width:600,height:400,sourceToDisplay:[1.0/1200,0,0,1.0/800,0,0],coordinateSystem:"display_top_left_v1")
        try DrawingGeometryValidation.validate(g,mime:"image/jpeg")
        let t = g.sourceToDisplay
        XCTAssertEqual(t[0]*300+t[4],0.25,accuracy:1e-12); XCTAssertEqual(t[3]*600+t[5],0.75,accuracy:1e-12)
        reject(.init(mediaBox:box,cropBox:box,displayBox:box,rotation:0,userUnit:1,width:600,height:400,sourceToDisplay:[1.0/1200,0,0,-1.0/800,0,1],coordinateSystem:g.coordinateSystem),mime:"image/png")
        reject(pdf(),mime:"image/jpeg")
    }
    func testSinglePixelRoundingAllowedButDistortionRejected() throws {
        try DrawingGeometryValidation.validate(pdf(width:581),mime:"application/pdf")
        reject(pdf(width:590))
    }

    func testLargeWorldOriginCannotHideShiftedCrop() throws {
        let x: Double = 1099511627776.0, source = DrawingPageGeometry.Box(x:x,y:0,width:1024,height:1024)
        let valid = DrawingPageGeometry(mediaBox:source,cropBox:source,displayBox:source,rotation:0,userUnit:1,width:1024,height:1024,sourceToDisplay:[1.0/1024,0,0,-1.0/1024,-x/1024,1],coordinateSystem:"display_top_left_v1")
        try DrawingGeometryValidation.validate(valid,mime:"application/pdf")
        let shifted = DrawingPageGeometry.Box(x:x+64,y:0,width:1024,height:1024)
        reject(.init(mediaBox:source,cropBox:source,displayBox:shifted,rotation:0,userUnit:1,width:1024,height:1024,sourceToDisplay:[1.0/1024,0,0,-1.0/1024,-(x+64)/1024,1],coordinateSystem:"display_top_left_v1"))
    }
    func testTinySourceBoxStillRequiresCorrectRenderAspect() throws {
        let size: Double = 1.0 / 1099511627776.0, box = DrawingPageGeometry.Box(x:0,y:0,width:size,height:size)
        let valid = DrawingPageGeometry(mediaBox:box,cropBox:box,displayBox:box,rotation:0,userUnit:1,width:100,height:100,sourceToDisplay:[1/size,0,0,-1/size,0,1],coordinateSystem:"display_top_left_v1")
        try DrawingGeometryValidation.validate(valid,mime:"application/pdf")
        reject(.init(mediaBox:box,cropBox:box,displayBox:box,rotation:0,userUnit:1,width:100,height:1000,sourceToDisplay:valid.sourceToDisplay,coordinateSystem:valid.coordinateSystem))
    }
}
