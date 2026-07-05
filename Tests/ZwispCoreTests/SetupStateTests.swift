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
                       ollamaApp: InstallPhase = .installed,
                       cleanupModel: InstallPhase = .installed) -> SetupState {
        SetupState(permissions: permissions ?? perms(),
                   speechModel: speechModel,
                   ollamaApp: ollamaApp,
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

    @Test func ollamaAndCleanupModelAloneNeverForceSetup() {
        // Cleanup is optional-by-design; a missing Ollama or model doesn't nag.
        #expect(!state(ollamaApp: .missing).needsSetup)
        #expect(!state(cleanupModel: .missing).needsSetup)
        #expect(!state(ollamaApp: .missing, cleanupModel: .missing).needsSetup)
    }

    @Test func noSetupNeededWhenPermissionsGrantedAndSpeechInstalled() {
        #expect(!state().needsSetup)
    }

    // MARK: - cleanupReady

    @Test func cleanupReadyRequiresBothOllamaAndModel() {
        #expect(state().cleanupReady)
        #expect(!state(ollamaApp: .missing).cleanupReady)
        #expect(!state(cleanupModel: .missing).cleanupReady)
        #expect(!state(ollamaApp: .missing, cleanupModel: .missing).cleanupReady)
    }

    // MARK: - cleanupActionTitle()

    @Test func cleanupActionTitleFullChainWhenNothingInstalled() {
        let title = state(ollamaApp: .missing, cleanupModel: .missing)
            .cleanupActionTitle(modelName: "qwen3:4b-instruct")
        #expect(title == "Install Ollama & download qwen3:4b-instruct…")
    }

    @Test func cleanupActionTitlePullOnlyWhenOllamaReadyButModelMissing() {
        let title = state(ollamaApp: .installed, cleanupModel: .missing)
            .cleanupActionTitle(modelName: "qwen3:4b-instruct")
        #expect(title == "Download qwen3:4b-instruct (~2.6 GB)…")
    }

    @Test func cleanupActionTitleStartOnlyWhenModelOnDiskButServerDown() {
        // Model already pulled, but Ollama's server isn't up — just start it.
        let title = state(ollamaApp: .missing, cleanupModel: .installed)
            .cleanupActionTitle(modelName: "qwen3:4b-instruct")
        #expect(title == "Start Ollama…")
    }

    @Test func cleanupActionTitleStartOnlyWhenOllamaOnDiskButServerDown() {
        // Ollama exists on disk (app bundle or Homebrew CLI) with the server
        // down: offer to start it — never to install alongside it. The model
        // may still need pulling, but that's only knowable once the server is
        // up, at which point the button becomes the pull variant.
        let title = state(ollamaApp: .missing, cleanupModel: .missing)
            .cleanupActionTitle(modelName: "qwen3:4b-instruct", ollamaOnDisk: true)
        #expect(title == "Start Ollama…")
    }

    @Test func cleanupActionTitleNilWhenReady() {
        #expect(state().cleanupActionTitle(modelName: "qwen3:4b-instruct") == nil)
    }

    @Test func cleanupActionTitleNilWhileBusy() {
        // A running chain must not offer a button that would race it.
        #expect(state(ollamaApp: .installing(stage: "Downloading Ollama", fraction: 0.3),
                      cleanupModel: .missing)
            .cleanupActionTitle(modelName: "qwen3:4b-instruct") == nil)
        #expect(state(ollamaApp: .installed,
                      cleanupModel: .installing(stage: "Pulling", fraction: nil))
            .cleanupActionTitle(modelName: "qwen3:4b-instruct") == nil)
    }

    // MARK: - InstallPhase.statusLine

    @Test func statusLineForEachPhase() {
        #expect(InstallPhase.missing.statusLine == "Not installed")
        #expect(InstallPhase.installed.statusLine == "Installed")
        #expect(InstallPhase.failed("disk full").statusLine == "Failed: disk full")
    }

    @Test func serverStatusLineUsesReachabilityWording() {
        // The Ollama row: a service's truth is reachability, not disk presence.
        #expect(InstallPhase.missing.serverStatusLine == "Not running")
        #expect(InstallPhase.installed.serverStatusLine == "Running")
        // Progress and failure states pass through the install wording.
        #expect(InstallPhase.installing(stage: "Starting Ollama", fraction: nil)
            .serverStatusLine == "Starting Ollama…")
        #expect(InstallPhase.failed("timeout").serverStatusLine == "Failed: timeout")
    }

    @Test func statusLineRendersPercentWhenFractionKnown() {
        #expect(InstallPhase.installing(stage: "Downloading Ollama", fraction: 0.42).statusLine
            == "Downloading Ollama — 42%")
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
