import Foundation
import SwiftUI

// MARK: - Runtime lifecycle

enum RuntimeState: Equatable {
    case idle
    case booting(detail: String)
    case ready(version: String, packages: [String])
    case failed(message: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - Variable explorer

enum WorkspaceVariableKind: String, Codable, Sendable {
    case array
    case dataframe
    case series
    case list
    case dictionary
    case string
    case number
    case boolean
    case function
    case object

    init(bridgeValue: String?) {
        self = WorkspaceVariableKind(rawValue: bridgeValue ?? "") ?? .object
    }

    var symbolName: String {
        switch self {
        case .array: return "square.grid.3x3"
        case .dataframe: return "tablecells"
        case .series: return "chart.bar.xaxis"
        case .list: return "list.bullet.rectangle"
        case .dictionary: return "curlybraces"
        case .string: return "textformat"
        case .number: return "number"
        case .boolean: return "checkmark.square"
        case .function: return "function"
        case .object: return "shippingbox"
        }
    }

    /// Spyder-style type colors used by the explorer and preview table.
    var tintColor: Color {
        switch self {
        case .array: return Color(red: 0.74, green: 0.58, blue: 0.99)
        case .dataframe, .series: return Color(red: 0.38, green: 0.84, blue: 0.80)
        case .list, .dictionary: return Color(red: 0.50, green: 0.74, blue: 1.00)
        case .string: return Color(red: 0.55, green: 0.88, blue: 0.58)
        case .number: return Color(red: 0.98, green: 0.72, blue: 0.36)
        case .boolean: return Color(red: 0.96, green: 0.55, blue: 0.68)
        case .function: return Color(red: 0.42, green: 0.80, blue: 0.98)
        case .object: return Color(white: 0.66)
        }
    }
}

struct PythonVariable: Identifiable, Hashable, Sendable {
    let name: String
    let typeName: String
    let shape: String
    let summary: String
    let kind: WorkspaceVariableKind

    var id: String { name }

    /// `numpy.ndarray` becomes `ndarray` for the compact type badge.
    var displayType: String {
        typeName.split(separator: ".").last.map(String.init) ?? typeName
    }
}

extension PythonVariable {
    init(payload: VariablePayload) {
        self.init(
            name: payload.name ?? "?",
            typeName: payload.type ?? "object",
            shape: payload.shape ?? "—",
            summary: payload.summary ?? "",
            kind: WorkspaceVariableKind(bridgeValue: payload.kind)
        )
    }
}

/// A page of structured data for the variable viewer sheet.
struct VariablePreview: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let kind: WorkspaceVariableKind
    let columns: [String]
    let rows: [[String]]
    let totalRows: Int
    let totalColumns: Int
    let note: String
    let repr: String
    let error: String?

    init?(payload: VariablePreviewPayload) {
        guard let name = payload.name, !name.isEmpty else { return nil }

        self.name = name
        self.kind = WorkspaceVariableKind(bridgeValue: payload.kind)
        self.columns = payload.columns ?? []
        self.rows = payload.rows ?? []
        self.totalRows = payload.totalRows ?? (payload.rows?.count ?? 0)
        self.totalColumns = payload.totalColumns ?? (payload.columns?.count ?? 0)
        self.note = payload.note ?? ""
        self.repr = payload.repr ?? ""

        if let error = payload.error, !error.isEmpty {
            self.error = error
        } else {
            self.error = nil
        }
    }
}

/// Docstring/signature result for the editor's Docs popover.
struct SymbolHelp: Identifiable, Sendable {
    let id = UUID()
    let symbol: String
    let title: String
    let signature: String
    let module: String
    let doc: String
    let error: String?

    init?(payload: SymbolHelpPayload) {
        guard let symbol = payload.symbol, !symbol.isEmpty else { return nil }

        self.symbol = symbol
        self.title = payload.title ?? symbol
        self.signature = payload.signature ?? symbol
        self.module = payload.module ?? ""
        self.doc = payload.doc ?? ""

        if let error = payload.error, !error.isEmpty {
            self.error = error
        } else {
            self.error = nil
        }
    }
}

// MARK: - Console

enum ConsoleLineLevel: String, Sendable {
    case input
    case stdout
    case stderr
    case error
    case system
    case success
    /// Alert shown under a missing-file traceback, with a link to Workspace Files.
    case fileHint
}

struct ConsoleLine: Identifiable, Sendable {
    let id: UUID
    let level: ConsoleLineLevel
    let text: String
    let timestamp: Date

    init(level: ConsoleLineLevel, text: String, timestamp: Date = .now) {
        self.id = UUID()
        self.level = level
        self.text = text
        self.timestamp = timestamp
    }
}

// MARK: - Plots

struct PlotSnapshot: Identifiable {
    let id: UUID
    let figureNumber: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let createdAt: Date
    let image: PlatformImage?

    init?(payload: PlotPayload, figureNumber: Int, createdAt: Date = .now) {
        guard
            let data = Data(base64Encoded: payload.png),
            let image = PlatformImage(data: data)
        else { return nil }

        self.id = UUID()
        self.figureNumber = payload.figure ?? figureNumber
        self.pixelWidth = payload.width ?? Int(image.size.width)
        self.pixelHeight = payload.height ?? Int(image.size.height)
        self.createdAt = createdAt
        self.image = image
    }

    var dimensionLabel: String {
        "\(pixelWidth) × \(pixelHeight) px"
    }
}

// MARK: - Editor + inspector state

struct EditorCursor: Equatable, Sendable {
    var line: Int = 1
    var column: Int = 1
    var selectedText: String = ""
    var symbol: String?

    var hasSelection: Bool { !selectedText.isEmpty }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case console
    case plots

    var id: String { rawValue }
}

enum InspectorSection: String, CaseIterable, Identifiable {
    case variables
    case console
    case plots

    var id: String { rawValue }
}

enum SplitAxisPreference: String, CaseIterable, Identifiable {
    case automatic
    case sideBySide
    case stacked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .sideBySide: return "Side by Side"
        case .stacked: return "Stacked"
        }
    }

    /// Split-screen glyphs used by the Variables bar layout toggle.
    var symbolName: String {
        switch self {
        case .automatic: return "rectangle"
        case .sideBySide: return "rectangle.split.2x1"
        case .stacked: return "rectangle.split.1x2"
        }
    }
}

/// The split layout actually in effect. The Variables bar shows its glyph and
/// toggles to the other mode when tapped.
enum WorkspaceLayout: String, Sendable {
    case sideBySide
    case stacked

    var symbolName: String {
        switch self {
        case .sideBySide: return "rectangle.split.2x1"
        case .stacked: return "rectangle.split.1x2"
        }
    }

    var title: String {
        switch self {
        case .sideBySide: return "Side by Side"
        case .stacked: return "Stacked"
        }
    }

    var alternate: WorkspaceLayout {
        self == .sideBySide ? .stacked : .sideBySide
    }
}

// MARK: - Variables bar

enum VariableSortOption: String, CaseIterable, Identifiable, Sendable {
    case name
    case type
    case size
    case value

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .type: return "Type"
        case .size: return "Size"
        case .value: return "Value"
        }
    }
}

/// Toolbar actions that no longer fit in the Variables bar and move into the
/// header's overflow menu.
struct VariableBarHiddenActions: OptionSet, Sendable {
    let rawValue: Int

    static let sort = VariableBarHiddenActions(rawValue: 1 << 0)
    static let reload = VariableBarHiddenActions(rawValue: 1 << 1)
    static let files = VariableBarHiddenActions(rawValue: 1 << 2)
    static let clear = VariableBarHiddenActions(rawValue: 1 << 3)
}

// MARK: - Workspace files

struct WorkspaceFile: Identifiable, Hashable, Sendable {
    let name: String
    let byteCount: Int

    var id: String { name }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

struct FileOperationResult: Sendable {
    let ok: Bool
    let size: Int
    let error: String?
}

// MARK: - Run results

struct RunOutcome {
    let requestId: String
    let succeeded: Bool
    let durationMs: Double
    let errorText: String?
    let variables: [PythonVariable]
    let plots: [PlotPayload]
}

enum OutputChannel {
    case stdout
    case stderr
}

// MARK: - String helpers

extension String {
    /// Number of logical lines, never less than one.
    var logicalLineCount: Int {
        max(1, reduce(0) { $1 == "\n" ? $0 + 1 : $0 })
    }

    /// Extracts a single 1-based line, used by "Run Line".
    func line(number: Int) -> String? {
        guard number > 0 else { return nil }
        var currentLine = 1
        var start = startIndex

        while currentLine < number {
            guard let newline = self[start...].firstIndex(of: "\n") else { return nil }
            start = index(after: newline)
            currentLine += 1
        }

        if let end = self[start...].firstIndex(of: "\n") {
            return String(self[start..<end])
        }
        return String(self[start...])
    }
}
