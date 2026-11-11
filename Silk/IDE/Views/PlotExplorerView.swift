import SwiftUI

struct PlotExplorerView: View {
    @Environment(IDEStore.self) private var store
    @State private var selection: UUID?

    var body: some View {
        Group {
            if store.plots.isEmpty {
                EmptyStateView(
                    systemImage: "photo",
                    title: "No figures yet"
                )
            } else {
                VStack(spacing: 0) {
                    figureChips

                    IDEHairline()

                    if let plot = selectedPlot {
                        ZoomablePlotView(plot: plot)
                        plotMetadata(for: plot)
                    }
                }
            }
        }
        .background(IDEPalette.consoleBackground)
        .onAppear(perform: syncSelection)
        .onChange(of: store.plots.count) { _, _ in
            syncSelection()
        }
    }

    private var selectedPlot: PlotSnapshot? {
        if let selection, let match = store.plots.first(where: { $0.id == selection }) {
            return match
        }
        return store.plots.last
    }

    private func syncSelection() {
        if let selection, store.plots.contains(where: { $0.id == selection }) {
            return
        }
        selection = store.plots.last?.id
    }

    private var figureChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(store.plots.enumerated()), id: \.element.id) { index, plot in
                    let isSelected = selectedPlot?.id == plot.id
                    Button {
                        selection = plot.id
                    } label: {
                        Text("Fig \(index + 1)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(isSelected ? IDEPalette.accent : IDEPalette.secondaryText)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(
                                Capsule().fill(
                                    isSelected
                                        ? IDEPalette.accent.opacity(0.16)
                                        : Color.white.opacity(0.05)
                                )
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    isSelected
                                        ? IDEPalette.accent.opacity(0.55)
                                        : IDEPalette.stroke
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Figure \(index + 1)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(height: 44)
    }

    private func plotMetadata(for plot: PlotSnapshot) -> some View {
        HStack(spacing: 8) {
            Text("Fig \(plot.figureNumber)")
            Text("·")
                .foregroundStyle(IDEPalette.secondaryText.opacity(0.5))
            Text(plot.dimensionLabel)
            Spacer(minLength: 4)
            Text("Matplotlib · AGG")
            Text("·")
                .foregroundStyle(IDEPalette.secondaryText.opacity(0.5))
            Text(plot.createdAt, style: .time)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(IDEPalette.secondaryText)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(IDEPalette.header)
    }
}

/// Pinch to zoom up to 8x, drag to inspect, double-tap to reset. The image is
/// contained, so touch targets stay inside the pane at every iPad size.
struct ZoomablePlotView: View {
    let plot: PlotSnapshot

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                IDEPalette.consoleBackground

                if let image = plot.image {
                    Image(platformImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnifyGesture)
                        .simultaneousGesture(panGesture)
                        .onTapGesture(count: 2) { toggleZoom() }
                } else {
                    Text("This figure could not be decoded.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(IDEPalette.secondaryText)
                }
            }
            .clipped()
            .contentShape(Rectangle())
        }
        .onChange(of: plot.id) { _, _ in
            resetZoom()
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(committedScale * value.magnification, 1), 8)
            }
            .onEnded { _ in
                committedScale = scale
                if scale <= 1.01 {
                    scale = 1
                    offset = .zero
                    committedOffset = .zero
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                committedOffset = offset
            }
    }

    private func toggleZoom() {
        withAnimation(.snappy(duration: 0.24)) {
            if scale > 1.01 {
                resetZoom()
            } else {
                scale = 2.5
                committedScale = 2.5
            }
        }
    }

    private func resetZoom() {
        scale = 1
        committedScale = 1
        offset = .zero
        committedOffset = .zero
    }
}
