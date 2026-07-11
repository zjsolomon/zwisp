import Observation
import ZwispCore

/// View model for the Home dashboard: local dictation stats plus the hotkey
/// names for the wave card's caption. Pipeline status comes from the sibling
/// `SetupModel`/`SettingsModel` (via `MainWindowModel`), not duplicated here.
@MainActor
@Observable
final class HomeModel {
    private let statsStore: StatsStore
    private let hotkeyStore: HotkeyStore

    private(set) var todayStats: StatsAggregate
    private(set) var lifetimeStats: StatsAggregate
    private(set) var hotkeyNames: [String]

    init(statsStore: StatsStore, hotkeyStore: HotkeyStore) {
        self.statsStore = statsStore
        self.hotkeyStore = hotkeyStore
        self.todayStats = statsStore.today()
        self.lifetimeStats = statsStore.lifetime
        self.hotkeyNames = hotkeyStore.hotkeys.map(\.name)
    }

    func refresh() {
        todayStats = statsStore.today()
        lifetimeStats = statsStore.lifetime
        hotkeyNames = hotkeyStore.hotkeys.map(\.name)
    }
}
