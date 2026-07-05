import Foundation

/// Pure knowledge of *where WhisperKit stores a downloaded model on disk* and
/// *what makes that download complete*. Kept here, dependency-free and tested,
/// so the installer (app layer) can decide "is the speech model already
/// present?" without dragging WhisperKit into the check — there is no public
/// is-downloaded API, so we inspect the folder ourselves.
public enum SpeechModelLayout {
    /// The `.mlmodelc` bundles WhisperKit's `loadModels` requires before it can
    /// transcribe. A folder missing any of these is a partial/aborted download
    /// (HubApi writes per-file), so loading it would fail — treat it as absent
    /// and re-download rather than half-load.
    public static let requiredBundles: Set<String> = [
        "MelSpectrogram.mlmodelc",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
    ]

    /// WhisperKit downloads into
    /// `<documents>/huggingface/models/argmaxinc/whisperkit-coreml/<variant>/`.
    /// Mirrors WhisperKit's own path construction so we point at the exact
    /// folder it will use — don't change the base, or existing installs orphan.
    public static func modelFolderPath(documentsPath: String, variant: String) -> String {
        (documentsPath as NSString)
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
            .appending("/\(variant)")
    }

    /// Whether the folder's direct contents contain every required bundle.
    /// Extra files (tokenizer, config, other variants' leftovers) are ignored;
    /// only the presence of all three `.mlmodelc` bundles matters.
    public static func isComplete(folderContents: Set<String>) -> Bool {
        requiredBundles.isSubset(of: folderContents)
    }
}
