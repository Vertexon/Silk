import Foundation
import WebKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Events emitted by the headless JavaScript runtime.
enum PyodideEvent {
    case ready(version: String, packages: [String])
    case status(String)
    case output(channel: OutputChannel, text: String)
    case result(RunOutcome)
    case workspace([PythonVariable])
    case variableDeleted(name: String, removed: Bool)
    case variablesCleared(count: Int)
    case failure(String)
    case log(String)
}

/// Owns the headless `WKWebView` that runs Pyodide and translates the
/// JavaScript message protocol into `PyodideEvent` values.
@MainActor
final class PyodideEngine: NSObject {
    var onEvent: ((PyodideEvent) -> Void)?

    let configuration: PyodideConfiguration

    private var webView: WKWebView?
    private var isReady = false
    private var bootRequested = false
    private var watchdog: Task<Void, Never>?
    private var hasLoadedDocument = false
    private var previewContinuations: [String: CheckedContinuation<VariablePreview?, Never>] = [:]
    private var helpContinuations: [String: CheckedContinuation<SymbolHelp?, Never>] = [:]
    private var fileListContinuations: [String: CheckedContinuation<[WorkspaceFile]?, Never>] = [:]
    private var fileDataContinuations: [String: CheckedContinuation<Data?, Never>] = [:]
    private var fileOperationContinuations: [String: CheckedContinuation<FileOperationResult?, Never>] = [:]

    init(configuration: PyodideConfiguration? = nil) {
        self.configuration = configuration ?? .live
        super.init()
    }

    // MARK: Web view

    func makeWebView() -> WKWebView {
        if let webView { return webView }

        let controller = WKUserContentController()
        controller.add(WeakScriptMessageHandler(target: self), name: WebHostAssets.messageHandlerName)

        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.userContentController = controller
        webConfiguration.websiteDataStore = .default()
        webConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let view = WKWebView(frame: .zero, configuration: webConfiguration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false

        #if canImport(UIKit)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        #endif

        webView = view
        return view
    }

    // MARK: Lifecycle

    func start() {
        guard !hasLoadedDocument else { return }
        let view = makeWebView()
        do {
            try WebHostAssets.load(into: view)
            hasLoadedDocument = true
        } catch {
            onEvent?(.failure(error.localizedDescription))
        }
    }

    /// Reloads the host page, which tears down Pyodide and its Python state.
    func restart() {
        watchdog?.cancel()
        cancelPendingRequests()
        isReady = false
        bootRequested = false
        hasLoadedDocument = false
        onEvent?(.status("Restarting Python..."))

        guard let webView else {
            start()
            return
        }

        do {
            try WebHostAssets.load(into: webView)
            hasLoadedDocument = true
        } catch {
            onEvent?(.failure(error.localizedDescription))
        }
    }

    // MARK: Requests

    func execute(requestId: String, code: String) {
        guard isReady, let webView else {
            onEvent?(.failure("Python is not ready yet."))
            return
        }
        send(function: "execute", payload: ["id": requestId, "code": code], to: webView)
    }

    func refreshWorkspace(requestId: String) {
        guard isReady, let webView else { return }
        send(function: "refresh", payload: ["id": requestId], to: webView)
    }

    /// Reads a structured page for the variable explorer sheet.
    func previewVariable(named name: String) async -> VariablePreview? {
        guard isReady, let webView else { return nil }
        let requestId = UUID().uuidString

        return await withCheckedContinuation { continuation in
            previewContinuations[requestId] = continuation
            send(function: "preview", payload: ["id": requestId, "name": name], to: webView)

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.finishPreview(requestId: requestId, preview: nil)
            }
        }
    }

    /// Fetches signature and docstring for a dotted symbol. `source` supplies
    /// the editor's imports so aliases resolve before the cell has run.
    func documentation(for symbol: String, source: String) async -> SymbolHelp? {
        guard isReady, let webView else { return nil }
        let requestId = UUID().uuidString

        return await withCheckedContinuation { continuation in
            helpContinuations[requestId] = continuation
            send(
                function: "help",
                payload: ["id": requestId, "symbol": symbol, "source": source],
                to: webView
            )

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.finishHelp(requestId: requestId, help: nil)
            }
        }
    }

    func deleteVariable(named name: String) {
        guard isReady, let webView else { return }
        send(
            function: "deleteVariable",
            payload: ["id": UUID().uuidString, "name": name],
            to: webView
        )
    }

    // MARK: Workspace files

    func clearVariables() {
        guard isReady, let webView else { return }
        send(function: "clearVariables", payload: ["id": UUID().uuidString], to: webView)
    }

    func listFiles() async -> [WorkspaceFile]? {
        guard isReady, let webView else { return nil }
        let requestId = UUID().uuidString

        return await withCheckedContinuation { continuation in
            fileListContinuations[requestId] = continuation
            send(function: "listFiles", payload: ["id": requestId], to: webView)

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.finishFileList(requestId: requestId, files: nil)
            }
        }
    }

    func writeFile(named name: String, data: Data) async -> FileOperationResult? {
        guard isReady, let webView else { return nil }
        let requestId = UUID().uuidString

        return await withCheckedContinuation { continuation in
            fileOperationContinuations[requestId] = continuation
            send(
                function: "writeFile",
                payload: [
                    "id": requestId,
                    "name": name,
                    "base64": data.base64EncodedString(),
                ],
                to: webView
            )

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(25))
                self?.finishFileOperation(requestId: requestId, result: nil)
            }
        }
    }

    func readFile(named name: String) async -> Data? {
        guard isReady, let webView else { return nil }
        let requestId = UUID().uuidString

        return await withCheckedContinuation { continuation in
            fileDataContinuations[requestId] = continuation
            send(function: "readFile", payload: ["id": requestId, "name": name], to: webView)

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(25))
                self?.finishFileData(requestId: requestId, data: nil)
            }
        }
    }

    func deleteFile(named name: String) async -> FileOperationResult? {
        guard isReady, let webView else { return nil }
        let requestId = UUID().uuidString

        return await withCheckedContinuation { continuation in
            fileOperationContinuations[requestId] = continuation
            send(function: "deleteFile", payload: ["id": requestId, "name": name], to: webView)

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.finishFileOperation(requestId: requestId, result: nil)
            }
        }
    }

    private func finishFileList(requestId: String, files: [WorkspaceFile]?) {
        guard let continuation = fileListContinuations.removeValue(forKey: requestId) else { return }
        continuation.resume(returning: files)
    }

    private func finishFileData(requestId: String, data: Data?) {
        guard let continuation = fileDataContinuations.removeValue(forKey: requestId) else { return }
        continuation.resume(returning: data)
    }

    private func finishFileOperation(requestId: String, result: FileOperationResult?) {
        guard let continuation = fileOperationContinuations.removeValue(forKey: requestId) else { return }
        continuation.resume(returning: result)
    }

    private func finishPreview(requestId: String, preview: VariablePreview?) {
        guard let continuation = previewContinuations.removeValue(forKey: requestId) else { return }
        continuation.resume(returning: preview)
    }

    private func finishHelp(requestId: String, help: SymbolHelp?) {
        guard let continuation = helpContinuations.removeValue(forKey: requestId) else { return }
        continuation.resume(returning: help)
    }

    private func cancelPendingRequests() {
        let previews = previewContinuations
        previewContinuations.removeAll()
        for continuation in previews.values {
            continuation.resume(returning: nil)
        }

        let helps = helpContinuations
        helpContinuations.removeAll()
        for continuation in helps.values {
            continuation.resume(returning: nil)
        }

        let fileLists = fileListContinuations
        fileListContinuations.removeAll()
        for continuation in fileLists.values {
            continuation.resume(returning: nil)
        }

        let fileData = fileDataContinuations
        fileDataContinuations.removeAll()
        for continuation in fileData.values {
            continuation.resume(returning: nil)
        }

        let fileOperations = fileOperationContinuations
        fileOperationContinuations.removeAll()
        for continuation in fileOperations.values {
            continuation.resume(returning: nil)
        }
    }

    // MARK: Boot sequence

    private func documentDidLoad() {
        guard !bootRequested else { return }
        bootRequested = true
        onEvent?(.status("Starting Python..."))

        Task { @MainActor [weak self] in
            guard let self, let webView = self.webView else { return }
            do {
                let hasBridge = self.booleanValue(
                    try await webView.evaluateJavaScript("typeof window.SpyderBridge === 'object'")
                )
                guard hasBridge else { throw BridgeError.bridgeMissing }

                let json = try self.configuration.bridgeJSON()
                _ = try await webView.evaluateJavaScript("window.SpyderBridge.boot(\(json));")
                self.startWatchdog()
            } catch {
                self.bootRequested = false
                self.onEvent?(.failure(error.localizedDescription))
            }
        }
    }

    private func send(function: String, payload: [String: Any], to webView: WKWebView) {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let json = String(data: data, encoding: .utf8) else {
                throw BridgeError.encodingFailed
            }
            let script = "window.SpyderBridge && window.SpyderBridge.\(function)(\(json));"

            Task { @MainActor [weak self] in
                do {
                    _ = try await webView.evaluateJavaScript(script)
                } catch {
                    self?.onEvent?(.failure("JavaScript bridge error: \(error.localizedDescription)"))
                }
            }
        } catch {
            onEvent?(.failure(error.localizedDescription))
        }
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard let self, !Task.isCancelled, !self.isReady else { return }
            self.onEvent?(.failure(
                "Python is taking unusually long to start. Check the network connection, or bundle Pyodide with the app for offline use."
            ))
        }
    }

    private func booleanValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let bool = value as? Bool { return bool }
        return false
    }

    // MARK: Incoming messages

    fileprivate func handle(messageBody: Any) {
        guard let message = BridgeMessage(body: messageBody) else { return }

        switch message.type {
        case "ready":
            isReady = true
            watchdog?.cancel()
            watchdog = nil
            onEvent?(.ready(version: message.version ?? "3.x", packages: message.packages ?? []))

        case "status":
            if let detail = message.detail, !isReady {
                onEvent?(.status(detail))
            }

        case "stdout":
            guard let text = message.text, !text.isEmpty else { return }
            onEvent?(.output(channel: message.stream == "stderr" ? .stderr : .stdout, text: text))

        case "result":
            let variables = (message.variables ?? []).map(PythonVariable.init(payload:))
            let outcome = RunOutcome(
                requestId: message.id ?? "",
                succeeded: message.ok ?? true,
                durationMs: message.durationMs ?? 0,
                errorText: message.error,
                variables: variables,
                plots: message.plots ?? []
            )
            onEvent?(.result(outcome))

        case "workspace":
            onEvent?(.workspace((message.variables ?? []).map(PythonVariable.init(payload:))))

        case "preview":
            guard let requestId = message.id else { break }
            let preview = message.preview.flatMap(VariablePreview.init(payload:))
            finishPreview(requestId: requestId, preview: preview)

        case "help":
            guard let requestId = message.id else { break }
            let help = message.help.flatMap(SymbolHelp.init(payload:))
            finishHelp(requestId: requestId, help: help)

        case "variableDeleted":
            onEvent?(.variableDeleted(name: message.name ?? "", removed: message.removed ?? false))

        case "variablesCleared":
            onEvent?(.variablesCleared(count: message.count ?? 0))

        case "files":
            guard let requestId = message.id else { break }
            if message.error != nil {
                finishFileList(requestId: requestId, files: nil)
            } else {
                let files = (message.files ?? []).compactMap { payload -> WorkspaceFile? in
                    guard let name = payload.name, !name.isEmpty else { return nil }
                    return WorkspaceFile(name: name, byteCount: payload.size ?? 0)
                }
                finishFileList(requestId: requestId, files: files)
            }

        case "fileData":
            guard let requestId = message.id else { break }
            let data = message.base64.flatMap { Data(base64Encoded: $0) }
            finishFileData(requestId: requestId, data: data)

        case "fileOperation":
            guard let requestId = message.id else { break }
            let result = FileOperationResult(
                ok: message.ok ?? false,
                size: message.size ?? 0,
                error: message.error
            )
            finishFileOperation(requestId: requestId, result: result)

        case "failure":
            cancelPendingRequests()
            isReady = false
            bootRequested = false
            watchdog?.cancel()
            watchdog = nil
            onEvent?(.failure(message.message ?? "The Python runtime failed."))

        case "log":
            if let text = message.message, !text.isEmpty {
                onEvent?(.log(text))
            }

        default:
            break
        }
    }
}

// MARK: - WKNavigationDelegate

extension PyodideEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        documentDidLoad()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onEvent?(.failure("Could not load the Python host page: \(error.localizedDescription)"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onEvent?(.failure("Could not load the Python host page: \(error.localizedDescription)"))
    }
}

// MARK: - WKUIDelegate

extension PyodideEngine: WKUIDelegate {
    /// WKWebView calls this for `window.prompt`, which Pyodide's stdin bridge
    /// uses. JavaScript blocks until `completionHandler` runs, so input() gets
    /// the submitted line (or EOF when cancelled).
    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        #if canImport(UIKit)
        guard let presenter = Self.topViewController() else {
            completionHandler(nil)
            return
        }

        let alert = UIAlertController(
            title: "Python input()",
            message: prompt.isEmpty ? "Enter a value for input()." : prompt,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "Value"
            field.text = defaultText
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completionHandler(nil)
        })
        alert.addAction(UIAlertAction(title: "Submit", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text ?? "")
        })
        presenter.present(alert, animated: true)
        #elseif canImport(AppKit)
        let alert = NSAlert()
        alert.messageText = "Python input()"
        alert.informativeText = prompt.isEmpty ? "Enter a value for input()." : prompt
        alert.addButton(withTitle: "Submit")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        let response = alert.runModal()
        completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        #endif
    }

    #if canImport(UIKit)
    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        var controller = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
    #endif
}

// MARK: - WKScriptMessageHandler

extension PyodideEngine: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebHostAssets.messageHandlerName else { return }
        handle(messageBody: message.body)
    }
}

/// Breaks the `WKUserContentController` -> engine retain cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
