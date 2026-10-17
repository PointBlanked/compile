// Owner: Maxwell. Voice intent parsing and Deepgram message handling.

import Foundation
import Testing
@testable import EchoGuideInfra

@Suite struct VoiceTests {
    @Test func findIntents() {
        #expect(VoiceIntent.parse("Find the start button.") == .find("start button"))
        #expect(VoiceIntent.parse("where's the kettle") == .find("kettle"))
        #expect(VoiceIntent.parse("Find my keys") == .find("keys"))
    }

    @Test func stopAndQuestions() {
        #expect(VoiceIntent.parse("Stop!") == .stop)
        #expect(VoiceIntent.parse("What does this say?") == .question("What does this say?"))
        #expect(VoiceIntent.parse("   ") == nil)
    }

    @Test func deepgramResults() {
        let msg = #"{"type":"Results","is_final":true,"speech_final":true,"channel":{"alternatives":[{"transcript":"find the kettle","confidence":0.98}]}}"#
        #expect(DeepgramMessage.transcript(from: Data(msg.utf8)) == Transcript(text: "find the kettle", isFinal: true, endOfUtterance: true))
    }

    @Test func deepgramIgnoresMetadataAndSilence() {
        #expect(DeepgramMessage.transcript(from: Data(#"{"type":"Metadata"}"#.utf8)) == nil)
        let empty = #"{"type":"Results","channel":{"alternatives":[{"transcript":""}]}}"#
        #expect(DeepgramMessage.transcript(from: Data(empty.utf8)) == nil)
    }
}
