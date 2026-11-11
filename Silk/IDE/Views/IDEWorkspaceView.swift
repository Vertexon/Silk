import SwiftUI
import UniformTypeIdentifiers

/// Three-pane IDE shell:
///
/// - Wide/regular layouts put the editor beside a vertically split inspector.
/// - Narrow layouts stack the editor above a tabbed inspector.
/// - The divider is draggable in both axes; the layout mode can be overridden
///   from the header menu (portrait users often prefer one or the other).
struct IDEWorkspaceView: View {
    @Environment(IDEStore.self) private var store
    @AppStorage("Spyder.paneAxis") private var paneAxisPreference = SplitAxisPreference.automatic.rawValue

    @State private var editorFraction: CGFloat = 0.60
    @State private var variableFraction: CGFloat = 0.46
    @State private var compactSection: InspectorSection = .variables

    var body: some View {
        VStack(spacing: 0) {
            IDEHeaderBar()
            IDEHairline()

            GeometryReader { proxy in
                let mode = layoutMode(for: proxy.size)

                Group {
                    switch mode {
                    case .sideBySide:
                        ResizableSplit(
                            axis: .horizontal,
                            fraction: $editorFraction,
                            leadingMinimum: 330,
                            trailingMinimum: 280
                        ) {
                            CodeEditorPane()
                        } trailing: {
                            InspectorPane(
                                isCompact: false,
                                layout: mode,
                                variableFraction: $variableFraction,
                                compactSection: $compactSection
                            )
                        }

                    case .stacked:
                        ResizableSplit(
                            axis: .vertical,
                            fraction: $editorFraction,
                            leadingMinimum: 220,
                            trailingMinimum: 230
                        ) {
                            CodeEditorPane()
                        } trailing: {
                            InspectorPane(
                                isCompact: true,
                                layout: mode,
                                variableFraction: $variableFraction,
                                compactSection: $compactSection
                            )
                        }
                    }
                }
            }
        }
        .background(IDEPalette.backdrop)
        .background(alignment: .topLeading) {
            if store.usesLiveRuntime {
                PyodideHostView(engine: store.engine)
                    .frame(width: 1, height: 1)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .preferredColorScheme(.dark)
    }

    private func layoutMode(for size: CGSize) -> WorkspaceLayout {
        switch SplitAxisPreference(rawValue: paneAxisPreference) ?? .automatic {
        case .stacked:
            return .stacked
        case .sideBySide:
            return size.width >= 560 ? .sideBySide : .stacked
        case .automatic:
            return (size.width >= 700 && size.height >= 480) ? .sideBySide : .stacked
        }
    }
}

struct IDEHeaderBar: View {
    @Environment(IDEStore.self) private var store
    @AppStorage("Silk.autoCloseBrackets") private var autoCloseBrackets = true
    @AppStorage("Silk.autoCloseQuotes") private var autoCloseQuotes = true

    @State private var fileError: String?
    @State private var windowControlsInset: CGFloat = 0

    var body: some View {
        @Bindable var store = store

        HStack(spacing: 10) {
            SilkMark(size: 24)

            Text("Silk")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(IDEPalette.text)
                .lineLimit(1)

            Spacer(minLength: 6)

            Menu {
                Section("Editor") {
                    // Native Toggle menu items reserve a leading checkmark
                    // gutter, which indents this section away from the others.
                    // Command rows carry their tick at the end of the title so
                    // every item keeps the menu's normal leading inset.
                    Button {
                        autoCloseBrackets.toggle()
                    } label: {
                        Text(autoCloseBrackets ? "Autocomplete ( )  ✓" : "Autocomplete ( )")
                    }
                    .accessibilityValue(autoCloseBrackets ? "On" : "Off")

                    Button {
                        autoCloseQuotes.toggle()
                    } label: {
                        Text(autoCloseQuotes ? "Autocomplete \" \"  ✓" : "Autocomplete \" \"")
                    }
                    .accessibilityValue(autoCloseQuotes ? "On" : "Off")
                }

                if !store.hiddenVariableBarActions.isEmpty {
                    Section("Variables") {
                        if store.hiddenVariableBarActions.contains(.sort) {
                            Menu {
                                Picker("Sort by", selection: Binding(
                                    get: { store.variableSortOption },
                                    set: { store.variableSortOption = $0 }
                                )) {
                                    ForEach(VariableSortOption.allCases) { option in
                                        Text(option.title).tag(option)
                                    }
                                }

                                Button {
                                    store.variableSortAscending.toggle()
                                } label: {
                                    Label(
                                        store.variableSortAscending ? "Ascending" : "Descending",
                                        systemImage: store.variableSortAscending ? "arrow.up" : "arrow.down"
                                    )
                                }
                            } label: {
                                Label("Sort Variables", systemImage: "arrow.up.arrow.down")
                            }
                        }

                        if store.hiddenVariableBarActions.contains(.reload) {
                            Button {
                                store.refreshWorkspace()
                            } label: {
                                Label("Reload variables", systemImage: "arrow.clockwise")
                            }
                        }

                        if store.hiddenVariableBarActions.contains(.files) {
                            Button {
                                store.isPresentingWorkspaceFiles = true
                            } label: {
                                Label("Workspace Files", systemImage: "folder")
                            }
                        }
                    }
                }

                Section("Kernel") {
                    Button {
                        store.restartRuntime()
                    } label: {
                        Label("Restart Python Runtime", systemImage: "arrow.clockwise")
                    }

                    Button {
                        store.clearVariables()
                    } label: {
                        Label("Remove All Variables", systemImage: "trash")
                    }

                    Button {
                        store.clearConsole()
                    } label: {
                        Label("Clear Console", systemImage: "trash")
                    }

                    Button {
                        store.clearPlots()
                    } label: {
                        Label("Clear Plots", systemImage: "photo.on.rectangle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(IDEPalette.secondaryText)
            .accessibilityLabel("IDE options")
        }
        .padding(.leading, headerLeadingInset + windowControlsInset)
        .padding(.trailing, 14)
        .frame(height: 52)
        .background(IDEPalette.header)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.containerCornerInsets.topLeading.width
        } action: { width in
            windowControlsInset = width
        }
        .fileImporter(
            isPresented: $store.isPresentingOpenDocument,
            allowedContentTypes: [.pythonFile, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleOpen(result)
        }
        .fileExporter(
            isPresented: $store.isPresentingSaveDocument,
            document: PythonDocument(text: store.source),
            contentType: .pythonFile,
            defaultFilename: store.documentName
        ) { result in
            handleSave(result)
        }
        .sheet(isPresented: $store.isPresentingWorkspaceFiles) {
            FileWorkspaceView()
        }
        .alert("File Error", isPresented: Binding(
            get: { fileError != nil },
            set: { if !$0 { fileError = nil } }
        )) {
            Button("OK", role: .cancel) { fileError = nil }
        } message: {
            Text(fileError ?? "")
        }
    }

    /// On macOS the window content runs beneath the floating window controls,
    /// so the header starts clear of the close/minimize/zoom buttons.
    private var headerLeadingInset: CGFloat {
        #if os(macOS)
        return 100
        #else
        return 14
        #endif
    }

    private func handleOpen(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                store.loadDocument(text: text, name: url.lastPathComponent)
            } catch {
                fileError = error.localizedDescription
            }

        case .failure(let error):
            fileError = error.localizedDescription
        }
    }

    private func handleSave(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            store.markDocumentSaved(name: url.lastPathComponent)
        case .failure(let error):
            fileError = error.localizedDescription
        }
    }
}
