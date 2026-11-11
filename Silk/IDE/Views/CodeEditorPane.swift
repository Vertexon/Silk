import SwiftUI

struct CodeEditorPane: View {
    @Environment(IDEStore.self) private var store
    @AppStorage("Silk.autoCloseBrackets") private var autoCloseBrackets = true
    @AppStorage("Silk.autoCloseQuotes") private var autoCloseQuotes = true

    @State private var showsDocumentation = false
    @State private var documentation: SymbolHelp?
    @State private var isLoadingDocumentation = false
    @State private var headerWidth: CGFloat = .greatestFiniteMagnitude

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            PanelHeader(title: documentTitle, systemImage: "doc.text") {
                HStack(spacing: 7) {
                    Button {
                        presentDocumentation()
                    } label: {
                        Image(systemName: "book.closed")
                            .ideIconButtonStyle()
                    }
                    .modifier(
                        DocumentationPresentation(
                            isPresented: $showsDocumentation,
                            symbol: store.cursor.symbol,
                            help: documentation,
                            isLoading: isLoadingDocumentation
                        )
                    )

                    Button {
                        store.runLineOrSelection()
                    } label: {
                        Label(store.cursor.hasSelection ? "Run Selection" : "Run Line", systemImage: "play")
                            .labelStyle(RunActionLabelStyle(compact: compactRunControls))
                    }
                    .buttonStyle(IDEToolbarButtonStyle(kind: .secondary))
                    .keyboardShortcut(.return, modifiers: [.command, .shift])

                    Button {
                        store.runAll()
                    } label: {
                        Label("Run All", systemImage: "play.fill")
                            .labelStyle(RunActionLabelStyle(compact: compactRunControls))
                    }
                    .buttonStyle(IDEToolbarButtonStyle(kind: .primary))
                    .keyboardShortcut(.return, modifiers: [.command])
                }
                .disabled(!store.runtime.isReady || store.isExecuting)
                .opacity(store.runtime.isReady ? 1 : 0.5)
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                headerWidth = width
            }

            runtimeBanner

            IDEHairline()

            editor(text: $store.source, cursor: $store.cursor, errorLine: store.errorLine)

            IDEHairline()
            statusBar
        }
        .background(IDEPalette.panel)
    }

    /// Keeps the Run titles while the header can still hold the document name
    /// and both labels; below that the glyphs alone prevent wrapping.
    private var compactRunControls: Bool { headerWidth < 360 }

    /// Appends an asterisk while the buffer differs from the last opened or
    /// saved text.
    private var documentTitle: String {
        store.hasUnsavedChanges ? "\(store.documentName) *" : store.documentName
    }

    /// The running CPython version, shown in the status bar where the header
    /// used to carry a separate runtime pill.
    private var pythonVersion: String {
        if case .ready(let version, _) = store.runtime {
            return version
        }
        return "3"
    }

    private func presentDocumentation() {
        let symbol = store.cursor.symbol
        if documentation?.symbol != symbol {
            documentation = nil
        }
        showsDocumentation = true
        Task { await loadDocumentation() }
    }

    private func loadDocumentation() async {
        guard let symbol = store.cursor.symbol, !symbol.isEmpty else {
            documentation = nil
            isLoadingDocumentation = false
            return
        }
        if documentation?.symbol == symbol {
            return
        }

        isLoadingDocumentation = true
        documentation = await store.documentation(for: symbol)
        isLoadingDocumentation = false
    }

    @ViewBuilder
    private var runtimeBanner: some View {
        switch store.runtime {
        case .booting(let detail):
            RuntimeBanner(
                systemImage: "hourglass",
                tint: IDEPalette.accent,
                title: "Warming up Python",
                message: detail,
                showsProgress: true
            )

        case .failed(let message):
            RuntimeBanner(
                systemImage: "exclamationmark.triangle.fill",
                tint: IDEPalette.danger,
                title: "Python runtime unavailable",
                message: message,
                actionTitle: "Retry",
                action: store.restartRuntime
            )

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func editor(
        text: Binding<String>,
        cursor: Binding<EditorCursor>,
        errorLine: Int?
    ) -> some View {
        #if canImport(UIKit)
        PythonTextEditor(
            text: text,
            cursor: cursor,
            errorLine: errorLine,
            autoClosesBrackets: autoCloseBrackets,
            autoClosesQuotes: autoCloseQuotes
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        TextEditor(text: text)
            .font(.system(size: 14, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(IDEPalette.panel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text("Ln \(store.cursor.line), Col \(store.cursor.column)")
            Text("·")
                .foregroundStyle(IDEPalette.secondaryText.opacity(0.5))
            Text("\(store.lineCount) lines")

            if let errorLine = store.errorLine {
                Text("·")
                    .foregroundStyle(IDEPalette.secondaryText.opacity(0.5))
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Line \(errorLine)")
                }
                .foregroundStyle(IDEPalette.danger)
            }

            Spacer(minLength: 4)

            if let symbol = store.cursor.symbol {
                Text(symbol)
                    .foregroundStyle(IDEPalette.accent.opacity(0.8))
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(IDEPalette.secondaryText.opacity(0.5))
            }

            if store.isExecuting {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(IDEPalette.accent)
                    Text("Running")
                }
            } else {
                Text("Python \(pythonVersion) · UTF-8")
            }
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(IDEPalette.secondaryText)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(IDEPalette.header)
    }
}

/// Shows the Run title while there is room, then falls back to the glyph alone
/// so the label can never wrap onto a second line.
private struct RunActionLabelStyle: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack(spacing: 6) {
                configuration.icon
                configuration.title
            }
        }
    }
}

/// Shows symbol documentation in a sheet on iOS/iPadOS so it always has room to
/// lay out, and in an anchored popover on macOS.
private struct DocumentationPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let symbol: String?
    let help: SymbolHelp?
    let isLoading: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SymbolDocumentationView(symbol: symbol, help: help, isLoading: isLoading)
                .frame(width: 520, height: 460)
        }
        #else
        content.sheet(isPresented: $isPresented) {
            SymbolDocumentationView(symbol: symbol, help: help, isLoading: isLoading)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(IDEPalette.panel)
                .presentationCornerRadius(18)
        }
        #endif
    }
}
