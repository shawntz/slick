import Kit
import LauncherUI
import SwiftUI

/// The first-run window: one step at a time, with Back and Continue.
struct OnboardingView: View {
    let model: OnboardingModel
    let toasts: ToastCenter

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome: WelcomeStep()
                case .hotkey: HotkeyStep(model: model)
                case .permissions: PermissionsStep(model: model)
                case .theme: ThemeStep(model: model)
                case .done: DoneStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 36)
            .padding(.top, 32)
            Divider()
            HStack {
                StepDots(current: model.step)
                Spacer()
                if model.canGoBack {
                    Button("Back") { model.back() }
                        .keyboardShortcut(.cancelAction)
                }
                if model.step == .done {
                    Button("Start") { model.finish() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(model.step == .welcome ? "Get Started" : "Continue") { model.next() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .overlay(alignment: .bottom) { ToastBanner(center: toasts).padding(.bottom, 56) }
        .frame(width: 620, height: 500)
    }
}

private struct StepDots: View {
    let current: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                Circle()
                    .fill(step == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingModel.Step.allCases.count), \(current.title)")
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text("Welcome to \(Brand.name)").font(.largeTitle).fontWeight(.semibold)
            Text(
                "One hotkey opens one search field, and everything on your Mac sits behind it: apps, files, commands, clipboard history and more."
            )
            .font(.title3)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("It learns which result you pick for what you type. That stays on this Mac.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct HotkeyStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose your hotkey").font(.title).fontWeight(.semibold)
            Text("Press it anywhere to open the launcher. Click the field, then press the keys.")
                .foregroundStyle(.secondary)
            HStack {
                Text("Hotkey")
                Spacer()
                HotkeyRecorder(model: model.hotkey)
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Label(model.spotlightNote, systemImage: "info.circle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionsStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(.title).fontWeight(.semibold)
            Text(
                "Some features need a permission from macOS. Each is optional. Skip any of them; a feature asks again when you use it."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.permissionItems) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.permission.symbol)
                                .frame(width: 22)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.permission.displayName).fontWeight(.medium)
                                ForEach(Array(item.reasons.enumerated()), id: \.offset) { _, reason in
                                    Text("\(reason.feature): \(reason.reason)")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            if item.status.isGranted {
                                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else if item.isSkipped {
                                Text("Skipped").foregroundStyle(.secondary)
                                Button("Allow…") { Task { await model.allow(item.permission) } }
                                    .accessibilityLabel("Allow \(item.permission.displayName)")
                            } else {
                                Button("Skip") { model.skip(item.permission) }
                                    .accessibilityLabel("Skip \(item.permission.displayName)")
                                Button("Allow…") { Task { await model.allow(item.permission) } }
                                    .accessibilityLabel("Allow \(item.permission.displayName)")
                            }
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityElement(children: .contain)
                    }
                }
            }
        }
    }
}

private struct ThemeStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick a look").font(.title).fontWeight(.semibold)
            Text("You can edit any theme later in Settings, under Appearance.").foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(model.themes) { named in
                    Button {
                        model.selectTheme(named.name)
                    } label: {
                        VStack(spacing: 6) {
                            let size = ThemePreviewView.logicalSize(for: named.theme)
                            ThemePreview(theme: named.theme)
                                .aspectRatio(size.width / size.height, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(
                                            named.name == model.selectedTheme
                                                ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                                            lineWidth: 3)
                                }
                            Text(named.name)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(named.name)
                    .accessibilityAddTraits(named.name == model.selectedTheme ? .isSelected : [])
                }
            }
        }
    }
}

private struct DoneStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You are set").font(.largeTitle).fontWeight(.semibold)
            if let combo = model.hotkey.combo {
                Text("Press \(combo.displayString) to open the launcher.").font(.title3)
            } else {
                Text("Open the launcher from the menu bar item. You can set a hotkey in Settings.").font(.title3)
            }
            Text(
                "Type to search. Return opens the top result, Command-K shows every action, and Command-comma opens Settings."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
