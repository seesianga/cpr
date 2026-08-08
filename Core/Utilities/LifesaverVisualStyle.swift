import SwiftUI

/// Semantic status roles keep clinical state legible without relying on hue alone.
enum LifesaverStatusRole: Sendable, Equatable {
    case success
    case warning
    case critical
    case informational
    case neutral
}

/// Environment-driven visual tokens shared by windowed and immersive interfaces.
struct LifesaverVisualStyle {
    let highContrast: Bool

    init(highContrast: Bool) {
        self.highContrast = highContrast
    }

    init(preferences: AudioPreferencesSnapshot) {
        self.init(highContrast: preferences.highContrast)
    }

    var captionBackgroundOpacity: Double { highContrast ? 0.94 : 0.58 }
    var captionBorderOpacity: Double { highContrast ? 1.0 : 0.42 }
    var statusBorderWidth: CGFloat { highContrast ? 2 : 1 }

    var captionForegroundColor: Color { .white }
    var captionBackgroundColor: Color { .black.opacity(captionBackgroundOpacity) }
    var captionBorderColor: Color { .white.opacity(captionBorderOpacity) }

    func foregroundColor(for role: LifesaverStatusRole) -> Color {
        guard highContrast else {
            return switch role {
            case .success: .green
            case .warning: .orange
            case .critical: .red
            case .informational: .blue
            case .neutral: .secondary
            }
        }

        return switch role {
        case .success, .critical, .informational, .neutral: .white
        case .warning: .black
        }
    }

    func backgroundColor(for role: LifesaverStatusRole) -> Color {
        if highContrast {
            return switch role {
            case .success: Color(red: 0.02, green: 0.30, blue: 0.12)
            case .warning: Color(red: 1.0, green: 0.82, blue: 0.0)
            case .critical: Color(red: 0.58, green: 0.0, blue: 0.06)
            case .informational: Color(red: 0.0, green: 0.22, blue: 0.55)
            case .neutral: Color(red: 0.16, green: 0.16, blue: 0.18)
            }
        }

        return switch role {
        case .success: .green.opacity(0.14)
        case .warning: .orange.opacity(0.16)
        case .critical: .red.opacity(0.14)
        case .informational: .blue.opacity(0.14)
        case .neutral: .secondary.opacity(0.12)
        }
    }

    func borderColor(for role: LifesaverStatusRole) -> Color {
        if highContrast {
            return role == .warning ? .black : .white
        }
        return foregroundColor(for: role).opacity(0.55)
    }
}

private struct LifesaverVisualStyleKey: EnvironmentKey {
    static let defaultValue = LifesaverVisualStyle(highContrast: false)
}

extension EnvironmentValues {
    var lifesaverVisualStyle: LifesaverVisualStyle {
        get { self[LifesaverVisualStyleKey.self] }
        set { self[LifesaverVisualStyleKey.self] = newValue }
    }
}

private struct LifesaverStatusChipModifier: ViewModifier {
    @Environment(\.lifesaverVisualStyle) private var style
    let role: LifesaverStatusRole

    func body(content: Content) -> some View {
        content
            .foregroundStyle(style.foregroundColor(for: role))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(style.backgroundColor(for: role), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(
                        style.borderColor(for: role),
                        lineWidth: style.statusBorderWidth
                    )
            }
    }
}

private struct LifesaverCaptionSurfaceModifier: ViewModifier {
    @Environment(\.lifesaverVisualStyle) private var style

    func body(content: Content) -> some View {
        content
            .foregroundStyle(style.captionForegroundColor)
            .background(
                style.captionBackgroundColor,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(style.captionBorderColor, lineWidth: style.statusBorderWidth)
            }
    }
}

extension View {
    func lifesaverStatusChip(_ role: LifesaverStatusRole) -> some View {
        modifier(LifesaverStatusChipModifier(role: role))
    }

    func lifesaverCaptionSurface() -> some View {
        modifier(LifesaverCaptionSurfaceModifier())
    }
}
