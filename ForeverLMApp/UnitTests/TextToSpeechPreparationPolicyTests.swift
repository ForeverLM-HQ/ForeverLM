import Testing
@testable import ForeverLM

@Suite("Text to Speech Preparation Policy")
struct TextToSpeechPreparationPolicyTests {

    @Test("papers, articles, books and courses are always prepared, whatever they contain")
    func readableTypesAlways() {
        for type in ["paper", "article", "book", "course"] {
            #expect(TextToSpeechPreparationPolicy.usesAIPreparation(sourceType: type))
        }
    }

    @Test("types that never narrate through the pass stay out of it")
    func otherTypesNeverPrepared() {
        #expect(!TextToSpeechPreparationPolicy.usesAIPreparation(sourceType: "manual"))
    }

    @Test("a spoken script is read as it stands")
    func spokenScriptIsNotPrepared() {
        let url = TextToSpeechPreparationPolicy.spokenScriptURLPrefix + "abc"
        #expect(!TextToSpeechPreparationPolicy.usesAIPreparation(sourceType: "article", url: url))
    }
}
