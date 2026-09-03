//
//  MarkdownTokenizer.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// The token namespace. Tokens are produced by `parseTokensViaAST`
// (`BlockScopedTokenizer`): block structure + block-level tokens come from
// `BlockParser` + `BlockLevelTokenizer` (hand scanners, no regex), inline
// tokens from the AST (`InlineParser` → `InlineASTAdapter`). This file keeps
// only the code-block language helper.
import Foundation

// MARK: - Tokenizer
enum MarkdownTokenizer {

    // MARK: - Code Block Helpers

    static func extractLanguage(from token: MarkdownToken, in text: String) -> String? {
        guard token.kind == .codeBlock,
              let openingMarker = token.markerRanges.first else { return nil }

        let nsText = text as NSString
        let end = min(NSMaxRange(openingMarker), nsText.length)
        // The open fence may sit behind up to 3 leading spaces/tabs; the language
        // is whatever follows its backtick run.
        var i = openingMarker.location
        var indent = 0
        while i < end, indent < 3,
              nsText.character(at: i) == 0x20 || nsText.character(at: i) == 0x09 { i += 1; indent += 1 }
        while i < end, nsText.character(at: i) == 0x60 { i += 1 }
        guard i < end else { return nil }

        let langString = nsText.substring(with: NSRange(location: i, length: end - i))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return langString.isEmpty ? nil : langString
    }
}
