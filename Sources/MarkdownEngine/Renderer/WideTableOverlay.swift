//
//  WideTableOverlay.swift
//  MarkdownEngine
//
//  NSScrollView subview of NativeTextView hosting a wide-table image with
//  native horizontal scrolling. Sidesteps TextKit 2's fragment surface
//  cache that defeats in-fragment custom scrolling.
//

import AppKit

// MARK: - Faint, hover-aware scroller

/// A horizontal scroller drawn with a fainter knob — same legacy behavior as the default
/// scroller, just a bit less visible.
final class SubtleScroller: NSScroller {
    override func drawKnobSlot(in slot: NSRect, highlight: Bool) {
        // Transparent track — only the knob is drawn.
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.width > 1, knob.height > 1 else { return }
        let thickness: CGFloat = 5
        let pill = knob.insetBy(dx: 2, dy: max(0, (knob.height - thickness) / 2))
        NSColor.secondaryLabelColor.withAlphaComponent(0.3).setFill()   // ← faintness; tweak here
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
    }
}

// MARK: - Overlay view

final class WideTableOverlay: NSScrollView {

    /// Hash of table source; key for offset persistence + reconcile lookup.
    let sourceID: Int

    /// Document index of the table anchor; click on image moves caret here.
    var anchorTextLocation: Int

    /// Weak parent ref for offset persistence + caret forwarding.
    weak var ownerTextView: NativeTextView?

    /// Left content inset = how far the table's left edge sits from the overlay's left
    /// edge (breakout mode: the text column's left edge). The inset area is scrollable
    /// space the table grows into when scrolled.
    var leftContentInset: CGFloat = 0 {
        didSet {
            guard abs(contentInsets.left - leftContentInset) > 0.5 else { return }
            contentInsets = NSEdgeInsets(top: 0, left: leftContentInset, bottom: 0, right: 0)
        }
    }

    private let tableImageView: WideTableImageView

    init(sourceID: Int, image: NSImage, ownerTextView: NativeTextView, anchorLocation: Int) {
        self.sourceID = sourceID
        self.anchorTextLocation = anchorLocation
        self.ownerTextView = ownerTextView
        self.tableImageView = WideTableImageView(frame: CGRect(origin: .zero, size: image.size))
        tableImageView.image = image
        tableImageView.imageScaling = .scaleNone
        tableImageView.imageAlignment = .alignTopLeft

        super.init(frame: .zero)

        hasHorizontalScroller = true
        hasVerticalScroller = false
        // Auto-hide: the breakout overlay also hosts tables that fit the full width (no
        // overflow), so only show the horizontal scroller when the table is actually wider.
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = false
        // Normal legacy scroller, just drawn with a fainter knob (see SubtleScroller).
        scrollerStyle = .legacy
        let subtleScroller = SubtleScroller()
        subtleScroller.scrollerStyle = .legacy
        horizontalScroller = subtleScroller
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        usesPredominantAxisScrolling = true
        horizontalScroller?.controlSize = .small
        automaticallyAdjustsContentInsets = false

        documentView = tableImageView
        tableImageView.ownerOverlay = self

        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollOffsetDidChange),
            name: NSScrollView.didLiveScrollNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollOffsetDidChange),
            name: NSScrollView.didEndLiveScrollNotification, object: self
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Clamp vertical scroll to 0 on every layout — kills sub-pixel wobble.
    override func tile() {
        super.tile()
        let origin = contentView.bounds.origin
        if origin.y != 0 {
            contentView.scroll(to: NSPoint(x: origin.x, y: 0))
            reflectScrolledClipView(contentView)
        }
    }

    /// Forward everything except clearly-horizontal events to the outer
    /// document scroll. Zero-delta phase/momentum lifecycle events count
    /// as "not horizontal" so the outer scroll view still receives the
    /// gesture-ended notifications it needs to stop cleanly.
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }


    /// Swap the rendered image after a restyle regenerated it.
    func updateImage(_ image: NSImage) {
        if tableImageView.image !== image {
            tableImageView.image = image
            tableImageView.frame = CGRect(origin: .zero, size: image.size)
        }
    }

    var horizontalOffset: CGFloat {
        get { contentView.bounds.origin.x }
        set {
            contentView.scroll(to: NSPoint(x: max(0, newValue), y: 0))
            reflectScrolledClipView(contentView)
        }
    }

    @objc private func scrollOffsetDidChange() {
        ownerTextView?.tableHorizontalScrollOffsets[sourceID] = horizontalOffset
    }
}

// MARK: - Document view inside the overlay

/// Forwards mouseDown to caret-into-table (so clicking switches to edit mode).
final class WideTableImageView: NSImageView {

    weak var ownerOverlay: WideTableOverlay?

    override func mouseDown(with event: NSEvent) {
        guard let overlay = ownerOverlay,
              let textView = overlay.ownerTextView else {
            super.mouseDown(with: event)
            return
        }
        let location = overlay.anchorTextLocation
        let docLen = (textView.string as NSString).length
        guard location >= 0, location <= docLen else {
            super.mouseDown(with: event)
            return
        }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }
}

// MARK: - NativeTextView reconcile extension

extension NativeTextView {

    /// Walk storage; create / position / destroy overlays to match attrs.
    func updateWideTableOverlays() {
        guard let storage = textStorage,
              let bridge = layoutBridge,
              let container = bridge.firstTextContainer,
              let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage else {
            removeAllWideTableOverlays()
            return
        }

        let containerWidth = container.size.width
        guard containerWidth.isFinite, containerWidth > 0 else { return }
        // Breakout mode (reading column): wide tables span the full view width and start
        // flush with the text column's left edge, scrolling into both margins.
        let breakout = configuration.readingWidth != nil
        let viewWidth = bounds.width

        var seenSourceIDs: Set<Int> = []
        let fullRange = NSRange(location: 0, length: storage.length)

        // Cheap presence-check first: skip the full-document layout pass when
        // the doc has no wide tables. enumerateAttribute stops on first hit.
        var hasAnyWideTable = false
        storage.enumerateAttribute(.scrollableBlockSourceID, in: fullRange, options: []) { value, _, stop in
            if value is Int { hasAnyWideTable = true; stop.pointee = true }
        }
        guard hasAnyWideTable else {
            removeAllWideTableOverlays()
            return
        }

        // Settle layout before measuring — stale fragments would yield wrong anchor Ys.
        tlm.ensureLayout(for: tlm.documentRange)

        storage.enumerateAttribute(.scrollableBlockSourceID, in: fullRange, options: []) { value, attrRange, _ in
            guard let sourceID = value as? Int,
                  let image = storage.attribute(.latexImage, at: attrRange.location, effectiveRange: nil) as? NSImage else { return }
            seenSourceIDs.insert(sourceID)

            if let start = tcs.location(tcs.documentRange.location, offsetBy: attrRange.location),
               let end = tcs.location(start, offsetBy: attrRange.length),
               let textRange = NSTextRange(location: start, end: end) {
                tlm.ensureLayout(for: textRange)
            }

            let anchorRect = bridge.boundingRect(forCharacterRange: attrRange, in: container)
            guard !anchorRect.isEmpty else { return }

            let totalHeight = (storage.attribute(.scrollableBlockTotalHeight, at: attrRange.location, effectiveRange: nil) as? CGFloat) ?? image.size.height
            let columnLeft = textContainerOrigin.x + anchorRect.minX
            let overlayFrame: NSRect = breakout
                ? NSRect(x: 0, y: textContainerOrigin.y + anchorRect.minY, width: viewWidth, height: totalHeight)
                : NSRect(x: columnLeft, y: textContainerOrigin.y + anchorRect.minY, width: containerWidth, height: totalHeight)
            // Breakout: start the table flush with the text column's left edge; the left
            // margin becomes scrollable space the table grows into.
            let leftContentInset: CGFloat = breakout ? max(0, columnLeft) : 0

            if let existing = wideTableOverlays[sourceID] {
                if !existing.frame.equalTo(overlayFrame) {
                    // Invalidate both old + new region so the vacated area redraws.
                    self.setNeedsDisplay(existing.frame)
                    existing.frame = overlayFrame
                    self.setNeedsDisplay(overlayFrame)
                }
                existing.leftContentInset = leftContentInset
                existing.updateImage(image)
                existing.anchorTextLocation = attrRange.location
            } else {
                let overlay = WideTableOverlay(
                    sourceID: sourceID, image: image,
                    ownerTextView: self, anchorLocation: attrRange.location
                )
                overlay.frame = overlayFrame
                overlay.leftContentInset = leftContentInset
                addSubview(overlay)
                wideTableOverlays[sourceID] = overlay
                let savedOffset = tableHorizontalScrollOffsets[sourceID] ?? 0
                if savedOffset > 0 { overlay.horizontalOffset = savedOffset }
            }
        }

        for (sourceID, overlay) in wideTableOverlays where !seenSourceIDs.contains(sourceID) {
            self.setNeedsDisplay(overlay.frame)
            overlay.removeFromSuperview()
            wideTableOverlays.removeValue(forKey: sourceID)
        }
    }

    /// Drop all overlays synchronously (file switch path).
    func removeAllWideTableOverlays() {
        for (_, overlay) in wideTableOverlays { overlay.removeFromSuperview() }
        wideTableOverlays.removeAll()
    }
}
