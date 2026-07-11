import SwiftUI
import ZwispCore

/// The main window's root layout: a fixed dark sidebar and a scrolling detail
/// pane, switching on `MainSection`. Hand-rolled rather than
/// `NavigationSplitView` so the branded near-black look isn't fighting system
/// sidebar material, selection chrome, or a collapse affordance.
struct MainView: View {
    let model: MainWindowModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
                .frame(width: Theme.sidebarWidth)
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: Theme.hairlineWidth)
            detail
        }
        .background(Theme.background)
        .ignoresSafeArea()
        // The window forces `.darkAqua`, but the SwiftUI hierarchy states it
        // too so previews and any hosted sheets agree.
        .preferredColorScheme(.dark)
    }

    private var detail: some View {
        ScrollView {
            Group {
                switch model.selection {
                case .home: HomeSectionView(model: model)
                case .setup: SetupSectionView(model: model)
                case .dictation: DictationSectionView(model: model.settings)
                case .cleanup: CleanupSectionView(model: model.settings)
                case .dictionary: DictionarySectionView(model: model.settings)
                case .styles: StylesSectionView(model: model.settings)
                }
            }
            .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
            .padding(Theme.space2XL)
            .frame(maxWidth: .infinity)   // centers the constrained column
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    let model: MainWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXS) {
            // Wordmark, inset below the traffic lights (transparent title bar).
            Text("zwisp")
                .font(.system(size: 13, weight: .semibold))
                .tracking(2)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 52)
                .padding(.leading, Theme.spaceL)
                .padding(.bottom, Theme.spaceL)

            ForEach(MainSection.allCases, id: \.self) { section in
                SidebarRow(section: section,
                           isSelected: model.selection == section,
                           showsBadge: section == .setup && model.setupNeedsAttention,
                           select: { model.select(section) })
            }
            Spacer()
        }
        .padding(.horizontal, Theme.spaceS)
    }
}

private struct SidebarRow: View {
    let section: MainSection
    let isSelected: Bool
    let showsBadge: Bool
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: Theme.spaceM) {
                // A sharp LED bar marks the selection — the sidebar's one piece
                // of pixel language.
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 3, height: 14)
                    .opacity(isSelected ? 0.92 : 0)
                Image(systemName: section.symbolName)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                Text(section.title)
                    .font(Theme.body)
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
                if showsBadge {
                    PixelStatusDot(kind: .attention)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, Theme.spaceS)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Theme.surfaceRaised
                          : hovering ? Theme.surface : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
