import CoreGraphics
import Testing
@testable import OpenLens

struct GlowDotFieldTests {
    private let viewfinder = CGRect(x: 100, y: 200, width: 260, height: 260)

    @Test func pointsBesideAnEdgeMeasureStraightToIt() {
        let (distance, normal) = GlowDotField.roundedRectDistance(
            from: CGPoint(x: 400, y: 330),
            to: viewfinder,
            cornerRadius: 30
        )

        #expect(abs(distance - 40) < 0.001)
        #expect(normal == CGVector(dx: 1, dy: 0))
    }

    @Test func pointsPastACornerPointDiagonallyOutward() {
        let (distance, normal) = GlowDotField.roundedRectDistance(
            from: CGPoint(x: 80, y: 180),
            to: viewfinder,
            cornerRadius: 30
        )
        let cornerCenterDistance = hypot(50.0, 50.0)

        #expect(abs(distance - (cornerCenterDistance - 30)) < 0.001)
        #expect(normal.dx < 0)
        #expect(normal.dy < 0)
        #expect(abs(normal.dx - normal.dy) < 0.001)
    }

    @Test func pointsInsideAreNegative() {
        let (distance, normal) = GlowDotField.roundedRectDistance(
            from: CGPoint(x: 230, y: 210),
            to: viewfinder,
            cornerRadius: 30
        )

        #expect(abs(distance + 10) < 0.001)
        #expect(normal == CGVector(dx: 0, dy: -1))
    }
}
