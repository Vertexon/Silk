#if canImport(UIKit)
import UIKit

enum EditorTheme {
    static let background = UIColor(red: 0.075, green: 0.082, blue: 0.098, alpha: 1)
    static let text = UIColor(red: 0.90, green: 0.91, blue: 0.93, alpha: 1)
    static let keyword = UIColor(red: 1.00, green: 0.45, blue: 0.69, alpha: 1)
    static let builtin = UIColor(red: 0.46, green: 0.82, blue: 1.00, alpha: 1)
    static let string = UIColor(red: 0.56, green: 0.89, blue: 0.59, alpha: 1)
    static let comment = UIColor(white: 0.46, alpha: 1)
    static let number = UIColor(red: 1.00, green: 0.71, blue: 0.42, alpha: 1)
    static let decorator = UIColor(red: 0.80, green: 0.61, blue: 1.00, alpha: 1)
    static let functionName = UIColor(red: 0.98, green: 0.84, blue: 0.45, alpha: 1)
    static let className = UIColor(red: 0.45, green: 0.90, blue: 0.86, alpha: 1)
    static let constant = UIColor(red: 0.62, green: 0.78, blue: 1.00, alpha: 1)
    static let selfKeyword = UIColor(red: 0.98, green: 0.62, blue: 0.45, alpha: 1)
    static let magic = UIColor(red: 0.74, green: 0.62, blue: 1.00, alpha: 1)
    static let caret = UIColor(red: 0.36, green: 0.78, blue: 0.98, alpha: 1)
    static let error = UIColor(red: 1.00, green: 0.36, blue: 0.38, alpha: 1)
    static let errorBackground = UIColor(red: 1.00, green: 0.30, blue: 0.32, alpha: 0.16)

    static let gutterBackground = UIColor(red: 0.090, green: 0.098, blue: 0.115, alpha: 1)
    static let gutterSeparator = UIColor(white: 1, alpha: 0.06)
    static let gutterText = UIColor(white: 0.42, alpha: 1)

    static let font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    static let gutterFont = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    static var gutterDigitWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: gutterFont]).width
    }
}

/// Lightweight Python tokenizer used to tint the editor. This is intentionally
/// regex-based: it runs on a debounce, caps document size, and only changes
/// attributes so the text, selection and undo stack stay intact.
enum PythonSyntaxHighlighter {
    static let baseAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2.5
        paragraph.paragraphSpacing = 3
        paragraph.defaultTabInterval = 28
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 28)]
        return [
            .font: EditorTheme.font,
            .foregroundColor: EditorTheme.text,
            .paragraphStyle: paragraph,
            .ligature: 0,
        ]
    }()

    private static let keywords = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break",
        "class", "continue", "def", "del", "elif", "else", "except", "finally",
        "for", "from", "global", "if", "import", "in", "is", "lambda", "match",
        "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with",
        "yield", "case",
    ]

    private static let builtins = [
        "abs", "all", "any", "bool", "bytes", "dict", "enumerate", "filter", "float",
        "format", "input", "int", "isinstance", "len", "list", "map", "max", "min",
        "open", "print", "range", "repr", "reversed", "round", "set", "sorted",
        "str", "sum", "super", "tuple", "type", "zip",
    ]

    private static let keywordRegex = try? NSRegularExpression(
        pattern: "\\b(?:\(keywords.joined(separator: "|")))\\b"
    )

    private static let builtinRegex = try? NSRegularExpression(
        pattern: "\\b(?:\(builtins.joined(separator: "|")))\\b"
    )

    private static let constantRegex = try? NSRegularExpression(
        pattern: "\\b(?:True|False|None)\\b"
    )

    private static let selfRegex = try? NSRegularExpression(
        pattern: "\\b(?:self|cls)\\b"
    )

    private static let functionNameRegex = try? NSRegularExpression(
        pattern: "\\bdef\\s+([A-Za-z_][A-Za-z0-9_]*)"
    )

    private static let classNameRegex = try? NSRegularExpression(
        pattern: "\\bclass\\s+([A-Za-z_][A-Za-z0-9_]*)"
    )

    private static let magicRegex = try? NSRegularExpression(
        pattern: "\\b__[A-Za-z0-9_]+__\\b"
    )

    private static let numberRegex = try? NSRegularExpression(
        pattern: "(?<![\\w.])(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?[jJ]?)(?![\\w.])"
    )

    private static let decoratorRegex = try? NSRegularExpression(
        pattern: "(?m)^[ \\t]*@[A-Za-z_][A-Za-z0-9_.]*"
    )

    private static let stringRegex = try? NSRegularExpression(
        pattern: "(?s)\"\"\"(?:.|\\n)*?\"\"\"|'''(?:.|\\n)*?'''|\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*'"
    )

    private static var commentAttributes: [NSAttributedString.Key: Any] {
        let descriptor = EditorTheme.font.fontDescriptor.withSymbolicTraits(.traitItalic)
        let font = descriptor.map { UIFont(descriptor: $0, size: EditorTheme.font.pointSize) } ?? EditorTheme.font
        return [.foregroundColor: EditorTheme.comment, .font: font]
    }

    static func apply(to storage: NSTextStorage, text: String) {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        guard fullRange.length > 0 else { return }

        apply(keywordRegex, in: storage, text: text, range: fullRange, attributes: [.foregroundColor: EditorTheme.keyword])
        apply(constantRegex, in: storage, text: text, range: fullRange, attributes: [.foregroundColor: EditorTheme.constant])
        apply(builtinRegex, in: storage, text: text, range: fullRange, attributes: [.foregroundColor: EditorTheme.builtin])
        apply(selfRegex, in: storage, text: text, range: fullRange, attributes: [.foregroundColor: EditorTheme.selfKeyword])
        applyFirstGroup(functionNameRegex, in: storage, text: text, range: fullRange, attributes: [.foregroundColor: EditorTheme.functionName])
        applyFirstGroup(classNameRegex, in: storage, text: text, range: fullRange, attributes: [.foregroundColor: EditorTheme.className])
        apply(magicRegex, in: storage, text: text, range: fullRange, attributes: [.foregroundColor: EditorTheme.magic])
        apply(numberRegex, in: storage, text: text, range: fullRange, attributes: [.foregroundColor: EditorTheme.number])
        apply(decoratorRegex, in: storage, text: text, range: fullRange, attributes: [.foregroundColor: EditorTheme.decorator])

        // Strings next so keywords and `#` inside a literal keep the string
        // color; comments are applied last so quotes inside them stay gray.
        let stringRanges = ranges(of: stringRegex, in: text, range: fullRange)
        for stringRange in stringRanges {
            storage.addAttributes([.foregroundColor: EditorTheme.string], range: stringRange)
        }
        applyComments(in: storage, text: text, stringRanges: stringRanges)
    }

    private static func ranges(
        of regex: NSRegularExpression?,
        in text: String,
        range: NSRange
    ) -> [NSRange] {
        guard let regex else { return [] }
        var ranges: [NSRange] = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            if let match { ranges.append(match.range) }
        }
        return ranges
    }

    /// Colors `#` comments while ignoring a `#` inside a string literal, and
    /// overrides string colors for quotes typed inside a comment.
    private static func applyComments(
        in storage: NSTextStorage,
        text: String,
        stringRanges: [NSRange]
    ) {
        let nsText = text as NSString
        var location = 0

        while location < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            let end = lineRange.location + lineRange.length
            var index = lineRange.location
            var commentStart: Int?

            while index < end {
                if nsText.character(at: index) == 0x23,
                   !stringRanges.contains(where: { NSLocationInRange(index, $0) }) {
                    commentStart = index
                    break
                }
                index += 1
            }

            if let commentStart {
                storage.addAttributes(
                    commentAttributes,
                    range: NSRange(location: commentStart, length: end - commentStart)
                )
            }

            guard lineRange.length > 0 else { break }
            location = end
        }
    }

    private static func apply(
        _ regex: NSRegularExpression?,
        in storage: NSTextStorage,
        text: String,
        range: NSRange,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard let regex else { return }
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttributes(attributes, range: match.range)
        }
    }

    private static func applyFirstGroup(
        _ regex: NSRegularExpression?,
        in storage: NSTextStorage,
        text: String,
        range: NSRange,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard let regex else { return }
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            let groupRange = match.range(at: 1)
            guard groupRange.location != NSNotFound else { return }
            storage.addAttributes(attributes, range: groupRange)
        }
    }
}
#endif
