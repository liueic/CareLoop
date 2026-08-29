import Foundation
@testable import CareLoop
import Testing

struct StreamingReplyExtractorTests {
    @Test func jsonReplyStreamedIncrementally() {
        var extractor = StreamingReplyExtractor()
        let chunks: [String] = [
            "{\"rep", "ly\":\"", "今天可以", "试试清蒸", "鲈鱼\",\"cited", "RecipeIDs\":", "[\"r-1\"]}",
        ]
        let visible = chunks.map { extractor.feed($0) }.joined()
        #expect(visible == "今天可以试试清蒸鲈鱼")
    }

    @Test func escapedQuotesAndNewlines() {
        var extractor = StreamingReplyExtractor()
        let output = extractor.feed(#"{"reply":"先看\"血压\"记录\n再决定"}"#)
        #expect(output == "先看\"血压\"记录\n再决定")
    }

    @Test func unicodeEscapeAndSurrogatePair() {
        var extractor = StreamingReplyExtractor()
        // \u4e2d → 中，\u6587 → 文，🍚 是代理对 \ud83c\udf5a
        let output = extractor.feed(#"{"reply":"\u4e2d\u6587 \ud83c\udf5a 好"}"#)
        #expect(output == "中文 🍚 好")
    }

    @Test func surrogatePairSplitAcrossChunks() {
        var extractor = StreamingReplyExtractor()
        let held = extractor.feed(#"{"reply":"\ud83c"#)
        #expect(held.isEmpty)
        let released = extractor.feed(#"\udf5a 粥"}"#)
        #expect(released == "🍚 粥")
    }

    @Test func plainTextPassthrough() {
        var extractor = StreamingReplyExtractor()
        let first = extractor.feed("今天吃点")
        let second = extractor.feed("清淡的")
        #expect(first + second == "今天吃点清淡的")
    }

    @Test func plainTextChunkByChunk() {
        var extractor = StreamingReplyExtractor()
        let text = "清蒸鲈鱼配杂粮饭，少盐少油。"
        var collected = ""
        for character in text {
            collected += extractor.feed(String(character))
        }
        #expect(collected == text)
    }

    @Test func fencedJson() {
        var extractor = StreamingReplyExtractor()
        let fenceOnly = extractor.feed("```json\n")
        #expect(fenceOnly.isEmpty)
        let output = extractor.feed(#"{"reply":"少盐为主"}"#)
        #expect(output == "少盐为主")
    }

    @Test func keyWithSpaceBeforeColon() {
        var extractor = StreamingReplyExtractor()
        let output = extractor.feed(#"{"reply" : "带空格"}"#)
        #expect(output == "带空格")
    }

    @Test func valueMentioningReplyLiteral() {
        var extractor = StreamingReplyExtractor()
        let output = extractor.feed(#"{"reply":"字段 \"reply\" 就是这个"}"#)
        #expect(output == #"字段 "reply" 就是这个"#)
    }

    @Test func truncatedOpenStringEmitsPartial() {
        var extractor = StreamingReplyExtractor()
        let output = extractor.feed(#"{"reply":"被截断的内"#)
        #expect(output == "被截断的内")
    }

    @Test func replyKeyAfterOtherFields() {
        var extractor = StreamingReplyExtractor()
        let output = extractor.feed(#"{"citedClauseIDs":[],"reply":"后置键"}"#)
        #expect(output == "后置键")
    }

    @Test func emptyAndWhitespaceOnlyChunksHoldEmission() {
        var extractor = StreamingReplyExtractor()
        #expect(extractor.feed("   ").isEmpty)
        #expect(extractor.feed("\n").isEmpty)
        let output = extractor.feed(#"{"reply":"开始"}"#)
        #expect(output == "开始")
    }
}
