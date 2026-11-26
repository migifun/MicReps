import AppKit
import SwiftUI

/// 文字起こしの本文。ドラッグで選択してコピーでき、クリックするとその文から再生する。
struct TranscriptTextView: NSViewRepresentable {
    let sentences: [Sentence]
    var fillers: [SpeakingAnalysis.Filler] = []
    let currentIndex: Int?
    /// nil なら押しても再生しない(コピー用)。
    let onSelect: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ClickableTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.setAccessibilityLabel("文字起こし")

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.show(sentences)
        coordinator.mark(fillers)
        coordinator.highlight(currentIndex)
        coordinator.textView?.onClick = onSelect.map { onSelect in
            { [weak coordinator] location in
                if let index = coordinator?.sentence(at: location) { onSelect(index) }
            }
        }
    }

    @MainActor
    final class Coordinator {
        weak var textView: ClickableTextView?
        private var sentences: [Sentence] = []
        private(set) var ranges: [NSRange] = []
        private var highlighted: Int?
        private var marked: [SpeakingAnalysis.Filler] = []
        private var markedRanges: [NSRange] = []

        func show(_ newValue: [Sentence]) {
            guard newValue != sentences, let storage = textView?.textStorage else { return }
            sentences = newValue
            highlighted = nil
            marked = []
            markedRanges = []
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.paragraphSpacing = 6
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
            ]
            ranges = []
            var location = 0
            for sentence in sentences {
                let length = (sentence.text as NSString).length
                ranges.append(NSRange(location: location, length: length))
                location += length + 1
            }
            let text = sentences.map(\.text).joined(separator: "\n")
            storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            textView?.scrollToBeginningOfDocument(nil)
        }

        /// フィラーに下線を引き、色を変える。
        func mark(_ fillers: [SpeakingAnalysis.Filler]) {
            guard fillers != marked, let storage = textView?.textStorage else { return }
            for range in markedRanges where NSMaxRange(range) <= storage.length {
                storage.removeAttribute(.underlineStyle, range: range)
                storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
            marked = fillers
            markedRanges = fillers.compactMap { filler in
                guard sentences.indices.contains(filler.sentence) else { return nil }
                let text = sentences[filler.sentence].text
                guard let from = text.index(text.startIndex, offsetBy: filler.offset, limitedBy: text.endIndex),
                      let to = text.index(from, offsetBy: filler.length, limitedBy: text.endIndex) else { return nil }
                let local = NSRange(from..<to, in: text)
                return NSRange(location: ranges[filler.sentence].location + local.location, length: local.length)
            }
            for (range, filler) in zip(markedRanges, fillers) where NSMaxRange(range) <= storage.length {
                storage.addAttributes([
                    .underlineStyle: (filler.isCertain ? NSUnderlineStyle.thick : [.single, .patternDot]).rawValue,
                    .underlineColor: NSColor.systemYellow,
                    .foregroundColor: NSColor.systemBrown,
                ], range: range)
            }
        }

        func highlight(_ index: Int?) {
            guard index != highlighted, let textView, let storage = textView.textStorage else { return }
            if let highlighted, ranges.indices.contains(highlighted) {
                storage.removeAttribute(.backgroundColor, range: ranges[highlighted])
            }
            highlighted = index
            guard let index, ranges.indices.contains(index) else { return }
            storage.addAttribute(
                .backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.22), range: ranges[index]
            )
            // 再生中も、章やバーで移動したときも、その文が見えるようにする。選択中は動かさない。
            if textView.selectedRange().length == 0 { textView.scrollRangeToVisible(ranges[index]) }
        }

        func sentence(at location: Int) -> Int? {
            ranges.lastIndex { $0.location <= location && location <= NSMaxRange($0) }
        }
    }
}

final class ClickableTextView: NSTextView {
    var onClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let hadSelection = selectedRange().length > 0
        // superはボタンを離すまで戻らない。戻った時点で選択が無ければ、ドラッグではなくクリック。
        super.mouseDown(with: event)
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.clickCount == 1, modifiers.isEmpty, selectedRange().length == 0 else { return }
        // 選択を解除するためのクリックでは、再生を始めない。
        guard !hadSelection else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard isInsideText(point) else { return }
        onClick?(characterIndexForInsertion(at: point))
    }

    /// 本文より下の余白を押したときは動かさない。
    private func isInsideText(_ point: NSPoint) -> Bool {
        guard let layout = textLayoutManager else { return true }
        return point.y <= layout.usageBoundsForTextContainer.maxY + textContainerOrigin.y
    }
}
