#if canImport(UIKit)
import SwiftUI
import UIKit

/// UIKit-backed code editor. `TextEditor` cannot report the caret, draw a line
/// gutter or provide a keyboard accessory bar, so the editor wraps a
/// `UITextView` with a scroll-synced gutter view.
struct PythonTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var cursor: EditorCursor
    let errorLine: Int?
    let autoClosesBrackets: Bool
    let autoClosesQuotes: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> CodeEditorContainerView {
        let container = CodeEditorContainerView()
        container.textView.delegate = context.coordinator
        container.textView.text = text
        container.textView.inputAccessoryView = context.coordinator.makeAccessoryToolbar()
        context.coordinator.container = container
        context.coordinator.applyHighlight()
        context.coordinator.updateGutterWidth()
        return container
    }

    func updateUIView(_ container: CodeEditorContainerView, context: Context) {
        context.coordinator.parent = self

        let textView = container.textView
        let errorChanged = context.coordinator.errorLine != errorLine
        context.coordinator.errorLine = errorLine

        if textView.text != text {
            let selection = textView.selectedRange
            textView.text = text
            let length = (text as NSString).length
            let location = min(selection.location, length)
            textView.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
            context.coordinator.applyHighlight()
            context.coordinator.updateGutterWidth()
        } else if errorChanged {
            context.coordinator.applyHighlight()
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PythonTextEditor
        weak var container: CodeEditorContainerView?
        var errorLine: Int?

        private var highlightTask: Task<Void, Never>?
        private var isApplyingHighlight = false

        init(parent: PythonTextEditor) {
            self.parent = parent
            self.errorLine = parent.errorLine
        }

        // MARK: Highlighting

        func scheduleHighlight() {
            highlightTask?.cancel()
            guard (container?.textView.text.count ?? 0) < 120_000 else { return }

            highlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
                self?.applyHighlight()
            }
        }

        func applyHighlight() {
            guard let textView = container?.textView, !isApplyingHighlight else { return }
            guard textView.markedTextRange == nil else { return }

            isApplyingHighlight = true
            defer { isApplyingHighlight = false }

            let text = textView.text ?? ""
            let storage = textView.textStorage
            let selection = textView.selectedRange

            if storage.length > 0 && storage.length < 120_000 {
                storage.beginEditing()
                storage.setAttributes(PythonSyntaxHighlighter.baseAttributes, range: NSRange(location: 0, length: storage.length))
                PythonSyntaxHighlighter.apply(to: storage, text: text)
                if let errorLine {
                    applyErrorHighlight(in: storage, text: text, line: errorLine)
                }
                storage.endEditing()
                textView.selectedRange = selection
            }

            textView.typingAttributes = PythonSyntaxHighlighter.baseAttributes
            container?.gutterView.errorLine = errorLine
            container?.gutterView.setNeedsDisplay()
        }

        /// Tints the whole failing line, matching the gutter marker.
        private func applyErrorHighlight(in storage: NSTextStorage, text: String, line: Int) {
            guard line > 0 else { return }
            let nsText = text as NSString
            var start = 0

            for _ in 1..<line {
                let searchRange = NSRange(location: start, length: nsText.length - start)
                let newline = nsText.range(of: "\n", options: [], range: searchRange)
                guard newline.location != NSNotFound else { return }
                start = newline.location + newline.length
            }

            guard start <= nsText.length else { return }
            let rest = NSRange(location: start, length: nsText.length - start)
            let newline = nsText.range(of: "\n", options: [], range: rest)
            let length = newline.location == NSNotFound ? rest.length : newline.location - start
            guard length > 0 else { return }

            storage.addAttribute(
                .backgroundColor,
                value: EditorTheme.errorBackground,
                range: NSRange(location: start, length: length)
            )
        }

        // MARK: Gutter

        func updateGutterWidth() {
            guard let container else { return }
            let lines = (container.textView.text ?? "").reduce(0) { $1 == "\n" ? $0 + 1 : $0 } + 1
            let digits = CGFloat(String(lines).count)
            let width = max(38, digits * EditorTheme.gutterDigitWidth + 18)

            if abs(container.gutterWidth - width) > 0.5 {
                container.gutterWidth = width
            }
            container.gutterView.setNeedsDisplay()
        }

        // MARK: Caret tracking

        private func publishCursor() {
            guard let textView = container?.textView else { return }

            let string = (textView.text ?? "") as NSString
            let range = textView.selectedRange
            let location = min(range.location, string.length)

            var line = 1
            var column = 1
            if location > 0 {
                let prefix = string.substring(to: location) as NSString
                line = prefix.components(separatedBy: "\n").count

                let lastNewline = prefix.range(of: "\n", options: .backwards)
                if lastNewline.location != NSNotFound {
                    column = location - (lastNewline.location + lastNewline.length) + 1
                } else {
                    column = location + 1
                }
            }

            let selectedLength = min(range.length, string.length - location)
            let selectedText = selectedLength > 0
                ? string.substring(with: NSRange(location: location, length: selectedLength))
                : ""

            let symbol = Self.symbol(at: location, in: string)
            let updated = EditorCursor(line: line, column: column, selectedText: selectedText, symbol: symbol)
            if parent.cursor != updated {
                parent.cursor = updated
            }
        }

        /// Returns the dotted identifier at (or immediately before) the caret so
        /// the Docs button can resolve `np.zeros`, `input`, etc.
        private static func symbol(at location: Int, in text: NSString) -> String? {
            guard text.length > 0 else { return nil }

            func isIdentifierUnit(_ unit: unichar) -> Bool {
                (unit >= 48 && unit <= 57)
                    || (unit >= 65 && unit <= 90)
                    || (unit >= 97 && unit <= 122)
                    || unit == 95
                    || unit == 46
            }

            var start = min(location, text.length)
            var end = start
            while start > 0 && isIdentifierUnit(text.character(at: start - 1)) { start -= 1 }
            while end < text.length && isIdentifierUnit(text.character(at: end)) { end += 1 }
            guard end > start else { return nil }

            var candidate = text.substring(with: NSRange(location: start, length: end - start))
            while candidate.hasPrefix(".") { candidate.removeFirst() }
            while candidate.hasSuffix(".") { candidate.removeLast() }

            guard let first = candidate.first, first.isLetter || first == "_" else { return nil }
            guard !candidate.contains("..") else { return nil }
            return candidate
        }

        // MARK: Keyboard accessory

        func makeAccessoryToolbar() -> UIToolbar {
            let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            toolbar.barStyle = .black
            toolbar.isTranslucent = true
            toolbar.tintColor = EditorTheme.caret
            toolbar.items = [
                UIBarButtonItem(systemItem: .flexibleSpace),
                UIBarButtonItem(title: "Tab", style: .plain, target: self, action: #selector(tabTapped)),
                UIBarButtonItem(
                    image: UIImage(systemName: "keyboard.chevron.compact.down"),
                    style: .plain,
                    target: self,
                    action: #selector(dismissTapped)
                ),
            ]
            return toolbar
        }

        @objc private func tabTapped() {
            container?.textView.insertText("    ")
        }

        @objc private func dismissTapped() {
            container?.textView.resignFirstResponder()
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            updateGutterWidth()
            publishCursor()
            scheduleHighlight()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            publishCursor()
            container?.gutterView.setNeedsDisplay()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            container?.gutterView.setNeedsDisplay()
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            // iPad keyboards and the accessory bar both send tabs; expand them
            // so pasted/runnable Python never fails on indentation.
            if text == "\t" {
                textView.insertText("    ")
                return false
            }

            guard range.length == 0, text.count == 1 else { return true }

            if parent.autoClosesQuotes, text == "\"" || text == "'" {
                return handleQuote(text, in: textView, at: range.location)
            }

            guard parent.autoClosesBrackets else { return true }

            let pairs: [String: String] = ["(": ")", "[": "]", "{": "}"]
            if let closer = pairs[text] {
                textView.insertText(text + closer)
                moveCaret(in: textView, to: range.location + 1)
                return false
            }

            if text == ")" || text == "]" || text == "}" {
                let existing = (textView.text ?? "") as NSString
                if range.location < existing.length,
                   existing.substring(with: NSRange(location: range.location, length: 1)) == text {
                    moveCaret(in: textView, to: range.location + 1)
                    return false
                }
            }

            return true
        }

        /// Mirrors the bracket behaviour for string literals: type the closing
        /// quote to step over an auto-inserted one, otherwise insert the pair
        /// and leave the caret inside it.
        private func handleQuote(_ quote: String, in textView: UITextView, at location: Int) -> Bool {
            let existing = (textView.text ?? "") as NSString
            let next = location < existing.length
                ? existing.substring(with: NSRange(location: location, length: 1))
                : ""

            if next == quote {
                moveCaret(in: textView, to: location + 1)
                return false
            }

            let previous = location > 0
                ? existing.substring(with: NSRange(location: location - 1, length: 1))
                : ""
            let preceding = previous.unicodeScalars.first
            let followsWord = preceding.map {
                CharacterSet.alphanumerics.contains($0) || $0 == "_"
            } ?? false

            // Don't pair the third quote of a triple-quoted string, or turn an
            // apostrophe after a word into `''`.
            if previous == quote || followsWord { return true }

            textView.insertText(quote + quote)
            moveCaret(in: textView, to: location + 1)
            return false
        }

        private func moveCaret(in textView: UITextView, to offset: Int) {
            guard let position = textView.position(from: textView.beginningOfDocument, offset: offset) else { return }
            textView.selectedTextRange = textView.textRange(from: position, to: position)
        }
    }
}

// MARK: - Container

final class CodeEditorContainerView: UIView {
    let gutterView = GutterView()
    let textView = PythonTextView()

    var gutterWidth: CGFloat = 44 {
        didSet {
            guard abs(gutterWidth - oldValue) > 0.5 else { return }
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = EditorTheme.background
        gutterView.textView = textView
        addSubview(gutterView)
        addSubview(textView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gutterView.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        textView.frame = CGRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: bounds.height)
    }
}

// MARK: - Text view

final class PythonTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = EditorTheme.background
        textColor = EditorTheme.text
        tintColor = EditorTheme.caret
        font = EditorTheme.font
        typingAttributes = PythonSyntaxHighlighter.baseAttributes

        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        keyboardAppearance = .dark
        keyboardDismissMode = .interactive

        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        contentInset = .zero
        textContainerInset = UIEdgeInsets(top: 14, left: 14, bottom: 48, right: 14)
        textContainer.lineFragmentPadding = 0

        showsVerticalScrollIndicator = true
        indicatorStyle = .white
        allowsEditingTextAttributes = false
    }
}

// MARK: - Line numbers

final class GutterView: UIView {
    weak var textView: PythonTextView? {
        didSet { setNeedsDisplay() }
    }

    var errorLine: Int? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = EditorTheme.gutterBackground
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        EditorTheme.gutterBackground.setFill()
        UIRectFill(bounds)

        EditorTheme.gutterSeparator.setFill()
        UIRectFill(CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height))

        let attributes: [NSAttributedString.Key: Any] = [
            .font: EditorTheme.gutterFont,
            .foregroundColor: EditorTheme.gutterText,
        ]

        guard let textView else { return }
        let layoutManager = textView.layoutManager
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0, textView.textStorage.length > 0 else {
            drawNumber(1, y: textView.textContainerInset.top, attributes: attributes)
            return
        }

        layoutManager.ensureLayout(for: textView.textContainer)
        let nsText = (textView.text ?? "") as NSString
        let originY = textView.textContainerInset.top - textView.contentOffset.y
        var lineNumber = 0

        layoutManager.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: glyphCount)
        ) { fragmentRect, _, _, glyphRange, _ in
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let startsLogicalLine = characterIndex == 0
                || (characterIndex > 0
                    && characterIndex < nsText.length
                    && nsText.character(at: characterIndex - 1) == 10)
            guard startsLogicalLine else { return }

            lineNumber += 1
            let y = originY + fragmentRect.minY
            guard y > -30, y < self.bounds.height else { return }

            if self.errorLine == lineNumber {
                EditorTheme.error.setFill()
                UIBezierPath(
                    roundedRect: CGRect(
                        x: 4,
                        y: y + 1,
                        width: 3,
                        height: max(4, fragmentRect.height - 2)
                    ),
                    cornerRadius: 1.5
                ).fill()
            }

            self.drawNumber(lineNumber, y: y, attributes: attributes)
        }
    }

    private func drawNumber(_ number: Int, y: CGFloat, attributes: [NSAttributedString.Key: Any]) {
        let label = "\(number)" as NSString
        let size = label.size(withAttributes: attributes)
        let lineHeight = EditorTheme.gutterFont.lineHeight
        let point = CGPoint(
            x: bounds.width - 10 - size.width,
            y: y + max(0, (lineHeight - size.height) / 2)
        )
        label.draw(at: point, withAttributes: attributes)
    }
}
#endif
