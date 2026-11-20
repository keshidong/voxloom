import SpeechFoundation
import Testing

struct RecognitionValueTests {
    @Test func optionsAndTranscriptPreserveUserLanguageAndText() {
        #expect(RecognitionOptions().language == .automatic)
        let options = RecognitionOptions(language: .chinese, context: "RxSwift API")
        #expect(options.context == "RxSwift API")
        #expect(options.language.rawValue == "zh")
        #expect(RecognitionLanguage.english.rawValue == "en")
        #expect(RecognitionLanguage.allCases.count == 3)
        #expect(Transcript(text: "中文 English", language: "zh").text == "中文 English")
        #expect(Transcript(text: "").language == nil)
    }
}
