//
//  NativeTextView+CursorRects.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 27.05.26.
//
//  Read-only cursor handling: arrow over text, pointing hand over links.
//

import AppKit

extension NativeTextView {

    override func mouseMoved(with event: NSEvent) {
        guard !suppressesCursor else { return }   // an overlay above owns the pointer
        super.mouseMoved(with: event)
        applyReadOnlyCursor(for: event)
    }

    override func mouseEntered(with event: NSEvent) {
        guard !suppressesCursor else { return }
        super.mouseEntered(with: event)
        applyReadOnlyCursor(for: event)
    }

    /// Don't set a cursor on cursorUpdate either while suppressed (the I-beam rect
    /// itself is dropped in `resetCursorRects`, in NativeTextView.swift).
    override func cursorUpdate(with event: NSEvent) {
        guard !suppressesCursor else { return }
        super.cursorUpdate(with: event)
    }

    /// Cursor affordance over links. In read-only mode we fully own the cursor
    /// (pointing hand over a `.link`, arrow elsewhere). In editable PREVIEW
    /// (markers hidden) the text is still editable, so we keep the I-beam over
    /// ordinary text and only raise the pointing hand over a clickable link —
    /// matching the plain-click link follow in `followLinkIfHit`.
    private func applyReadOnlyCursor(for event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let overLink = isOverLink(at: viewPoint)
        if !isEditable {
            guard isSelectable else { return }
            (overLink ? NSCursor.pointingHand : NSCursor.arrow).set()
        } else if configuration.markerVisibility == .allHidden, overLink {
            NSCursor.pointingHand.set()
        }
    }

    /// True when a clickable `.link` attribute exists under the given point
    /// (view coordinates). `.link` is what drives `clickedOnLink`, so this
    /// matches exactly what is clickable.
    private func isOverLink(at viewPoint: CGPoint) -> Bool {
        linkHit(at: viewPoint) != nil
    }

    /// The `.link` attribute value and its DOCUMENT character index under the
    /// given point (view coordinates), or `nil` if no link is there. Used both
    /// for the hover cursor and to drive a click through to `clickedOnLink`.
    func linkHit(at viewPoint: CGPoint) -> (index: Int, link: Any)? {
        guard let tlm = textLayoutManager,
              let textStorage = textStorage, textStorage.length > 0 else { return nil }

        let containerPoint = CGPoint(x: viewPoint.x - textContainerOrigin.x,
                                     y: viewPoint.y - textContainerOrigin.y)
        guard let fragment = tlm.textLayoutFragment(for: containerPoint) else { return nil }

        let fragFrame = fragment.layoutFragmentFrame
        let pInFrag = CGPoint(x: containerPoint.x - fragFrame.minX,
                              y: containerPoint.y - fragFrame.minY)
        // Walk the fragment's line fragments, tracking each one's offset from
        // the fragment start, so a hit maps back to a document index (not just
        // a line-local one). Only accept a line that actually contains the
        // point — guards against clicks in trailing padding / past line end.
        var lineLocalBase = 0
        var hitLine: NSTextLineFragment?
        for lf in fragment.textLineFragments {
            if lf.typographicBounds.contains(pInFrag) { hitLine = lf; break }
            lineLocalBase += lf.attributedString.length
        }
        guard let line = hitLine else { return nil }

        let pInLine = CGPoint(x: pInFrag.x - line.typographicBounds.minX,
                              y: pInFrag.y - line.typographicBounds.minY)
        let localIdx = line.characterIndex(for: pInLine)
        guard localIdx >= 0, localIdx < line.attributedString.length else { return nil }

        let fragStart = tlm.offset(from: tlm.documentRange.location, to: fragment.rangeInElement.location)
        let docIdx = fragStart + lineLocalBase + localIdx
        guard docIdx >= 0, docIdx < textStorage.length else { return nil }
        guard let link = textStorage.attribute(.link, at: docIdx, effectiveRange: nil) else { return nil }
        return (docIdx, link)
    }
}
