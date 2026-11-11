import SwiftUI

struct VariableExplorerView: View {
    @Environment(IDEStore.self) private var store

    /// The split layout currently in effect; drives the toggle's glyph.
    let layout: WorkspaceLayout

    @AppStorage("Spyder.paneAxis") private var paneAxisPreference = SplitAxisPreference.automatic.rawValue

    @State private var query = ""
    @State private var presentedSheet: ExplorerSheet?
    @State private var showsClearConfirmation = false

    private enum ExplorerSheet: Identifiable {
        case variable(PythonVariable)
        case files

        var id: String {
            switch self {
            case .variable(let variable): return "variable-\(variable.name)"
            case .files: return "files"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Variables", systemImage: "tablecells") {
                HStack(spacing: 1) {
                    countBadge
                    layoutButton

                    if !store.hiddenVariableBarActions.contains(.sort) {
                        sortMenu
                    }
                    if !store.hiddenVariableBarActions.contains(.reload) {
                        reloadButton
                    }
                    if !store.hiddenVariableBarActions.contains(.files) {
                        filesButton
                    }
                    if !store.hiddenVariableBarActions.contains(.clear) {
                        clearButton
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                updateHiddenActions(for: width)
            }

            IDEHairline()
            searchField

            content
        }
        .background(IDEPalette.panel)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .variable(let variable):
                VariableDetailSheet(variable: variable)
            case .files:
                FileWorkspaceView()
            }
        }
        .confirmationDialog(
            "Remove all variables?",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) {
                store.clearVariables()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every user variable from the Python workspace. It cannot be undone.")
        }
    }

    private var countBadge: some View {
        Text("\(store.variables.count)")
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(IDEPalette.secondaryText)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .fixedSize()
            .layoutPriority(1)
    }

    /// Shows the active split and flips to the other mode when tapped.
    private var layoutButton: some View {
        Button {
            paneAxisPreference = (layout == .sideBySide ? SplitAxisPreference.stacked : .sideBySide).rawValue
        } label: {
            Image(systemName: layout.symbolName)
                .ideIconButtonStyle()
        }
        .accessibilityLabel("Switch to \(layout.alternate.title) layout")
    }

    private var sortMenu: some View {
        Menu {
            Section("Sort by") {
                Picker("Sort by", selection: Binding(
                    get: { store.variableSortOption },
                    set: { store.variableSortOption = $0 }
                )) {
                    ForEach(VariableSortOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
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
            Image(systemName: "arrow.up.arrow.down")
                .ideIconButtonStyle()
        }
        .accessibilityLabel("Sort variables")
    }

    private var reloadButton: some View {
        Button {
            store.refreshWorkspace()
        } label: {
            if store.isRefreshingWorkspace {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 34, height: 34)
            } else {
                Image(systemName: "arrow.clockwise")
                    .ideIconButtonStyle()
            }
        }
        .accessibilityLabel("Reload variables")
    }

    private var filesButton: some View {
        Button {
            presentedSheet = .files
        } label: {
            Image(systemName: "folder")
                .ideIconButtonStyle()
        }
        .accessibilityLabel("Workspace files")
    }

    private var clearButton: some View {
        Button {
            showsClearConfirmation = true
        } label: {
            Image(systemName: "trash")
                .ideIconButtonStyle()
        }
        .disabled(store.variables.isEmpty)
        .opacity(store.variables.isEmpty ? 0.35 : 1)
        .accessibilityLabel("Clear variables")
    }

    /// Drops the least-used actions first so the title and split toggle keep
    /// their room; the header menu picks up whatever is hidden.
    private func updateHiddenActions(for width: CGFloat) {
        var hidden: VariableBarHiddenActions = []
        if width < 340 { hidden.insert(.clear) }
        if width < 305 { hidden.insert(.files) }
        if width < 270 { hidden.insert(.sort) }
        if width < 235 { hidden.insert(.reload) }

        if store.hiddenVariableBarActions != hidden {
            store.hiddenVariableBarActions = hidden
        }
    }

    private var filteredVariables: [PythonVariable] {
        let base: [PythonVariable]
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            base = store.variables
        } else {
            base = store.variables.filter { variable in
                variable.name.localizedCaseInsensitiveContains(query)
                    || variable.typeName.localizedCaseInsensitiveContains(query)
                    || variable.summary.localizedCaseInsensitiveContains(query)
            }
        }

        let sorted: [PythonVariable]
        switch store.variableSortOption {
        case .name:
            sorted = base.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .type:
            sorted = base.sorted { lhs, rhs in
                if lhs.displayType == rhs.displayType {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.displayType.localizedStandardCompare(rhs.displayType) == .orderedAscending
            }
        case .size:
            sorted = base.sorted { lhs, rhs in
                let left = sizeHint(lhs.shape)
                let right = sizeHint(rhs.shape)
                if left == right {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return left < right
            }
        case .value:
            sorted = base.sorted { $0.summary.localizedStandardCompare($1.summary) == .orderedAscending }
        }

        return store.variableSortAscending ? sorted : Array(sorted.reversed())
    }

    private func sizeHint(_ shape: String) -> Int {
        if shape.hasPrefix("len ") {
            return Int(shape.dropFirst(4)) ?? 0
        }
        if shape.contains("x") {
            return shape.split(separator: "x").compactMap { Int($0) }.reduce(1, *)
        }
        if shape == "-" || shape == "scalar" {
            return 1
        }
        return Int(shape) ?? 0
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IDEPalette.secondaryText)

            TextField("Filter variables", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .ideNoAutocapitalization()

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(IDEPalette.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(IDEPalette.consoleBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(IDEPalette.stroke)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if store.variables.isEmpty {
            EmptyStateView(
                systemImage: "square.stack.3d.up",
                title: "No variables yet"
            )
        } else if filteredVariables.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "No matches",
                message: "No variable matches “\(query)”."
            )
        } else {
            List {
                ForEach(filteredVariables) { variable in
                    Button {
                        presentedSheet = .variable(variable)
                    } label: {
                        VariableRow(variable: variable)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                    .listRowBackground(IDEPalette.panel)
                    .listRowSeparatorTint(IDEPalette.stroke.opacity(0.6))
                    .contextMenu {
                        Button {
                            presentedSheet = .variable(variable)
                        } label: {
                            Label("View Variable", systemImage: "rectangle.grid.2x2")
                        }

                        Button {
                            Clipboard.copy(variable.name)
                        } label: {
                            Label("Copy Name", systemImage: "textformat")
                        }

                        Button {
                            Clipboard.copy(variable.summary)
                        } label: {
                            Label("Copy Value", systemImage: "doc.on.doc")
                        }

                        Divider()

                        Button(role: .destructive) {
                            store.deleteVariable(variable)
                        } label: {
                            Label("Delete Variable", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            store.deleteVariable(variable)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 44)
        }
    }
}

// MARK: - Row

private struct VariableRow: View {
    let variable: PythonVariable

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: variable.kind.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(variable.kind.tintColor)
                .frame(width: 18, height: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(variable.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(IDEPalette.text)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(variable.shape)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(IDEPalette.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(variable.kind.tintColor.opacity(0.14)))
                        .lineLimit(1)
                }

                Text(variable.typeName)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(variable.kind.tintColor.opacity(0.9))
                    .lineLimit(1)

                Text(variable.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(IDEPalette.secondaryText.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(variable.name), \(variable.typeName), shape \(variable.shape)")
    }
}

// MARK: - Detail sheet

private struct VariableDetailSheet: View {
    let variable: PythonVariable

    @Environment(IDEStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var preview: VariablePreview?
    @State private var isLoading = true
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                summary
                IDEHairline()
                content
            }
            .background(IDEPalette.backdrop)
            .navigationTitle(variable.name)
            .ideInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .destructive) {
                        store.deleteVariable(variable)
                        dismiss()
                    } label: {
                        Image(systemName: "trash")
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(IDEPalette.backdrop)
        .task(id: variable.name) {
            await load()
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: variable.kind.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(variable.kind.tintColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(variable.typeName)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(variable.kind.tintColor)
                        .lineLimit(1)
                    Text("shape \(variable.shape)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(IDEPalette.secondaryText)
                }

                Spacer(minLength: 4)

                Button {
                    copyValue()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(IDEToolbarButtonStyle(kind: .secondary))
            }

            Text(variable.summary.isEmpty ? "—" : variable.summary)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(IDEPalette.secondaryText)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(IDEPalette.panel)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading value…")
                    .font(.system(size: 11))
                    .foregroundStyle(IDEPalette.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview, let error = preview.error {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Preview unavailable",
                message: error
            )
        } else if let preview, !preview.rows.isEmpty {
            VStack(spacing: 0) {
                VariablePreviewTable(preview: preview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !preview.note.isEmpty {
                    Text(preview.note)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(IDEPalette.secondaryText)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(IDEPalette.header)
                }
            }
        } else {
            EmptyStateView(
                systemImage: "eye.slash",
                title: "No table preview",
                message: "This value has no columns to display. The summary above is the full representation."
            )
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        preview = await store.preview(for: variable)
        isLoading = false
    }

    private func copyValue() {
        if let repr = preview?.repr, !repr.isEmpty {
            Clipboard.copy(repr)
        } else {
            Clipboard.copy(variable.summary)
        }
        copied = true
    }
}

// MARK: - Preview table

private struct VariablePreviewTable: View {
    let preview: VariablePreview

    private let indexWidth: CGFloat = 48
    private let cellWidth: CGFloat = 112

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                ForEach(Array(preview.rows.enumerated()), id: \.offset) { index, row in
                    dataRow(row: row, rowIndex: index)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(preview.columns.enumerated()), id: \.offset) { index, column in
                Text(column.isEmpty ? " " : column)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(IDEPalette.secondaryText)
                    .lineLimit(1)
                    .frame(width: index == 0 ? indexWidth : cellWidth, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .background(IDEPalette.header)
            }
        }
    }

    private func dataRow(row: [String], rowIndex: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, cell in
                Text(cell)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(cellColor(cell, columnIndex: columnIndex))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: columnIndex == 0 ? indexWidth : cellWidth, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(cellBackground(columnIndex: columnIndex, rowIndex: rowIndex))
            }
        }
    }

    private func cellBackground(columnIndex: Int, rowIndex: Int) -> Color {
        if columnIndex == 0 {
            return Color.white.opacity(rowIndex.isMultiple(of: 2) ? 0.035 : 0.015)
        }
        let palette: [Color] = [
            IDEPalette.accent.opacity(0.13),
            Color(red: 0.74, green: 0.58, blue: 0.99).opacity(0.14),
            Color(red: 0.38, green: 0.84, blue: 0.80).opacity(0.10),
        ]
        return palette[(columnIndex - 1) % palette.count]
    }

    private func cellColor(_ cell: String, columnIndex: Int) -> Color {
        if columnIndex == 0 {
            return IDEPalette.secondaryText
        }
        if cell == "None" || cell == "nan" || cell == "NaN" || cell == "NaT" {
            return IDEPalette.secondaryText
        }
        if Double(cell) != nil {
            return Color(red: 0.98, green: 0.72, blue: 0.36)
        }
        if cell.hasPrefix("'") || cell.hasPrefix("\"") {
            return Color(red: 0.55, green: 0.88, blue: 0.58)
        }
        return IDEPalette.text
    }
}
