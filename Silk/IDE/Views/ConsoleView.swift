import SwiftUI

// MARK: - Console content

struct ConsoleView: View {
    @Environment(IDEStore.self) private var store

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if store.console.isEmpty {
                    EmptyStateView(
                        systemImage: "terminal",
                        title: "Console is empty"
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.console) { line in
                            Group {
                                if line.level == .fileHint {
                                    FileAccessHint()
                                } else {
                                    ConsoleLineRow(line: line)
                                }
                            }
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: store.console.count) { _, _ in
                guard let last = store.console.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
        .background(IDEPalette.consoleBackground)
    }
}

private struct ConsoleLineRow: View {
    let line: ConsoleLine

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(prefix)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color.opacity(0.85))
                .frame(width: 10, alignment: .leading)
                .padding(.top, 1)

            Text(line.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(highlight)
        )
    }

    private var highlight: Color {
        switch line.level {
        case .error: return IDEPalette.danger.opacity(0.10)
        case .stderr: return IDEPalette.warning.opacity(0.06)
        default: return .clear
        }
    }

    private var prefix: String {
        switch line.level {
        case .input: return "›"
        case .stdout: return " "
        case .stderr: return "!"
        case .error: return "✕"
        case .system: return "·"
        case .success: return "✓"
        case .fileHint: return " "
        }
    }

    private var color: Color {
        switch line.level {
        case .input: return IDEPalette.accent
        case .stdout: return IDEPalette.text.opacity(0.92)
        case .stderr: return IDEPalette.warning
        case .error: return IDEPalette.danger
        case .system: return IDEPalette.secondaryText
        case .success: return IDEPalette.success
        case .fileHint: return IDEPalette.warning
        }
    }
}

/// Orange console alert for a missing-file traceback. "Workspace Files" is an
/// underlined link that opens the file browser; tapping the card does too.
private struct FileAccessHint: View {
    @Environment(IDEStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IDEPalette.warning)
                .padding(.top, 1)

            message
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(IDEPalette.warning.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(IDEPalette.warning.opacity(0.45), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture { store.isPresentingWorkspaceFiles = true }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "silk", url.host == "workspace-files" else {
                return .systemAction
            }
            store.isPresentingWorkspaceFiles = true
            return .handled
        })
    }

    private var message: Text {
        Text("Silk can't access your iPad's files. Add files to the \(folderIcon) \(workspaceLink) to let Silk use them.")
    }

    private var folderIcon: Text {
        Text(Image(systemName: "folder"))
            .foregroundColor(IDEPalette.warning)
    }

    private var workspaceLink: Text {
        var text = AttributedString("Workspace Files")
        text.link = URL(string: "silk://workspace-files")
        text.foregroundColor = IDEPalette.warning
        text.underlineStyle = Text.LineStyle(pattern: .solid, color: IDEPalette.warning)
        return Text(text)
    }
}

// MARK: - Tabbed console + plots

struct ConsolePlotPanel: View {
    @Environment(IDEStore.self) private var store

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Inspector tab", selection: $store.selectedTab) {
                    Text("Console").tag(InspectorTab.console)
                    Text(store.plots.isEmpty ? "Plots" : "Plots · \(store.plots.count)")
                        .tag(InspectorTab.plots)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)

                Spacer(minLength: 4)

                if store.selectedTab == .console {
                    Button {
                        Clipboard.copy(store.consoleText)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .ideIconButtonStyle()
                    }
                    .accessibilityLabel("Copy console")

                    Button {
                        store.clearConsole()
                    } label: {
                        Image(systemName: "trash")
                            .ideIconButtonStyle()
                    }
                    .accessibilityLabel("Clear console")
                } else {
                    Button {
                        store.clearPlots()
                    } label: {
                        Image(systemName: "trash")
                            .ideIconButtonStyle()
                    }
                    .accessibilityLabel("Clear plots")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(IDEPalette.header)

            IDEHairline()

            switch store.selectedTab {
            case .console:
                ConsoleView()
            case .plots:
                PlotExplorerView()
            }
        }
    }
}

// MARK: - Single-section panels (compact inspector)

struct ConsolePanel: View {
    @Environment(IDEStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Console", systemImage: "terminal") {
                HStack(spacing: 2) {
                    Button {
                        Clipboard.copy(store.consoleText)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .ideIconButtonStyle()
                    }
                    .accessibilityLabel("Copy console")

                    Button {
                        store.clearConsole()
                    } label: {
                        Image(systemName: "trash")
                            .ideIconButtonStyle()
                    }
                    .accessibilityLabel("Clear console")
                }
            }

            IDEHairline()
            ConsoleView()
        }
    }
}

struct PlotPanel: View {
    @Environment(IDEStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Plots", systemImage: "photo") {
                Button {
                    store.clearPlots()
                } label: {
                    Image(systemName: "trash")
                        .ideIconButtonStyle()
                }
                .accessibilityLabel("Clear plots")
            }

            IDEHairline()
            PlotExplorerView()
        }
    }
}
