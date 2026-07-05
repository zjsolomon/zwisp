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
}
