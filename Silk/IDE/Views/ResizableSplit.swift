import SwiftUI

/// A single-finger draggable split pane. `fraction` is the share of the
/// available length given to the leading pane and is clamped so neither pane
/// collapses below its minimum size.
struct ResizableSplit<Leading: View, Trailing: View>: View {
    let axis: Axis
    @Binding var fraction: CGFloat
    let leadingMinimum: CGFloat
    let trailingMinimum: CGFloat
    let handleThickness: CGFloat
    let leading: () -> Leading
    let trailing: () -> Trailing

    @State private var dragStartFraction: CGFloat?

    init(
        axis: Axis,
        fraction: Binding<CGFloat>,
        leadingMinimum: CGFloat = 280,
        trailingMinimum: CGFloat = 240,
        handleThickness: CGFloat = 14,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.axis = axis
        self._fraction = fraction
        self.leadingMinimum = leadingMinimum
        self.trailingMinimum = trailingMinimum
        self.handleThickness = handleThickness
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        GeometryReader { proxy in
            let horizontal = axis == .horizontal
            let total = horizontal ? proxy.size.width : proxy.size.height
            let available = max(total - handleThickness, 1)
            let lowest = min(leadingMinimum / available, 0.9)
            let highest = max(1 - (trailingMinimum / available), lowest)
            let resolved = min(max(fraction, lowest), highest)
            let leadingLength = (available * resolved).rounded()

            if horizontal {
                HStack(spacing: 0) {
                    leading()
                        .frame(width: leadingLength, height: proxy.size.height)
                    divider(horizontal: horizontal, available: available, lowest: lowest, highest: highest)
                    trailing()
                        .frame(width: max(0, available - leadingLength), height: proxy.size.height)
                }
            } else {
                VStack(spacing: 0) {
                    leading()
                        .frame(width: proxy.size.width, height: leadingLength)
                    divider(horizontal: horizontal, available: available, lowest: lowest, highest: highest)
                    trailing()
                        .frame(width: proxy.size.width, height: max(0, available - leadingLength))
                }
            }
        }
        .clipped()
    }

    private func divider(horizontal: Bool, available: CGFloat, lowest: CGFloat, highest: CGFloat) -> some View {
        ZStack {
            IDEPalette.backdrop
            Capsule()
                .fill(IDEPalette.secondaryText.opacity(0.35))
                .frame(width: horizontal ? 2 : 30, height: horizontal ? 30 : 2)
        }
        .frame(width: horizontal ? handleThickness : nil, height: horizontal ? nil : handleThickness)
        .frame(maxHeight: horizontal ? .infinity : nil)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if dragStartFraction == nil {
                        dragStartFraction = fraction
                    }
                    let base = dragStartFraction ?? fraction
                    let delta = horizontal ? value.translation.width : value.translation.height
                    let proposed = ((base * available) + delta) / available
                    fraction = min(max(proposed, lowest), highest)
                }
                .onEnded { _ in
                    dragStartFraction = nil
                }
        )
        .accessibilityLabel(horizontal ? "Resize editor and inspector" : "Resize editor and inspector height")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                fraction = min(fraction + 0.05, highest)
            case .decrement:
                fraction = max(fraction - 0.05, lowest)
            @unknown default:
                break
            }
        }
    }
}
