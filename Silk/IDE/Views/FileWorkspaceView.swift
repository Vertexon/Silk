import SwiftUI
import UniformTypeIdentifiers

/// Files live in Pyodide's current working directory (`/home/pyodide`), so a
/// CSV imported here is readable as `np.genfromtxt("data.csv")`.
struct FileWorkspaceView: View {
    @Environment(IDEStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var showsImporter = false
    @State private var exportPayload: ExportPayload?

    private struct ExportPayload: Identifiable {
        let id = UUID()
        let name: String
        let data: Data
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                IDEHairline()
                content
            }
            .background(IDEPalette.backdrop)
            .navigationTitle("Workspace Files")
            .ideInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(!store.runtime.isReady)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await store.refreshFiles() }
                    } label: {
                        if store.isLoadingFiles {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(store.isLoadingFiles)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(IDEPalette.backdrop)
        .task {
            await store.refreshFiles()
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await store.importFiles(at: urls) }
            case .failure(let error):
                store.reportFileError(error.localizedDescription)
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportPayload != nil },
                set: { if !$0 { exportPayload = nil } }
            ),
            document: exportPayload.map { WorkspaceFileDocument(data: $0.data) },
            contentType: .data,
            defaultFilename: exportPayload?.name
        ) { result in
            if case .failure(let error) = result {
                store.reportFileError(error.localizedDescription)
            }
            exportPayload = nil
        }
        .alert("File Error", isPresented: Binding(
            get: { store.fileError != nil },
            set: { if !$0 { store.fileError = nil } }
        )) {
            Button("OK", role: .cancel) { store.fileError = nil }
        } message: {
            Text(store.fileError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .foregroundStyle(IDEPalette.accent)
                Text("Python working directory")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(IDEPalette.text)
                Spacer(minLength: 4)
                Text("\(store.files.count) files")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(IDEPalette.secondaryText)
            }

            Text("Read imported files by name: np.genfromtxt(\"data.csv\") or open(\"notes.txt\"). Files reset when Python restarts.")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(IDEPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(IDEPalette.panel)
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoadingFiles && store.files.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading the Python working directory…")
                    .font(.system(size: 11))
                    .foregroundStyle(IDEPalette.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.files.isEmpty {
            EmptyStateView(
                systemImage: "folder.badge.plus",
                title: "No files yet",
                message: "Import a CSV, NumPy array or text file, then read it by name from Python."
            )
        } else {
            List {
                ForEach(store.files) { file in
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: file.name))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(IDEPalette.accent)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(IDEPalette.text)
                                .lineLimit(1)
                            Text(file.sizeLabel)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(IDEPalette.secondaryText)
                        }

                        Spacer(minLength: 4)

                        Menu {
                            Button {
                                beginExport(file)
                            } label: {
                                Label("Export to Files…", systemImage: "square.and.arrow.up")
                            }

                            Button {
                                Clipboard.copy(file.name)
                            } label: {
                                Label("Copy File Name", systemImage: "textformat")
                            }

                            Divider()

                            Button(role: .destructive) {
                                Task { await store.deleteFile(named: file.name) }
                            } label: {
                                Label("Delete File", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(IDEPalette.secondaryText)
                                .frame(width: 34, height: 34)
                                .contentShape(Rectangle())
                        }
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(IDEPalette.panel)
                    .listRowSeparatorTint(IDEPalette.stroke.opacity(0.6))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await store.deleteFile(named: file.name) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func beginExport(_ file: WorkspaceFile) {
        Task { @MainActor in
            guard let data = await store.exportFile(named: file.name) else { return }
            exportPayload = ExportPayload(name: file.name, data: data)
        }
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "csv", "tsv":
            return "tablecells"
        case "npy", "npz":
            return "square.stack.3d.up"
        case "json":
            return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "pdf":
            return "photo"
        case "txt", "md", "log":
            return "doc.text"
        default:
            return "doc"
        }
    }
}
