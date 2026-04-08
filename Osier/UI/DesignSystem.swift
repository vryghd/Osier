//
//  DesignSystem.swift
//  Osier — UI Layer
//
//  Single source of truth for colors, typography, spacing, and animations.
//  All views consume tokens from here — never use raw literals in views.
//

import SwiftUI

// MARK: - Color Palette

extension Color {
    // ── Backgrounds ──────────────────────────────────────────────────────
    static let osierBg          = Color(red: 0.04, green: 0.04, blue: 0.07)   // #0A0A12
    static let osierSurface     = Color(red: 0.09, green: 0.09, blue: 0.13)   // #171720
    static let osierElevated    = Color(red: 0.13, green: 0.13, blue: 0.18)   // #212230

    // ── Accents ──────────────────────────────────────────────────────────
    static let osierAccent      = Color(red: 0.29, green: 0.62, blue: 1.00)   // #4A9EFF — electric blue
    static let osierGreen       = Color(red: 0.20, green: 0.84, blue: 0.29)   // #32D74B — success / iCloud
    static let osierAmber       = Color(red: 1.00, green: 0.58, blue: 0.00)   // #FF9500 — external / warning
    static let osierRed         = Color(red: 1.00, green: 0.27, blue: 0.23)   // #FF453A — danger / delete
    static let osierPurple      = Color(red: 0.75, green: 0.35, blue: 1.00)   // #BF59FF — vault

    // ── Text ─────────────────────────────────────────────────────────────
    static let osierPrimary     = Color.white
    static let osierSecondary   = Color(white: 0.55)
    static let osierTertiary    = Color(white: 0.35)

    // ── Borders & Separators ─────────────────────────────────────────────
    static let osierBorder      = Color.white.opacity(0.07)
    static let osierBorderFocus = Color.white.opacity(0.18)
    static let osierDivider     = Color.white.opacity(0.05)
}

// MARK: - Gradient Library

extension LinearGradient {
    static let osierAccentGradient = LinearGradient(
        colors: [Color.osierAccent, Color.osierPurple.opacity(0.8)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let osierSurfaceGradient = LinearGradient(
        colors: [Color.osierSurface, Color.osierElevated],
        startPoint: .top, endPoint: .bottom
    )
}

// MARK: - Typography

extension Font {
    /// Large display numbers (storage readouts)
    static let osierDisplay = Font.system(.largeTitle, design: .rounded, weight: .bold)

    /// Section headers
    static let osierTitle   = Font.system(.title2, design: .rounded, weight: .semibold)

    /// Card titles
    static let osierHeadline = Font.system(.headline, design: .rounded, weight: .semibold)

    /// Body copy
    static let osierBody    = Font.system(.subheadline, design: .default, weight: .regular)

    /// Monospaced data (bytes, paths)
    static let osierMono    = Font.system(.caption, design: .monospaced, weight: .medium)

    /// Small labels
    static let osierCaption = Font.system(.caption2, design: .rounded, weight: .medium)
}

// MARK: - Spacing

enum OsierSpacing {
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 24
    static let xl:  CGFloat = 32
    static let xxl: CGFloat = 48
}

// MARK: - Corner Radius

enum OsierRadius {
    static let xs:  CGFloat = 6
    static let sm:  CGFloat = 10
    static let md:  CGFloat = 14
    static let lg:  CGFloat = 20
    static let xl:  CGFloat = 28
}

// MARK: - Animation

extension Animation {
    static let osierSpring   = Animation.spring(response: 0.4, dampingFraction: 0.75)
    static let osierSnap     = Animation.spring(response: 0.25, dampingFraction: 0.85)
    static let osierSmooth   = Animation.easeInOut(duration: 0.35)
}

// MARK: - Reusable View Modifiers

/// Glassmorphism surface card
struct OsierCard: ViewModifier {
    var padding: CGFloat = OsierSpacing.md

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: OsierRadius.md)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: OsierRadius.md)
                            .stroke(Color.osierBorder, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func osierCard(padding: CGFloat = OsierSpacing.md) -> some View {
        modifier(OsierCard(padding: padding))
    }
}

/// Scale press animation
struct PressEffect: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.osierSnap, value: configuration.isPressed)
    }
}

// MARK: - Storage Color Mapping

extension Color {
    static func storageColor(for type: StorageColorType) -> Color {
        switch type {
        case .internal: return .osierAccent
        case .iCloud:   return .osierGreen
        case .external: return .osierAmber
        }
    }
}

enum StorageColorType {
    case `internal`, iCloud, external
}

// MARK: - Status Dot

struct StatusDot: View {
    let color: Color
    var animated: Bool = false

    @State private var pulse = false

    var body: some View {
        ZStack {
            if animated {
                Circle()
                    .fill(color.opacity(0.3))
                    .frame(width: 12, height: 12)
                    .scaleEffect(pulse ? 1.8 : 1.0)
                    .opacity(pulse ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false),
                               value: pulse)
                    .onAppear { pulse = true }
            }
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
    }
}

// MARK: - Byte Formatter

extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .binary)
    }
}

extension Double {
    /// Formats a fraction (0.0–1.0) as a percentage string.
    var percentString: String { "\(Int(self * 100))%" }
}
