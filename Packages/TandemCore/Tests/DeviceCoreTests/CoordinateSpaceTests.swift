import Testing
@testable import DeviceCore

@Suite struct CoordinateSpaceTests {
    @Test func portraitScalesToLongEdge() {
        let s = CoordinateSpace(screenWidth: 1080, screenHeight: 2400)!
        #expect(s.width == 576 && s.height == 1280)
    }
    @Test func landscapeScalesToLongEdge() {
        let s = CoordinateSpace(screenWidth: 2400, screenHeight: 1080)!
        #expect(s.width == 1280 && s.height == 576)
    }
    @Test func smallScreenIsUpscaled() {
        let s = CoordinateSpace(screenWidth: 480, screenHeight: 800)!
        #expect(s.width == 768 && s.height == 1280)
    }
    @Test func normalizedClamps() {
        let s = CoordinateSpace(screenWidth: 1080, screenHeight: 2400)!
        #expect(s.normalized(x: 288, y: 640) == NormalizedPoint(x: 0.5, y: 0.5))
        #expect(s.normalized(x: -5, y: 2000) == NormalizedPoint(x: 0, y: 1))
    }
    @Test func pointRoundsBack() {
        let s = CoordinateSpace(screenWidth: 1080, screenHeight: 2400)!
        let p = s.point(NormalizedPoint(x: 0.5, y: 0.25))
        #expect(p.x == 288 && p.y == 320)
    }
    @Test func zeroSizeIsNil() {
        #expect(CoordinateSpace(screenWidth: 0, screenHeight: 100) == nil)
        #expect(CoordinateSpace(screenWidth: 100, screenHeight: -1) == nil)
    }
}
