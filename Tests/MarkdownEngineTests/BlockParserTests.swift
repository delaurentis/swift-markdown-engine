//
//  BlockParserTests.swift
//  MarkdownEngineTests
//
//  Phase 1 — test-first specification of the block-structure pass. Each test
//  pins an exact, tiling block decomposition (every UTF-16 unit covered once).
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 1 — block parser")
struct BlockParserTests {

    private func b(_ kind: BlockKind, _ location: Int, _ length: Int) -> Block {
        Block(kind: kind, range: NSRange(location: location, length: length))
    }

    /// Sanity: the parsed blocks must tile `text` with no gaps or overlaps.
    private func assertTiles(_ text: String) {
        let blocks = BlockParser.parse(text)
        let total = (text as NSString).length
        guard total > 0 else { return }
        var cursor = 0
        for block in blocks {
            #expect(block.range.location == cursor, "gap/overlap before \(block)")
            cursor = NSMaxRange(block.range)
        }
        #expect(cursor == total, "blocks do not cover the whole string")
    }

    @Test("single line is one paragraph")
    func singleParagraph() {
        #expect(BlockParser.parse("hello world") == [b(.paragraph, 0, 11)])
    }

    @Test("blank line separates blocks and the result tiles the whole string")
    func blankSeparates() {
        let text = "a\n\nb"
        #expect(BlockParser.parse(text) == [b(.paragraph, 0, 2), b(.blank, 2, 1), b(.paragraph, 3, 1)])
        assertTiles(text)
    }

    @Test("consecutive plain lines merge into one paragraph")
    func mergedParagraph() {
        #expect(BlockParser.parse("a\nb\nc") == [b(.paragraph, 0, 5)])
    }

    @Test("ATX heading is its own block")
    func heading() {
        let text = "# Title\n\nbody"
        #expect(BlockParser.parse(text) == [b(.heading, 0, 8), b(.blank, 8, 1), b(.paragraph, 9, 4)])
        assertTiles(text)
    }

    @Test("thematic break is its own block")
    func thematicBreak() {
        let text = "a\n\n---\n\nb"
        #expect(BlockParser.parse(text) == [
            b(.paragraph, 0, 2), b(.blank, 2, 1), b(.thematicBreak, 3, 4), b(.blank, 7, 1), b(.paragraph, 8, 1),
        ])
        assertTiles(text)
    }

    @Test("fenced code block is a single opaque block")
    func fencedCode() {
        #expect(BlockParser.parse("```\ncode\n```\n") == [b(.fencedCode, 0, 13)])
    }

    @Test("a fence indented up to 3 spaces still opens/closes a code block")
    func indentedFence() {
        let text = "   ```bash\n   cmd\n   ```\n"
        #expect(BlockParser.parse(text) == [b(.fencedCode, 0, (text as NSString).length)])
        assertTiles(text)
    }

    @Test("indented fence parts: language extracted, both fences are markers")
    func indentedFenceParts() {
        let text = "   ```bash\n   cmd\n   ```\n" as NSString
        let parts = MarkdownASTStyler.codeBlockParts(NSRange(location: 0, length: text.length), text)
        #expect(parts.language == "bash")
        #expect(parts.openFence == NSRange(location: 0, length: 11))    // "   ```bash\n"
        #expect(parts.closeFence == NSRange(location: 18, length: 6))   // "   ```"
        #expect(parts.content == NSRange(location: 11, length: 7))      // "   cmd\n"
    }

    @Test("consecutive blockquote lines form one block, ended by a non-quote line")
    func blockquote() {
        let text = "> a\n> b\nc"
        #expect(BlockParser.parse(text) == [b(.blockquote, 0, 8), b(.paragraph, 8, 1)])
        assertTiles(text)
    }
}
