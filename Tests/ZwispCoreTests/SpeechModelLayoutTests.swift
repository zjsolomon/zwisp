import Testing
@testable import ZwispCore

struct SpeechModelLayoutTests {
    // MARK: - modelFolderPath()

    @Test func pathComposesHuggingFaceLayoutUnderDocuments() {
        let path = SpeechModelLayout.modelFolderPath(
            documentsPath: "/Users/me/Documents",
            variant: "openai_whisper-large-v3-v20240930_turbo")
        #expect(path == "/Users/me/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo")
    }

    // MARK: - isComplete()

    @Test func completeRequiresAllThreeBundles() {
        #expect(SpeechModelLayout.isComplete(folderContents: [
            "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
        ]))
    }

    @Test func incompleteWhenAnyRequiredBundleIsMissing() {
        // A partial/aborted download: TextDecoder never finished.
        #expect(!SpeechModelLayout.isComplete(folderContents: [
            "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc",
        ]))
    }

    @Test func extraFilesDoNotConfuseTheCheck() {
        // Tokenizer/config leftovers alongside the bundles are fine.
        #expect(SpeechModelLayout.isComplete(folderContents: [
            "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
            "config.json", "tokenizer.json", "generation_config.json",
        ]))
    }

    @Test func emptyFolderIsIncomplete() {
        #expect(!SpeechModelLayout.isComplete(folderContents: []))
    }

    // MARK: - displayName()

    @Test func displayNameCleansTheShippedDefault() {
        // The default: publisher prefix, release datestamp, and an underscore
        // all disappear.
        #expect(SpeechModelLayout.displayName(
            variant: "openai_whisper-large-v3-v20240930_turbo") == "Whisper large-v3 turbo")
    }

    @Test func displayNameCleansTheDocumentedAlternatives() {
        #expect(SpeechModelLayout.displayName(
            variant: "openai_whisper-small.en") == "Whisper small.en")
        #expect(SpeechModelLayout.displayName(
            variant: "openai_whisper-base.en") == "Whisper base.en")
        #expect(SpeechModelLayout.displayName(
            variant: "distil-whisper_distil-large-v3_turbo")
            == "Distil-Whisper distil-large-v3 turbo")
    }

    @Test func displayNameKeepsVersionSuffixesThatArentDatestamps() {
        // "-v3" is the model generation, not a release stamp — only an 8-digit
        // date is dropped.
        #expect(SpeechModelLayout.displayName(
            variant: "openai_whisper-large-v3") == "Whisper large-v3")
        #expect(SpeechModelLayout.displayName(
            variant: "openai_whisper-large-v2") == "Whisper large-v2")
    }

    @Test func displayNameFallsBackToTheVariantWhenUnrecognised() {
        // An unknown model still names itself rather than rendering blank.
        #expect(SpeechModelLayout.displayName(variant: "some-new-model")
                == "some-new-model")
        #expect(SpeechModelLayout.displayName(variant: "") == "")
    }
}
