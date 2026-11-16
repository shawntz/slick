import Kit
import KitHosting
import SwiftUI

/// An item's icon from the app's icon provider, or an SF Symbol or glyph drawn directly, or a
/// placeholder while the provider loads it.
struct IconView: View {
    let icon: Icon?
    var size: CGFloat = 20
    let resolver: IconResolver
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        content
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        let isDark = colorScheme == .dark
        if let icon, let image = resolver.image(for: icon, points: size, scale: displayScale, isDark: isDark) {
            Image(decorative: image, scale: displayScale)
                .resizable()
        } else {
            switch icon.map({ Self.resolved($0, isDark: isDark) }) {
            case .symbol(let name, let tint):
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tint.map(Self.color) ?? Color.secondary)
                    .padding(size * 0.1)
            case .glyph(let text):
                Text(text).font(.system(size: size * 0.8))
            case .color(let color):
                Circle().fill(Self.color(color))
            default:
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(.quaternary)
            }
        }
    }

    private static func resolved(_ icon: Icon, isDark: Bool) -> Icon {
        if case .adaptive(let light, let dark) = icon { return resolved(isDark ? dark : light, isDark: isDark) }
        return icon
    }

    static func color(_ color: KitColor) -> Color {
        switch color {
        case .rgba(let red, let green, let blue, let alpha):
            return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
        case .semantic(let semantic):
            switch semantic {
            case .accent: return .accentColor
            case .primary: return .primary
            case .secondary: return .secondary
            case .red: return .red
            case .orange: return .orange
            case .yellow: return .yellow
            case .green: return .green
            case .mint: return .mint
            case .teal: return .teal
            case .cyan: return .cyan
            case .blue: return .blue
            case .indigo: return .indigo
            case .purple: return .purple
            case .pink: return .pink
            case .brown: return .brown
            case .gray: return .gray
            }
        }
    }
}

/// A feature's status at the top of its page, with a Grant button for each permission it asks for.
struct StatusBanner: View {
    let status: FeatureStatus
    let missing: [PermissionNeed]
    let grant: (Permission) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title).fontWeight(.semibold)
                    if let message = status.message {
                        Text(message).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            ForEach(missing, id: \.permission.settingsKey) { need in
                HStack {
                    Text(need.reason).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow \(need.permission.displayName)…") {
                        Task { await grant(need.permission) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch status.level {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch status.level {
        case .info: .blue
        case .warning: .orange
        case .failure: .red
        }
    }
}

/// A permission's name and live status, with Allow and System Settings buttons.
struct PermissionRow: View {
    let permission: Permission
    /// The row's title. Nil uses the permission's name.
    var title: String?
    let status: PermissionStatus
    var reason: String?
    /// Shown in place of the Allow button while the permission waits for its app to run.
    var waitingSentence: String?
    let grant: () async -> Void
    let openSettings: () async -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: permission.symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? permission.displayName)
                if let reason {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
                Label(status.label, systemImage: status.isGranted ? "checkmark.circle.fill" : "circle")
                    .font(.callout)
                    .foregroundStyle(status.isGranted ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                if let waitingSentence {
                    Text(waitingSentence).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if waitingSentence == nil && !status.isGranted && status != .restricted {
                Button("Allow…") { Task { await grant() } }
                    .accessibilityLabel("Allow \(title ?? permission.displayName)")
            }
            Button("Open System Settings") { Task { await openSettings() } }
                .buttonStyle(.link)
                .accessibilityLabel("Open \(title ?? permission.displayName) in System Settings")
        }
        .accessibilityElement(children: .contain)
    }
}

/// The toast at the bottom of the settings window.
struct ToastBanner: View {
    let center: ToastCenter

    var body: some View {
        if let shown = center.current {
            HStack(spacing: 8) {
                symbol(shown.toast.style)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shown.toast.title).fontWeight(.medium)
                    if let message = shown.toast.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Button {
                    center.dismissCurrent()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 16)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(shown.id)
        }
    }

    @ViewBuilder private func symbol(_ style: Toast.Style) -> some View {
        switch style {
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .progress: ProgressView().controlSize(.small)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
        }
    }
}

/// A number with its value at the trailing edge, next to the stepper.
struct ValueStepper<Value: Strideable>: View {
    let title: String
    var info: String?
    @Binding var value: Value
    let range: ClosedRange<Value>
    let step: Value.Stride
    let text: String

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(text).monospacedDigit().foregroundStyle(.secondary)
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
                    .accessibilityValue(text)
            }
        } label: {
            TitleAndInfo(title: title, info: info)
        }
    }
}

/// A label with help text under it, as grouped forms draw a setting's description.
struct TitleAndInfo: View {
    let title: String
    let info: String?

    var body: some View {
        Text(title)
        if let info {
            Text(info)
        }
    }
}

extension View {
    /// Asks the open question of a ``ConfirmationCenter`` as an alert.
    func confirmations(_ center: ConfirmationCenter) -> some View {
        alert(
            center.pending?.confirmation.title ?? "",
            isPresented: Binding(get: { center.pending != nil }, set: { _ in }),
            presenting: center.pending
        ) { pending in
            Button(pending.confirmation.confirmTitle, role: pending.confirmation.isDestructive ? .destructive : nil) {
                center.answer(true)
            }
            Button("Cancel", role: .cancel) { center.answer(false) }
        } message: { pending in
            if let message = pending.confirmation.message { Text(message) }
        }
    }
}
