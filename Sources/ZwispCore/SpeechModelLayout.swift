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

    /// A human name for a WhisperKit variant, for the UI:
    /// `openai_whisper-large-v3-v20240930_turbo` → `Whisper large-v3 turbo`.
    /// The raw variant is a repo path — publisher prefix, release datestamp,
    /// underscores — none of which a person needs to read. Anything that
    /// doesn't match the known shapes falls through to the variant itself, so
    /// an unrecognised model still names itself rather than showing blank.
    public static func displayName(variant: String) -> String {
        var name = variant
        // Publisher prefix (`openai_whisper-…`, `distil-whisper_distil-…`).
        for publisher in ["openai_", "argmaxinc_"] where name.hasPrefix(publisher) {
            name.removeFirst(publisher.count)
        }
        name = strippingDatestamp(from: name)
        name = name.replacingOccurrences(of: "_", with: " ")
        // Capitalize the family, which is now the leading word.
        for (family, pretty) in [("whisper-", "Whisper "),
                                 ("distil-whisper ", "Distil-Whisper ")]
        where name.hasPrefix(family) {
            name = pretty + name.dropFirst(family.count)
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? variant : trimmed
    }

    /// Drops a `-vYYYYMMDD` release stamp (e.g. `-v20240930`) anywhere in the
    /// variant. It identifies the upload, not the model, and only clutters the
    /// name.
    private static func strippingDatestamp(from name: String) -> String {
        var result = name
        var index = result.startIndex
        while let marker = result.range(of: "-v", range: index..<result.endIndex) {
            let digits = result[marker.upperBound...].prefix(8)
            if digits.count == 8, digits.allSatisfy(\.isNumber) {
                result.removeSubrange(marker.lowerBound..<result.index(marker.upperBound, offsetBy: 8))
                index = marker.lowerBound
            } else {
                index = marker.upperBound
            }
        }
        return result
    }
}
