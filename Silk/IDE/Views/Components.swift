import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum IDEPalette {
    static let backdrop = Color(red: 0.055, green: 0.060, blue: 0.075)
    static let panel = Color(red: 0.075, green: 0.082, blue: 0.098)
    static let header = Color(red: 0.098, green: 0.106, blue: 0.126)
    static let consoleBackground = Color(red: 0.063, green: 0.070, blue: 0.086)
    static let stroke = Color.white.opacity(0.07)
    static let accent = Color(red: 0.36, green: 0.78, blue: 0.98)
    static let text = Color(white: 0.93)
    static let secondaryText = Color(white: 0.60)
    static let danger = Color(red: 1.00, green: 0.42, blue: 0.42)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.36)
    static let success = Color(red: 0.45, green: 0.86, blue: 0.58)
}

/// App mark for the header: the Silk yarn glyph in the UI accent blue with the
/// "S" badge baked into the icon artwork.
struct SilkMark: View {
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let image = Self.image {
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "circle.hexagongrid.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(IDEPalette.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    @MainActor private static let image: Image? = {
        #if canImport(UIKit)
        if let image = UIImage(named: "SilkIcon") {
            return Image(uiImage: image)
        }
        if let url = Bundle.main.url(forResource: "SilkIcon", withExtension: "png"),
           let image = UIImage(contentsOfFile: url.path) {
            return Image(uiImage: image)
        }
        #elseif canImport(AppKit)
        if let image = NSImage(named: "SilkIcon") {
            return Image(nsImage: image)
        }
        if let url = Bundle.main.url(forResource: "SilkIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return Image(nsImage: image)
        }
        #endif
        return nil
    }()
}

struct IDEHairline: View {
    var body: some View {
        Rectangle()
            .fill(IDEPalette.stroke)
            .frame(height: 1)
    }
}

struct PanelHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    let trailing: () -> Trailing

    init(title: String, systemImage: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IDEPalette.secondaryText)

            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(IDEPalette.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 6)

            trailing()
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(IDEPalette.header)
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, systemImage: String) {
        self.init(title: title, systemImage: systemImage) { EmptyView() }
    }
}

struct RuntimeBanner: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String
    var showsProgress = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(IDEPalette.text)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(IDEPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if showsProgress {
                ProgressView().controlSize(.small).tint(tint)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(IDEToolbarButtonStyle(kind: .secondary))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(tint.opacity(0.22)).frame(height: 1)
        }
    }
}

struct IDEToolbarButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .frame(minHeight: 34)
            .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return IDEPalette.backdrop
        case .secondary: return IDEPalette.text
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return IDEPalette.accent
        case .secondary: return Color.white.opacity(0.075)
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return IDEPalette.accent.opacity(0.85)
        case .secondary: return IDEPalette.stroke
        }
    }
}

private struct IDEIconButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(IDEPalette.secondaryText)
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
    }
}

extension View {
    func ideIconButtonStyle() -> some View {
        modifier(IDEIconButtonModifier())
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String = ""

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(IDEPalette.secondaryText.opacity(0.7))
            Text(title)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(IDEPalette.text)
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(IDEPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
