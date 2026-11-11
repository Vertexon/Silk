import Foundation
import Observation

/// Single source of truth for the IDE: document text, runtime status, console,
/// variables and figures. Views observe it through SwiftUI's environment.
@MainActor
@Observable
final class IDEStore {
    // MARK: Observable state

    var source: String
    var savedSource: String
    var variables: [PythonVariable] = []
    var plots: [PlotSnapshot] = []
    var console: [ConsoleLine] = []
    var runtime: RuntimeState = .idle
    var isExecuting = false
    var isRefreshingWorkspace = false
    var cursor = EditorCursor()
    var selectedTab: InspectorTab = .console
    var runSequence = 0
    var documentName = "temp.py"
    var errorLine: Int?
    var lastErrorMessage: String?
    var files: [WorkspaceFile] = []
    var isLoadingFiles = false
    var fileError: String?
    var isPresentingOpenDocument = false
    var isPresentingSaveDocument = false
    var isPresentingWorkspaceFiles = false
    var variableSortOption: VariableSortOption = .name
    var variableSortAscending = true
    var hiddenVariableBarActions: VariableBarHiddenActions = []

    /// `false` in previews so no WebKit process is started.
    let usesLiveRuntime: Bool

    // MARK: Private state

    @ObservationIgnored let engine: PyodideEngine
    @ObservationIgnored private var stdoutBuffer = ""
    @ObservationIgnored private var stderrBuffer = ""
    @ObservationIgnored private let maxConsoleLines = 2_000
    @ObservationIgnored private let maxPlots = 24
    @ObservationIgnored private var documentationCache: [String: SymbolHelp] = [:]
    @ObservationIgnored private var lastRunStartLine = 1
    @ObservationIgnored private static let maxFileBytes = 16 * 1024 * 1024

    // MARK: Init

    init(bootsAutomatically: Bool = true, configuration: PyodideConfiguration? = nil) {
        self.usesLiveRuntime = bootsAutomatically
        self.engine = PyodideEngine(configuration: configuration ?? .live)
        self.source = Self.starterSource
        self.savedSource = Self.starterSource

        if bootsAutomatically {
            engine.onEvent = { [weak self] event in
                self?.handle(event)
            }
            engine.start()
            runtime = .booting(detail: "Loading Python runtime...")
        } else {
            runtime = .ready(version: "3.14.0", packages: ["numpy", "matplotlib"])
            seedPreviewContent()
        }
    }

    // MARK: Derived state

    var consoleText: String {
        console.map(\.text).joined(separator: "\n")
    }

    var lineCount: Int { source.logicalLineCount }

    var hasUnsavedChanges: Bool { source != savedSource }

    // MARK: Commands

    func runAll() {
        execute(source, startLine: 1)
    }

    /// Runs the selected text when there is a selection, otherwise the line
    /// containing the caret (Spyder's F9 behaviour).
    func runLineOrSelection() {
        if cursor.hasSelection {
            let start = max(1, cursor.line - cursor.selectedText.logicalLineCount + 1)
            execute(cursor.selectedText, startLine: start)
            return
        }

        guard let line = source.line(number: cursor.line) else { return }
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        execute(line, startLine: cursor.line)
    }

    func refreshWorkspace() {
        guard runtime.isReady, !isRefreshingWorkspace else { return }
        isRefreshingWorkspace = true
        engine.refreshWorkspace(requestId: "workspace-\(runSequence)")

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.isRefreshingWorkspace else { return }
            self.isRefreshingWorkspace = false
        }
    }

    func restartRuntime() {
        isExecuting = false
        variables = []
        plots = []
        files = []
        errorLine = nil
        lastErrorMessage = nil
        fileError = nil
        documentationCache.removeAll()
        cursor = EditorCursor()
        flushOutputBuffers()
        append(.system, "Restarting the Python runtime. Variables, files and figures were cleared.")
        runtime = .booting(detail: "Restarting Python...")
        engine.restart()
    }

    func loadDocument(text: String, name: String) {
        source = text
        savedSource = text
        documentName = name
        cursor = EditorCursor()
        errorLine = nil
        lastErrorMessage = nil
        append(.system, "Opened \(name).")
    }

    func markDocumentSaved(name: String) {
        documentName = name
        savedSource = source
    }

    func clearVariables() {
        guard runtime.isReady else {
            append(.system, "Python is still starting up.")
            return
        }
        engine.clearVariables()
    }

    /// Reads a structured table for the variable viewer sheet.
    func preview(for variable: PythonVariable) async -> VariablePreview? {
        await engine.previewVariable(named: variable.name)
    }

    /// Returns signature + docstring for a symbol, caching successes per runtime
    /// session. Failures stay uncached so Docs works once the cell has run.
    func documentation(for symbol: String) async -> SymbolHelp? {
        if let cached = documentationCache[symbol] {
            return cached
        }
        guard let help = await engine.documentation(for: symbol, source: source) else { return nil }
        if help.error == nil {
            documentationCache[symbol] = help
        }
        return help
    }

    func deleteVariable(_ variable: PythonVariable) {
        guard runtime.isReady else {
            append(.system, "Python is still starting up.")
            return
        }
        engine.deleteVariable(named: variable.name)
    }

    // MARK: Workspace files

    func refreshFiles() async {
        guard runtime.isReady else {
            files = []
            return
        }

        isLoadingFiles = true
        let loaded = await engine.listFiles()
        if let loaded {
            files = loaded
        } else {
            fileError = "Could not list the Python working directory."
        }
        isLoadingFiles = false
    }

    func importFiles(at urls: [URL]) async {
        guard runtime.isReady else {
            fileError = "Python is still starting up."
            return
        }

        var problems: [String] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: url)
                guard data.count <= Self.maxFileBytes else {
                    problems.append("\(url.lastPathComponent) is larger than 16 MB.")
                    continue
                }
                guard let operation = await engine.writeFile(named: url.lastPathComponent, data: data) else {
                    problems.append("Could not import \(url.lastPathComponent).")
                    continue
                }
                guard operation.ok else {
                    problems.append(operation.error ?? "Could not import \(url.lastPathComponent).")
                    continue
                }
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        fileError = problems.isEmpty ? nil : problems.joined(separator: "\n")
        await refreshFiles()
    }

    func exportFile(named name: String) async -> Data? {
        guard runtime.isReady else {
            fileError = "Python is still starting up."
            return nil
        }
        guard let data = await engine.readFile(named: name) else {
            fileError = "Could not read \(name)."
            return nil
        }
        return data
    }

    func deleteFile(named name: String) async {
        guard runtime.isReady else { return }
        let result = await engine.deleteFile(named: name)
        if result?.ok != true {
            fileError = result?.error ?? "Could not delete \(name)."
        }
        await refreshFiles()
    }

    func reportFileError(_ message: String) {
        fileError = message
    }

    func clearConsole() {
        console.removeAll()
        stdoutBuffer = ""
        stderrBuffer = ""
    }

    func clearPlots() {
        plots.removeAll()
    }

    // MARK: Execution

    private func execute(_ code: String, startLine: Int = 1) {
        guard runtime.isReady else {
            append(.system, "Python is still starting up.")
            return
        }
        guard !isExecuting else {
            append(.system, "A cell is already running.")
            return
        }

        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        runSequence += 1
        lastRunStartLine = max(1, startLine)
        errorLine = nil
        lastErrorMessage = nil
        isExecuting = true
        flushOutputBuffers()

        let echo = trimmed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, line in
                index == 0 ? "In [\(runSequence)]: \(line)" : "      ...: \(line)"
            }
            .joined(separator: "\n")
        append(.input, echo)

        engine.execute(requestId: "run-\(runSequence)", code: code)
    }

    private func complete(_ outcome: RunOutcome) {
        flushOutputBuffers()
        isExecuting = false
        variables = outcome.variables

        let newPlots = outcome.plots.enumerated().compactMap { index, payload in
            PlotSnapshot(payload: payload, figureNumber: payload.figure ?? index + 1)
        }
        if !newPlots.isEmpty {
            plots = Array((plots + newPlots).suffix(maxPlots))
            selectedTab = .plots
        }

        if outcome.succeeded {
            errorLine = nil
            lastErrorMessage = nil
            append(.system, String(format: "Finished in %.0f ms", outcome.durationMs))
        } else {
            let message = (outcome.errorText ?? "Execution failed.").trimmingCharacters(in: .whitespacesAndNewlines)
            errorLine = parseErrorLine(in: message)
            lastErrorMessage = message
            append(.error, message)
            if Self.isMissingFileError(message) {
                append(.fileHint, Self.fileAccessHint)
            }
            append(.system, String(format: "Failed after %.0f ms", outcome.durationMs))
        }
    }

    /// Pyodide cannot read the iPad's Files app, so a missing path is the common
    /// first-run error. The console answers it with a pointer to Workspace Files.
    private static func isMissingFileError(_ message: String) -> Bool {
        message.contains("FileNotFoundError") || message.contains("No such file or directory")
    }

    static let fileAccessHint = "Silk can't access your iPad's files. Add files to the Workspace Files to let Silk use them."

    private func parseErrorLine(in message: String) -> Int? {
        let patterns = [
            "\"<spyder-cell>\", line (\\d+)",
            "line (\\d+)",
        ]
        let fullRange = NSRange(message.startIndex..., in: message)

        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: message, options: [], range: fullRange),
                let lineRange = Range(match.range(at: 1), in: message),
                let localLine = Int(message[lineRange])
            else { continue }
            return max(1, lastRunStartLine + localLine - 1)
        }
        return nil
    }

    // MARK: Event handling

    private func handle(_ event: PyodideEvent) {
        switch event {
        case .ready(let version, let packages):
            runtime = .ready(version: version, packages: packages)
            append(.success, "Python \(version) ready · \(packages.joined(separator: ", "))")

        case .status(let detail):
            if !runtime.isReady {
                runtime = .booting(detail: detail)
            }

        case .output(let channel, let text):
            appendOutput(text, isError: channel == .stderr)

        case .result(let outcome):
            complete(outcome)

        case .workspace(let variables):
            self.variables = variables
            isRefreshingWorkspace = false

        case .variableDeleted(let name, let removed):
            if removed {
                variables.removeAll { $0.name == name }
                documentationCache.removeValue(forKey: name)
                append(.system, "Deleted '\(name)' from the workspace.")
            } else {
                append(.system, "'\(name)' is no longer defined.")
            }

        case .variablesCleared(let count):
            variables = []
            documentationCache.removeAll()
            errorLine = nil
            lastErrorMessage = nil
            append(.system, count > 0 ? "Removed \(count) variables from the workspace." : "The workspace is already empty.")

        case .failure(let message):
            flushOutputBuffers()
            isExecuting = false
            isRefreshingWorkspace = false
            runtime = .failed(message: message)
            append(.error, message)

        case .log(let message):
            append(.system, "[runtime] \(message)")
        }
    }

    // MARK: Console helpers

    private func appendOutput(_ text: String, isError: Bool) {
        var buffer = isError ? stderrBuffer : stdoutBuffer
        buffer += text

        var lines = buffer.components(separatedBy: "\n")
        let remainder = lines.removeLast()
        for line in lines where !line.isEmpty {
            append(isError ? .stderr : .stdout, line)
        }

        if isError {
            stderrBuffer = remainder
        } else {
            stdoutBuffer = remainder
        }
    }

    private func flushOutputBuffers() {
        if !stdoutBuffer.isEmpty {
            append(.stdout, stdoutBuffer)
            stdoutBuffer = ""
        }
        if !stderrBuffer.isEmpty {
            append(.stderr, stderrBuffer)
            stderrBuffer = ""
        }
    }

    private func append(_ level: ConsoleLineLevel, _ text: String) {
        console.append(ConsoleLine(level: level, text: text))
        if console.count > maxConsoleLines {
            console.removeFirst(console.count - maxConsoleLines)
        }
    }

    // MARK: Starter document

    /// The editor starts blank instead of with a demo script.
    private static let starterSource = ""

    // MARK: Previews

    private func seedPreviewContent() {
        variables = [
            PythonVariable(name: "x", typeName: "numpy.ndarray", shape: "400", summary: "[0.         0.01574644 0.03149287 ... 6.25134543 6.26710892 6.28287241]", kind: .array),
            PythonVariable(name: "y", typeName: "numpy.ndarray", shape: "400", summary: "[0.00000000e+00 1.55424726e-02 2.98072272e-02 ... 1.52927867e-03 8.59213848e-04 3.38788872e-04]", kind: .array),
            PythonVariable(name: "sample", typeName: "dict", shape: "len 2", summary: "{'x': array([0. , 0.01574644, ...]), 'y': array([0. , 0.01541771, ...])}", kind: .dictionary),
        ]
        console = [
            ConsoleLine(level: .success, text: "Python 3.14.0 ready · numpy, matplotlib"),
            ConsoleLine(level: .input, text: "In [1]: print('samples:', x.size)"),
            ConsoleLine(level: .stdout, text: "samples: 400"),
            ConsoleLine(level: .system, text: "Finished in 42 ms"),
        ]
    }
}
