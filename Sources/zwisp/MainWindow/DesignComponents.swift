import SwiftUI

/// Reusable building blocks for the main window, styled from `Theme`. They keep
/// the 8-bit rules the dictation overlay established: sharp-cornered LED cells,
/// instant on/off steps with only opacity animating, and static fallbacks under
/// Reduce Motion. Nothing here reaches for `.ultraThinMaterial` — solid fills only.

/// A framed surface panel: `Theme.surface` fill, rounded corners, hairline border,
/// 16pt padding.
struct Card<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(Theme.spaceL)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
    }
}

/// A section title with an optional subtitle beneath it.
struct SectionHeader: View {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXS) {
            Text(title)
                .font(Theme.sectionTitle)
                .foregroundStyle(Theme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Status dot

enum StatusKind {
    case ok, busy, attention, off
}

/// A sharp 7×7 LED square coloured by status. `busy` pulses its opacity slowly
/// (0.35 ↔ 0.9, the overlay's cadence); every other kind is steady, and Reduce
/// Motion pins `busy` to a static lit square.
struct PixelStatusDot: View {
    let kind: StatusKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Rectangle()
            .fill(tint)
            .frame(width: 7, height: 7)
            .opacity(opacity)
            .onAppear { updatePulse() }
            .onChange(of: kind) { _, _ in updatePulse() }
    }

    private var tint: Color {
        switch kind {
        case .ok:        return Theme.ok
        case .busy:      return Theme.busy
        case .attention: return Theme.attention
        case .off:       return Theme.ghost
        }
    }

    private var opacity: Double {
        guard kind == .busy, !reduceMotion else { return 0.92 }
        return pulse ? 0.9 : 0.35
    }

    /// Starts or cancels the repeating pulse to match the current kind.
    private func updatePulse() {
        guard kind == .busy, !reduceMotion else {
            withAnimation(.linear(duration: 0)) { pulse = false }
            return
        }
        pulse = false
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

// MARK: - Progress bar

/// A fixed row of 24 sharp LED cells. Determinate (`fraction` non-nil): the
/// leading `fraction·24` cells light; the rest ghost. Indeterminate (`nil`): a
/// 3-cell lit run marches left→right (a static half-lit bar under Reduce Motion).
/// LED steps are instant — only the lit/unlit opacity flip animates.
struct PixelProgressBar: View {
    let fraction: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cellCount = 24
    private static let runLength = 3
    /// Seconds the marching run spends on each cell.
    private static let marchStep: TimeInterval = 0.06

    init(fraction: Double?) {
        self.fraction = fraction
    }

    var body: some View {
        if let fraction {
            determinate(fraction: fraction)
        } else if reduceMotion {
            // No timer under Reduce Motion: a steady half-lit bar reads as
            // "working" without motion.
            row { $0 < Self.cellCount / 2 }
        } else {
            indeterminate
        }
    }

    private func determinate(fraction: Double) -> some View {
        let lit = Int((min(max(fraction, 0), 1) * Double(Self.cellCount)).rounded(.down))
        return row { $0 < lit }
            // Only the opacity of a newly (un)lit cell animates; the count is a
            // discrete LED step.
            .animation(.linear(duration: 0.06), value: lit)
    }

    private var indeterminate: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // A run of `runLength` cells whose head marches across the row and
            // off the end, then restarts — a short off-screen gap paces it.
            let span = Self.cellCount + Self.runLength
            let head = Int(t / Self.marchStep) % span
            row { $0 <= head && $0 > head - Self.runLength }
        }
    }

    /// Builds the cell row, lighting each index for which `isLit` is true.
    private func row(_ isLit: @escaping (Int) -> Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.cellCount, id: \.self) { i in
                Rectangle()
                    .fill(Theme.busy)
                    .opacity(isLit(i) ? 0.92 : 0.16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 8)
            }
        }
    }
}

// MARK: - Buttons

/// LIT (LED-white) label on an `accent` fill; dims when pressed.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.spaceM)
            .padding(.vertical, Theme.spaceXS + 2)   // 6
            .background(Theme.accent.opacity(configuration.isPressed ? 0.75 : 0.9))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Neutral: LED-white label on a raised surface with a hairline border.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.spaceM)
            .padding(.vertical, Theme.spaceXS + 2)   // 6
            .background(Theme.surfaceRaised.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
    }
}

// MARK: - Rows

/// A full-width labelled row: title (+ optional caption) on the left, a control
/// on the right. Separators are left to the consumer *except* the opt-in
/// `showsDivider`, which draws a bottom hairline — pass it on all but the last
/// row of a stacked group.
struct SettingRow<Trailing: View>: View {
    let title: String
    let caption: String?
    let showsDivider: Bool
    let trailing: Trailing

    init(title: String, caption: String? = nil, showsDivider: Bool = false,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.caption = caption
        self.showsDivider = showsDivider
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.spaceM) {
            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                Text(title)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                if let caption {
                    Text(caption)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.spaceM)
            trailing
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: Theme.hairlineWidth)
            }
        }
    }
}

/// A `SettingRow` wired to a `Bool` via a standard switch toggle tinted `accent`.
struct ToggleRow: View {
    let title: String
    let caption: String?
    let showsDivider: Bool
    @Binding var isOn: Bool

    init(title: String, caption: String? = nil, showsDivider: Bool = false,
         isOn: Binding<Bool>) {
        self.title = title
        self.caption = caption
        self.showsDivider = showsDivider
        self._isOn = isOn
    }

    var body: some View {
        SettingRow(title: title, caption: caption, showsDivider: showsDivider) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
        }
    }
}
