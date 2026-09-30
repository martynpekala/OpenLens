import SwiftUI

/// Animated backdrop of glowing dots laid on a perspective wave surface. Crests glow, a
/// `Pulse` sends a ripple through the surface, and a `Focus` gathers a halo of dots around a
/// rounded rect such as the QR viewfinder. Frames are in the global coordinate space.
struct GlowDotField: View {
    struct Pulse: Equatable {
        let origin: CGPoint
        let date: Date
    }

    struct Focus: Equatable {
        var rect: CGRect
        var cornerRadius: CGFloat
        var isActive: Bool
        var date: Date
    }

    var pulse: Pulse?
    var focus: Focus?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isVisible = false
    @State private var startDate = Date.now

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion || !isVisible)) { timeline in
                let renderer = GlowDotFieldRenderer(
                    time: reduceMotion ? 0 : timeline.date.timeIntervalSince(startDate),
                    date: timeline.date,
                    origin: origin,
                    pulse: reduceMotion ? nil : pulse,
                    focus: focus,
                    reduceMotion: reduceMotion,
                    isDark: colorScheme == .dark,
                    color: Color.appPrimary
                )
                Canvas { context, size in
                    renderer.draw(in: &context, size: size)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

extension GlowDotField {
    /// Signed distance from `point` to a rounded rect (negative inside) and the outward normal.
    static func roundedRectDistance(
        from point: CGPoint,
        to rect: CGRect,
        cornerRadius: CGFloat
    ) -> (distance: CGFloat, normal: CGVector) {
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let px = point.x - rect.midX
        let py = point.y - rect.midY
        let qx = abs(px) - (rect.width / 2 - radius)
        let qy = abs(py) - (rect.height / 2 - radius)
        let outsideX = max(qx, 0)
        let outsideY = max(qy, 0)
        let outside = hypot(outsideX, outsideY)
        let distance = outside + min(max(qx, qy), 0) - radius

        var normal: CGVector
        if outside > 0 {
            normal = CGVector(dx: outsideX / outside, dy: outsideY / outside)
        } else if qx > qy {
            normal = CGVector(dx: 1, dy: 0)
        } else {
            normal = CGVector(dx: 0, dy: 1)
        }
        normal.dx *= px < 0 ? -1 : 1
        normal.dy *= py < 0 ? -1 : 1
        return (distance, normal)
    }
}

private struct GlowDotFieldRenderer {
    private static let spacing = 24.0
    /// Depth of the first row; slightly nearer than the bottom edge so lifted dots never leave a gap.
    private static let nearDepth = 0.94
    private static let dotBuckets = 12
    private static let glowBuckets = 8
    private static let rippleDuration = 1.7
    private static let focusDelay = 0.12
    private static let focusDuration = 1.0

    let time: Double
    let date: Date
    let origin: CGPoint
    let pulse: GlowDotField.Pulse?
    let focus: GlowDotField.Focus?
    let reduceMotion: Bool
    let isDark: Bool
    let color: Color

    private struct Ripple {
        let x: Double
        let depth: Double
        let radius: Double
        let strength: Double
    }

    private struct Lens {
        let rect: CGRect
        let cornerRadius: CGFloat
        let progress: Double
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let width = Double(size.width)
        let height = Double(size.height)
        guard width > 0, height > 0 else { return }

        let spacing = Self.spacing
        // The vanishing line sits above the screen, so the plane recedes without a visible horizon.
        let horizon = -1.1 * height
        let depthSpan = height - horizon
        let centerX = width / 2
        let rowDepth = spacing / depthSpan
        let topDepth = depthSpan / -horizon
        let topScale = 1 / topDepth
        let rowCount = Int(((topDepth + 2 * rowDepth) - Self.nearDepth) / rowDepth) + 2

        // The camera glides forward slowly; rows wrap so the grid stays anchored to the world.
        let rowShift = time * 7 / spacing
        let baseRow = rowShift.rounded(.down)
        let rowFraction = rowShift - baseRow

        let baseAlpha = isDark ? 0.2 : 0.15
        let crestAlpha = isDark ? 0.6 : 0.42
        let maxAlpha = baseAlpha + crestAlpha
        let glowOpacity = isDark ? 0.7 : 0.18

        let ripple = rippleState(horizon: horizon, depthSpan: depthSpan, centerX: centerX, rowDepth: rowDepth)
        let lens = lensState()
        // Dim the field behind the centered copy, except while the ripple or lens own the stage.
        let hushStrength = 0.35 * (1 - (lens?.progress ?? 0)) * (1 - (ripple?.strength ?? 0))

        var dots = Array(repeating: Path(), count: Self.dotBuckets)
        var glows = Array(repeating: Path(), count: Self.glowBuckets)

        for row in 0..<rowCount {
            let depth = Self.nearDepth + (Double(row) - rowFraction) * rowDepth
            let scale = 1 / depth
            let depthFade = Self.smoothstep(topScale, topScale + 0.2, scale)
            guard depthFade > 0 else { continue }

            let baseY = horizon + depthSpan * scale
            let relativeDepth = (depth - 1) / rowDepth * spacing
            let worldRow = Int(baseRow) + row
            let worldDepth = Double(worldRow) * spacing
            let parity = worldRow.isMultiple(of: 2) ? 0 : 0.5
            let columns = Int(((width / 2 + spacing) / scale / spacing).rounded(.up))

            for column in -columns...columns {
                let worldX = (Double(column) + parity) * spacing
                let surface = Self.surfaceHeight(x: worldX, z: worldDepth, time: time)
                var glow = Self.smoothstep(0.15, 0.95, surface)
                var lift = surface * 24

                let seed = Self.hash(column, worldRow)
                if seed > 0.82 {
                    glow += pow(max(0, sin(time * (0.5 + seed) + seed * 97)), 18) * 0.9
                }

                if let ripple {
                    let distance = hypot(worldX - ripple.x, relativeDepth - ripple.depth)
                    let offset = (distance - ripple.radius) / 120
                    if abs(offset) < 3 {
                        let envelope = exp(-offset * offset) * ripple.strength
                        lift += envelope * cos(offset * 2.6) * 50
                        glow += envelope * 2
                    }
                }

                var x = centerX + worldX * scale
                var y = baseY - lift * scale * 0.75
                var alphaScale = depthFade

                if let lens {
                    let (distance, normal) = GlowDotField.roundedRectDistance(
                        from: CGPoint(x: x, y: y),
                        to: lens.rect,
                        cornerRadius: lens.cornerRadius
                    )
                    if distance < 0 {
                        alphaScale *= 1 - lens.progress
                    } else {
                        let halo = exp(-Double(distance) / 42) * lens.progress
                        let pull = min(Double(distance), 20) * halo
                        x -= Double(normal.dx) * pull
                        y -= Double(normal.dy) * pull
                        let angle = atan2(y - Double(lens.rect.midY), x - Double(lens.rect.midX))
                        glow += halo * 1.3 * (0.65 + 0.35 * cos(angle - time * 1.6))
                    }
                }

                guard x > -8, x < width + 8, y > -8, y < height + 8 else { continue }

                if hushStrength > 0 {
                    let dx = (x - centerX) / (width * 0.5)
                    let dy = (y - height * 0.42) / (height * 0.22)
                    alphaScale *= 1 - hushStrength * exp(-(dx * dx + dy * dy))
                }

                let intensity = min(glow, 1.8)
                let alpha = (baseAlpha + crestAlpha * min(intensity, 1)) * alphaScale
                guard alpha > 0.01 else { continue }

                let radius = (1 + min(intensity, 1.4)) * max(scale, 0.5)
                let bucket = min(Int(alpha / maxAlpha * Double(Self.dotBuckets)), Self.dotBuckets - 1)
                dots[bucket].addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))

                if intensity > 0.3 {
                    let glowAlpha = (intensity - 0.3) * alphaScale
                    let glowBucket = min(Int(glowAlpha / 1.5 * Double(Self.glowBuckets)), Self.glowBuckets - 1)
                    let glowRadius = radius * 3.6
                    glows[glowBucket].addEllipse(
                        in: CGRect(x: x - glowRadius, y: y - glowRadius, width: glowRadius * 2, height: glowRadius * 2)
                    )
                }
            }
        }

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 7))
            for (index, path) in glows.enumerated() where !path.isEmpty {
                let opacity = (Double(index) + 0.5) / Double(Self.glowBuckets) * glowOpacity
                layer.fill(path, with: .color(color.opacity(opacity)))
            }
        }
        for (index, path) in dots.enumerated() where !path.isEmpty {
            let opacity = (Double(index) + 0.5) / Double(Self.dotBuckets) * maxAlpha
            context.fill(path, with: .color(color.opacity(opacity)))
        }
    }

    private func rippleState(horizon: Double, depthSpan: Double, centerX: Double, rowDepth: Double) -> Ripple? {
        guard let pulse else { return nil }
        let elapsed = date.timeIntervalSince(pulse.date)
        guard elapsed >= 0, elapsed < Self.rippleDuration else { return nil }

        let x = Double(pulse.origin.x - origin.x)
        let y = Double(pulse.origin.y - origin.y)
        let scale = max((y - horizon) / depthSpan, 0.05)
        let progress = elapsed / Self.rippleDuration
        return Ripple(
            x: (x - centerX) / scale,
            depth: (1 / scale - 1) / rowDepth * Self.spacing,
            radius: elapsed * 1250,
            strength: pow(1 - progress, 1.6)
        )
    }

    private func lensState() -> Lens? {
        guard let focus, !focus.rect.isEmpty else { return nil }
        let progress: Double
        if reduceMotion {
            progress = focus.isActive ? 1 : 0
        } else {
            let elapsed = date.timeIntervalSince(focus.date) - (focus.isActive ? Self.focusDelay : 0)
            let raw = min(max(elapsed / Self.focusDuration, 0), 1)
            let eased = 1 - pow(1 - raw, 3)
            progress = focus.isActive ? eased : 1 - eased
        }
        guard progress > 0 else { return nil }
        return Lens(
            rect: focus.rect.offsetBy(dx: -origin.x, dy: -origin.y),
            cornerRadius: focus.cornerRadius,
            progress: progress
        )
    }

    /// Height of the wave surface in -1...1 at a world position, in points.
    private static func surfaceHeight(x: Double, z: Double, time: Double) -> Double {
        // Swells roll toward the viewer as bands; the cross waves break them into drifting crests.
        let swell = sin(z * 0.011 + x * 0.003 + time * 0.9)
        let cross = sin(x * 0.009 - z * 0.004 - time * 0.5)
        let chop = sin((x + z) * 0.017 + time * 1.2)
        return 0.5 * swell + 0.3 * cross + 0.2 * chop
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func hash(_ a: Int, _ b: Int) -> Double {
        var value = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663))
        value ^= value >> 33
        value &*= 0xff51_afd7_ed55_8ccd
        value ^= value >> 33
        return Double(value & 0xffff) / 65_535
    }
}

#Preview("Glow dot field") {
    GlowDotField()
        .background(Color.appBackground)
        .ignoresSafeArea()
}
