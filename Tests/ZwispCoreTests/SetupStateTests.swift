import Testing
@testable import ZwispCore

struct SetupStateTests {
    /// All permissions granted — tweak one axis per test.
    private func perms(mic: PermissionStatus = .granted,
                       input: PermissionStatus = .granted,
                       ax: PermissionStatus = .granted) -> OnboardingState {
        OnboardingState(microphone: mic, inputMonitoring: input, accessibility: ax)
    }

    /// Everything installed and granted unless overridden.
    private func state(permissions: OnboardingState? = nil,
                       speechModel: InstallPhase = .installed,
                       cleanupModel: InstallPhase = .installed) -> SetupState {
        SetupState(permissions: permissions ?? perms(),
                   speechModel: speechModel,
                   cleanupModel: cleanupModel)
    }

    // MARK: - needsSetup

    @Test func needsSetupWhenHotkeyPermissionsMissingRegardlessOfModels() {
        // Everything downloaded, but a hotkey permission is missing → setup.
        #expect(state(permissions: perms(input: .notGranted)).needsSetup)
        #expect(state(permissions: perms(ax: .notGranted)).needsSetup)
    }

    @Test func needsSetupWheneverSpeechModelNotInstalled() {
        // Every non-installed phase leaves the app unable to transcribe.
        #expect(state(speechModel: .missing).needsSetup)
        #expect(state(speechModel: .installing(stage: "Downloading", fraction: 0.5)).needsSetup)
        #expect(state(speechModel: .failed("nope")).needsSetup)
    }

    @Test func cleanupModelAloneNeverForcesSetup() {
        // Cleanup is optional-by-design; a missing model doesn't nag.
        #expect(!state(cleanupModel: .missing).needsSetup)
        #expect(!state(cleanupModel: .failed("disk full")).needsSetup)
    }

    @Test func noSetupNeededWhenPermissionsGrantedAndSpeechInstalled() {
        #expect(!state().needsSetup)
    }

    // MARK: - cleanupReady

    @Test func cleanupReadyTracksTheModelFile() {
        // The engine ships inside the app; the model file is the only dependency.
        #expect(state().cleanupReady)
        #expect(!state(cleanupModel: .missing).cleanupReady)
        #expect(!state(cleanupModel: .installing(stage: "Downloading", fraction: 0.5)).cleanupReady)
    }

    // MARK: - cleanupActionTitle()

    @Test func cleanupActionTitleOffersTheDownloadWhenMissing() {
        let title = state(cleanupModel: .missing).cleanupActionTitle(modelName: "Qwen3 4B")
        #expect(title == "Download Qwen3 4B (~2.5 GB)…")
    }

    @Test func cleanupActionTitleOffersTheDownloadAfterAFailure() {
        // "Retry" semantics: a failed download is re-offered, not hidden.
        let title = state(cleanupModel: .failed("connection dropped"))
            .cleanupActionTitle(modelName: "Qwen3 4B")
        #expect(title == "Download Qwen3 4B (~2.5 GB)…")
    }

    @Test func cleanupActionTitleNilWhenReady() {
        #expect(state().cleanupActionTitle(modelName: "Qwen3 4B") == nil)
    }

    @Test func cleanupActionTitleNilWhileBusy() {
        // A running download must not offer a button that would race it.
        #expect(state(cleanupModel: .installing(stage: "Downloading", fraction: 0.3))
            .cleanupActionTitle(modelName: "Qwen3 4B") == nil)
    }

    // MARK: - InstallPhase.statusLine

    @Test func statusLineForEachPhase() {
        #expect(InstallPhase.missing.statusLine == "Not installed")
        #expect(InstallPhase.installed.statusLine == "Installed")
        #expect(InstallPhase.failed("disk full").statusLine == "Failed: disk full")
    }

    @Test func statusLineRendersPercentWhenFractionKnown() {
        #expect(InstallPhase.installing(stage: "Downloading model", fraction: 0.42).statusLine
            == "Downloading model — 42%")
    }

    @Test func statusLineIsIndeterminateWithoutFraction() {
        #expect(InstallPhase.installing(stage: "Verifying", fraction: nil).statusLine == "Verifying…")
    }

    @Test func statusLineClampsOutOfRangeFractions() {
        // Rounding or an over-count must never print a nonsense percent.
        #expect(InstallPhase.installing(stage: "Pulling", fraction: 1.04).statusLine == "Pulling — 100%")
        #expect(InstallPhase.installing(stage: "Pulling", fraction: -0.03).statusLine == "Pulling — 0%")
    }

    // MARK: - InstallPhase flags

    @Test func isInstalledAndIsBusyReflectTheCase() {
        #expect(InstallPhase.installed.isInstalled)
        #expect(!InstallPhase.missing.isInstalled)
        #expect(!InstallPhase.installing(stage: "x", fraction: nil).isInstalled)

        #expect(InstallPhase.installing(stage: "x", fraction: nil).isBusy)
        #expect(!InstallPhase.installed.isBusy)
        #expect(!InstallPhase.missing.isBusy)
        #expect(!InstallPhase.failed("x").isBusy)
    }

    // MARK: - ProgressGate

    @Test func progressGateAlwaysEmitsEndpoints() {
        var gate = ProgressGate(minDelta: 0.5)
        let start = gate.shouldEmit(0.0)      // start frame
        let mid = gate.shouldEmit(0.3)        // +0.3 < 0.5 → suppressed
        let done = gate.shouldEmit(1.0)       // completion frame never dropped
        #expect(start)
        #expect(!mid)
        #expect(done)
    }

    @Test func progressGateSuppressesSmallDeltas() {
        var gate = ProgressGate(minDelta: 0.1)
        let first = gate.shouldEmit(0.2)      // establishes baseline → emits
        let small = gate.shouldEmit(0.25)     // +0.05 < 0.1 → suppressed
        let big = gate.shouldEmit(0.35)       // +0.15 ≥ 0.1 → emits
        #expect(first)
        #expect(!small)
        #expect(big)
    }
}
