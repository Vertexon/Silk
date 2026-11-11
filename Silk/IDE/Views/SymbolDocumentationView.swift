import SwiftUI

struct SymbolDocumentationView: View {
    let symbol: String?
    let help: SymbolHelp?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            IDEHairline()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IDEPalette.panel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(IDEPalette.accent)

            Text(help?.title ?? symbol ?? "Documentation")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(IDEPalette.text)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let module = help?.module, !module.isEmpty {
                Text(module)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(IDEPalette.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(IDEPalette.header)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Looking up \(symbol ?? "symbol")…")
                    .font(.system(size: 13))
                    .foregroundStyle(IDEPalette.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = help?.error {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(IDEPalette.warning)
                    Text("No documentation for \(symbol ?? "this name")")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(IDEPalette.text)
                }

                Text(error)
                    .font(.system(size: 13.5, design: .monospaced))
                    .foregroundStyle(IDEPalette.text.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                Text("Place the caret on a name that the Python session has defined, then open Docs again.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(IDEPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let help {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(help.signature)
                        .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(IDEPalette.accent)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(help.doc.isEmpty ? "No docstring is available for this object." : help.doc)
                        .font(.system(size: 13.5, design: .monospaced))
                        .foregroundStyle(IDEPalette.text.opacity(0.9))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyStateView(
                systemImage: "text.cursor",
                title: "Place the caret on a name",
                message: "Tap inside a function, module or variable name, then open Docs again."
            )
        }
    }
}
