import SwiftUI

/// The unified main window's dark, self-contained design tokens — colours,
/// fonts, and metrics in one place, mirroring how `Configuration` centralises
/// behaviour. Values come straight from the brand palette in
/// `Assets/generate-logo.py` (the logo is the source of truth), so the window,
/// the logo, and the dictation wave all read as one 8-bit system.
///
/// **Solid colours only** — deliberately no `.ultraThinMaterial` anywhere. The
/// window forces a dark appearance and must not tint with whatever is behind it;
/// a material would bleed the desktop through the near-black surfaces.
enum Theme {
    // MARK: Colours

    static let background    = rgb(6, 6, 8)       // near-black, the logo's field
    static let surface       = rgb(14, 14, 18)    // cards
    static let surfaceRaised = rgb(20, 20, 25)    // controls / secondary buttons
    static let ghost         = rgb(32, 32, 38)    // unlit LED / off state
    /// White hairline at 0.07 — matches the dictation overlay's border.
    static let hairline      = Color.white.opacity(0.07)

    static let textPrimary   = rgb(242, 243, 250) // LED-white
    static let textSecondary = textPrimary.opacity(0.55)
    static let textTertiary  = textPrimary.opacity(0.35)

    // Semantic accents (pastel, from the logo's tip palette).
    static let accent     = rgb(109, 182, 255)    // blue   — primary action
    static let ok         = rgb(87, 240, 203)     // teal   — ready / success
    static let busy       = rgb(244, 228, 107)    // yellow — working
    static let attention  = rgb(255, 176, 102)    // orange — needs setup
    static let recording  = rgb(255, 133, 189)    // pink   — recording
    static let thinking   = rgb(192, 140, 255)    // purple — cleanup running

    /// The logo's eight-colour tip cycle, in order. Consumers that need more
    /// than eight entries wrap with a modulo.
    static let tipCycle: [Color] = [
        rgb(109, 182, 255),   // blue
        rgb(87, 240, 203),    // teal
        rgb(155, 240, 107),   // green
        rgb(244, 228, 107),   // yellow
        rgb(255, 176, 102),   // orange
        rgb(255, 133, 189),   // pink
        rgb(192, 140, 255),   // purple
    ]

    // MARK: Fonts

    static let sectionTitle = Font.system(size: 22, weight: .semibold)
    static let cardTitle    = Font.system(size: 13, weight: .semibold)
    static let body         = Font.system(size: 13)
    static let caption      = Font.system(size: 11)
    /// Big numbers — monospaced digits so a ticking stat doesn't jitter its width.
    static let statValue    = Font.system(size: 28, weight: .medium).monospacedDigit()

    // MARK: Metrics

    static let spaceXS:  CGFloat = 4
    static let spaceS:   CGFloat = 8
    static let spaceM:   CGFloat = 12
    static let spaceL:   CGFloat = 16
    static let spaceXL:  CGFloat = 24
    static let space2XL: CGFloat = 32

    static let cardCornerRadius: CGFloat = 8
    static let hairlineWidth:    CGFloat = 0.5
    static let sidebarWidth:     CGFloat = 200
    static let contentMaxWidth:  CGFloat = 620

    /// Palette values are authored as 0–255 sRGB (matching the Python source);
    /// this converts them once.
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: 1)
    }
}
