import CoreGraphics
import Foundation
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

    // MARK: - Glide

    private let orb = CGRect(x: 160, y: 260, width: 140, height: 140)
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func focus(_ rect: CGRect, cornerRadius: CGFloat = 30, isActive: Bool = true) -> GlowDotField.Focus {
        GlowDotField.Focus(rect: rect, cornerRadius: cornerRadius, isActive: isActive, date: start)
    }

    @Test func aHaloThatWasNotGatheredDoesNotGlide() {
        let glide = GlowDotField.glide(
            from: focus(viewfinder, isActive: false),
            to: focus(orb, cornerRadius: 70),
            continuing: nil,
            at: start
        )

        #expect(glide == nil)
    }

    @Test func smallMovesTrackTheRectWithoutRestartingTheGlide() {
        let running = GlowDotField.Glide(rect: viewfinder, cornerRadius: 30, date: start)
        let glide = GlowDotField.glide(
            from: focus(orb, cornerRadius: 70),
            to: focus(orb.offsetBy(dx: 0, dy: 4), cornerRadius: 70),
            continuing: running,
            at: start.addingTimeInterval(0.2)
        )

        #expect(glide == running)
    }

    @Test func jumpingToAnotherRectGlidesFromWhereTheHaloIsDrawn() {
        let glide = GlowDotField.glide(
            from: focus(viewfinder),
            to: focus(orb, cornerRadius: 70),
            continuing: nil,
            at: start
        )

        #expect(glide == GlowDotField.Glide(rect: viewfinder, cornerRadius: 30, date: start))
    }

    @Test func retargetingMidGlideStartsFromTheHalosCurrentOutline() {
        let orbFocus = focus(orb, cornerRadius: 70)
        let running = GlowDotField.Glide(rect: viewfinder, cornerRadius: 30, date: start)
        let midway = start.addingTimeInterval(GlowDotField.glideDuration / 2)

        let glide = GlowDotField.glide(from: orbFocus, to: focus(viewfinder), continuing: running, at: midway)
        let drawn = GlowDotField.outline(of: orbFocus, glide: running, at: midway)

        #expect(glide == GlowDotField.Glide(rect: drawn.rect, cornerRadius: drawn.cornerRadius, date: midway))
    }

    @Test func theOutlineEasesTowardTheFocusAndSettlesOnIt() {
        let target = focus(orb, cornerRadius: 70)
        let glide = GlowDotField.Glide(rect: viewfinder, cornerRadius: 30, date: start)

        let atStart = GlowDotField.outline(of: target, glide: glide, at: start)
        #expect(atStart.rect == viewfinder)
        #expect(atStart.cornerRadius == 30)

        // Halfway through, the cubic ease-out has covered 7/8 of the way.
        let halfway = GlowDotField.outline(of: target, glide: glide, at: start.addingTimeInterval(GlowDotField.glideDuration / 2))
        #expect(abs(halfway.rect.minX - (viewfinder.minX + (orb.minX - viewfinder.minX) * 0.875)) < 0.001)
        #expect(abs(halfway.cornerRadius - (30 + 40 * 0.875)) < 0.001)

        let settled = GlowDotField.outline(of: target, glide: glide, at: start.addingTimeInterval(GlowDotField.glideDuration + 0.1))
        #expect(settled.rect == orb)
        #expect(settled.cornerRadius == 70)
    }
}
