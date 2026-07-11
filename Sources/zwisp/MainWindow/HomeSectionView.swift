import SwiftUI
import ZwispCore

/// The Home dashboard: pipeline status at a glance, the big live equalizer,
/// and the local dictation stats. Status is read from the sibling
/// `SetupModel`/`SettingsModel` snapshots (the 1 s window poll keeps them
/// fresh); stats come from `HomeModel`.
struct HomeSectionView: View {
    let model: MainWindowModel

    private var setup: SetupModel { model.setup }
    private var home: HomeModel { model.home }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXL) {
            SectionHeader(title: "Home",
                          subtitle: "Private, on-device dictation. Nothing leaves this Mac.")

            HStack(spacing: Theme.spaceL) {
                statusCard(title: "Speech model",
                           kind: speechKind,
                           line: speechLine,
                           fixHint: setup.speechPhase.isInstalled ? nil : "Fix in Setup")
                statusCard(title: "AI cleanup",
                           kind: cleanupKind,
                           line: model.settings.cleanupStatusLine.isEmpty
                                 ? "Checking…" : model.settings.cleanupStatusLine,
                           fixHint: nil)
                statusCard(title: "Permissions",
                           kind: permissionsKind,
                           line: permissionsLine,
                           fixHint: setup.permissions.needsSetup ? "Fix in Setup" : nil)
            }

            Card {
                VStack(spacing: Theme.spaceM) {
                    HomeWaveView(feed: model.waveFeed,
                                 levelProvider: model.levelProvider,
                                 config: model.config.homeWave)
                        .frame(height: 120)
                    Text(waveCaption)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            HStack(spacing: Theme.spaceL) {
                statTile(value: "\(home.todayStats.dictations)", label: "Dictations today")
                statTile(value: "\(home.todayStats.words)", label: "Words today")
                statTile(value: "\(home.lifetimeStats.dictations)", label: "All time")
                statTile(value: averageSpeed, label: "Avg speed")
            }

            Text("Counts only — zwisp never stores what you said.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Status derivations

    private var speechKind: StatusKind {
        switch setup.speechPhase {
        case .installed: return .ok
        case .installing: return .busy
        case .failed: return .attention
        case .missing: return .attention
        }
    }

    private var speechLine: String {
        setup.speechPhase.isInstalled ? "Ready" : setup.speechPhase.statusLine
    }

    private var cleanupKind: StatusKind {
        if !model.settings.cleanupEnabled { return .off }
        return model.settings.cleanupStatusLine.hasPrefix("Active") ? .ok : .attention
    }

    private var permissionsKind: StatusKind {
        setup.permissions.allGranted ? .ok
            : setup.permissions.needsSetup ? .attention : .off
    }

    private var permissionsLine: String {
        if setup.permissions.allGranted { return "All granted" }
        let missing = setup.permissions.missingHotkeyPermissionNames
        return missing.isEmpty ? "Microphone pending" : missing.joined(separator: ", ")
    }

    private var waveCaption: String {
        switch model.waveFeed.phase {
        case .recording: return "Listening…"
        case .thinking: return "Thinking…"
        case .idle:
            let keys = home.hotkeyNames.isEmpty
                ? "your push-to-talk key" : home.hotkeyNames.joined(separator: " or ")
            return "Hold \(keys) and speak"
        }
    }

    private var averageSpeed: String {
        let avg = home.lifetimeStats.averageTotalSeconds
        return avg > 0 ? String(format: "%.1fs", avg) : "—"
    }

    // MARK: - Cards

    private func statusCard(title: String, kind: StatusKind, line: String,
                            fixHint: String?) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                HStack(spacing: Theme.spaceS) {
                    PixelStatusDot(kind: kind)
                    Text(title)
                        .font(Theme.cardTitle)
                        .foregroundStyle(Theme.textPrimary)
                }
                Text(line)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                if let fixHint {
                    Button(fixHint) { model.select(.setup) }
                        .buttonStyle(.plain)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statTile(value: String, label: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                Text(value)
                    .font(Theme.statValue)
                    .foregroundStyle(Theme.textPrimary)
                Text(label)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
