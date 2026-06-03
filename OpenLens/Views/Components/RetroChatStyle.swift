import SwiftUI

enum RetroChatStyle {
    static let screenTop = Color(red: 0.83, green: 0.89, blue: 0.63)
    static let screenMiddle = Color(red: 0.70, green: 0.79, blue: 0.48)
    static let screenBottom = Color(red: 0.53, green: 0.66, blue: 0.34)
    static let paper = Color(red: 0.96, green: 0.96, blue: 0.84)
    static let paperWarm = Color(red: 0.90, green: 0.92, blue: 0.72)
    static let playerFill = Color(red: 0.73, green: 0.82, blue: 0.48)
    static let ink = Color(red: 0.06, green: 0.09, blue: 0.04)
    static let secondaryInk = Color(red: 0.19, green: 0.27, blue: 0.13)
    static let mutedInk = Color(red: 0.31, green: 0.40, blue: 0.23)
    static let shadow = Color(red: 0.06, green: 0.09, blue: 0.04).opacity(0.45)
    static let blueAccent = Color(red: 0.18, green: 0.22, blue: 0.58)
    static let magentaAccent = Color(red: 0.46, green: 0.12, blue: 0.34)
    static let danger = Color(red: 0.62, green: 0.13, blue: 0.10)

    private static let pokemonFontName = "Pokemon-Classic"

    static let bodyFont = Font.custom(pokemonFontName, size: 13)
    static let smallFont = Font.custom(pokemonFontName, size: 11)
    static let headerFont = Font.custom(pokemonFontName, size: 13)
}

struct RetroChatScreenBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    RetroChatStyle.screenTop,
                    RetroChatStyle.screenMiddle,
                    RetroChatStyle.screenBottom,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RetroChatScanlines()
                .opacity(0.5)
        }
    }
}

private struct RetroChatScanlines: View {
    private let pixelPitch: CGFloat = 7
    private let lineWidth: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            var path = Path()

            var y: CGFloat = 0
            while y < size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: lineWidth))
                y += pixelPitch
            }

            var x: CGFloat = 0
            while x < size.width {
                path.addRect(CGRect(x: x, y: 0, width: lineWidth, height: size.height))
                x += pixelPitch
            }

            context.fill(path, with: .color(RetroChatStyle.ink.opacity(0.08)))
        }
    }
}

struct RetroChatDoubleBorder: View {
    let cornerRadius: CGFloat
    var lineWidth: CGFloat = 2

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(RetroChatStyle.ink, lineWidth: lineWidth)
            .overlay {
                RoundedRectangle(cornerRadius: max(cornerRadius - 4, 0), style: .continuous)
                    .inset(by: 5)
                    .stroke(RetroChatStyle.mutedInk.opacity(0.8), lineWidth: 1)
            }
    }
}

struct RetroChatPanelChrome: ViewModifier {
    let fill: Color
    let cornerRadius: CGFloat
    var shadowOffset: CGFloat = 3

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .shadow(color: RetroChatStyle.shadow, radius: 0, x: shadowOffset, y: shadowOffset)
            }
            .overlay {
                RetroChatDoubleBorder(cornerRadius: cornerRadius)
            }
    }
}

struct RetroOptionalPanelChrome: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .padding(.horizontal, 8)
                .modifier(RetroChatPanelChrome(fill: RetroChatStyle.paper, cornerRadius: 6, shadowOffset: 2))
        } else {
            content
        }
    }
}

struct ChatModeChipChrome: ViewModifier {
    let visualMode: ChatVisualMode
    var usesGlassInStandardMode = true

    func body(content: Content) -> some View {
        if visualMode.isRetro {
            content
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(RetroChatStyle.paperWarm)
                        .shadow(color: RetroChatStyle.shadow.opacity(0.75), radius: 0, x: 2, y: 2)
                }
                .overlay {
                    RetroChatDoubleBorder(cornerRadius: 5, lineWidth: 1.5)
                }
        } else {
            if usesGlassInStandardMode {
                content
                    .background(Color.appTertiary)
                    .clipShape(Capsule())
                    .glassEffect()
            } else {
                content
                    .background(Color.appTertiary)
                    .clipShape(Capsule())
            }
        }
    }
}

struct ChatComposerFieldChrome: ViewModifier {
    let visualMode: ChatVisualMode

    func body(content: Content) -> some View {
        if visualMode.isRetro {
            content
                .modifier(RetroChatPanelChrome(fill: RetroChatStyle.paper, cornerRadius: 7))
        } else {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.appSeparator.opacity(0.8), lineWidth: 1)
                }
                .subtleShadow()
        }
    }
}

struct ChatPopoverChrome: ViewModifier {
    let visualMode: ChatVisualMode

    func body(content: Content) -> some View {
        if visualMode.isRetro {
            content
                .modifier(RetroChatPanelChrome(fill: RetroChatStyle.paper, cornerRadius: 7, shadowOffset: 4))
        } else {
            content
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.appSeparator.opacity(0.7), lineWidth: 1)
                }
        }
    }
}

struct ChatHeaderStatusChrome: ViewModifier {
    let visualMode: ChatVisualMode

    func body(content: Content) -> some View {
        if visualMode.isRetro {
            content
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(RetroChatStyle.paperWarm)
                        .shadow(color: RetroChatStyle.shadow.opacity(0.7), radius: 0, x: 2, y: 2)
                }
                .overlay {
                    RetroChatDoubleBorder(cornerRadius: 5, lineWidth: 1.5)
                }
        } else {
            content
                .glassEffect(.regular, in: Capsule())
        }
    }
}

struct ChatRecordingButtonChrome: ViewModifier {
    let visualMode: ChatVisualMode

    func body(content: Content) -> some View {
        if visualMode.isRetro {
            content
                .modifier(RetroChatPanelChrome(fill: RetroChatStyle.paperWarm, cornerRadius: 5, shadowOffset: 2))
        } else {
            content
                .background(Color.appSurface)
                .clipShape(Capsule())
                .surfaceShadow()
        }
    }
}

extension View {
    func chatModeChipChrome(_ visualMode: ChatVisualMode, usesGlassInStandardMode: Bool = true) -> some View {
        modifier(ChatModeChipChrome(visualMode: visualMode, usesGlassInStandardMode: usesGlassInStandardMode))
    }

    func ifRetroPanel(_ enabled: Bool) -> some View {
        modifier(RetroOptionalPanelChrome(enabled: enabled))
    }

    func chatComposerFieldChrome(_ visualMode: ChatVisualMode) -> some View {
        modifier(ChatComposerFieldChrome(visualMode: visualMode))
    }

    func chatPopoverChrome(_ visualMode: ChatVisualMode) -> some View {
        modifier(ChatPopoverChrome(visualMode: visualMode))
    }

    func chatHeaderStatusChrome(_ visualMode: ChatVisualMode) -> some View {
        modifier(ChatHeaderStatusChrome(visualMode: visualMode))
    }

    func chatRecordingButtonChrome(_ visualMode: ChatVisualMode) -> some View {
        modifier(ChatRecordingButtonChrome(visualMode: visualMode))
    }
}
