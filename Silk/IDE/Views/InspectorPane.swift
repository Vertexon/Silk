import SwiftUI

struct InspectorPane: View {
    let isCompact: Bool
    let layout: WorkspaceLayout
    @Binding var variableFraction: CGFloat
    @Binding var compactSection: InspectorSection

    var body: some View {
        Group {
            if isCompact {
                VStack(spacing: 0) {
                    Picker("Inspector section", selection: $compactSection) {
                        Text("Variables").tag(InspectorSection.variables)
                        Text("Console").tag(InspectorSection.console)
                        Text("Plots").tag(InspectorSection.plots)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)

                    IDEHairline()

                    switch compactSection {
                    case .variables:
                        VariableExplorerView(layout: layout)
                    case .console:
                        ConsolePanel()
                    case .plots:
                        PlotPanel()
                    }
                }
            } else {
                ResizableSplit(
                    axis: .vertical,
                    fraction: $variableFraction,
                    leadingMinimum: 130,
                    trailingMinimum: 160,
                    handleThickness: 14
                ) {
                    VariableExplorerView(layout: layout)
                } trailing: {
                    ConsolePlotPanel()
                }
            }
        }
        .background(IDEPalette.panel)
    }
}
