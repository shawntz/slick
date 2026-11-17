import Kit
import LauncherUI
import SwiftUI

/// The first-run window: one step at a time, with Back and Continue.
///
/// Every step has the same size. A step whose list can be longer than the room it has, the
/// optional features, the permissions and the themes, scrolls that list in an area that ends clear
/// of the footer, with its edges faded, so nothing it holds pushes the footer or reads as cut off.
struct OnboardingView: View {
    let model: OnboardingModel
    let toasts: ToastCenter

    /// The window's content size, the same on every step.
    static let size = CGSize(width: 680, height: 580)
    /// The room on the left and right of everything the step shows.
    static let margin: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome: WelcomeStep()
                case .hotkey: HotkeyStep(model: model)
                case .features: FeaturesStep(model: model)
                case .permissions: PermissionsStep(model: model)
                case .theme: ThemeStep(model: model)
                case .done: DoneStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 36)
            .padding(.bottom, 12)
            .clipped()
            Divider()
            HStack(spacing: 8) {
                StepDots(current: model.step)
                Spacer()
                // While the hotkey recorder records, Escape and Return go to it, not to Back and
                // Continue.
                if model.canGoBack {
                    Button("Back") { model.back() }
                        .keyboardShortcut(model.hotkey.isRecording ? nil : .cancelAction)
                }
                if model.step == .done {
                    Button("Start") { model.finish() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(model.step == .welcome ? "Get Started" : "Continue") { Task { await model.next() } }
                        .keyboardShortcut(model.hotkey.isRecording ? nil : .defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isTakingKeys)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .overlay(alignment: .bottom) { ToastBanner(center: toasts).padding(.bottom, 56) }
        .frame(width: Self.size.width, height: Self.size.height)
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

/// A step's title and the paragraph under it, inside the window's margins.
private struct StepHeader: View {
    let title: String
    var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title).fontWeight(.semibold)
            if let text {
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, OnboardingView.margin)
    }
}

/// The area a step's list scrolls in. It spans the window's width, so its scroller sits at the
/// edge, keeps its content inside the margins, and fades the content at its top and bottom edges.
/// The content starts below the top fade and ends above the bottom one, so at rest nothing it holds
/// is faded at the top, and the last card clears the bottom edge when scrolled to the end.
struct StepScrollArea<Content: View>: View {
    /// How tall each faded edge is.
    static var fade: CGFloat { 16 }

    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, OnboardingView.margin)
                .padding(.vertical, Self.fade)
        }
        .overlay(alignment: .top) { edge(fadingDown: true) }
        .overlay(alignment: .bottom) { edge(fadingDown: false) }
    }

    private func edge(fadingDown: Bool) -> some View {
        let background = Color(nsColor: .windowBackgroundColor)
        return LinearGradient(
            colors: [background, background.opacity(0)], startPoint: fadingDown ? .top : .bottom,
            endPoint: fadingDown ? .bottom : .top
        )
        .frame(height: Self.fade)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A card as wide as the area it sits in, with the same padding and corners on every step.
private struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension View {
    fileprivate func card() -> some View { modifier(Card()) }
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
                "Press your hotkey and start typing. \(Brand.name) finds the app, file, setting or command you mean. Press Return to open it."
            )
            .font(.title3)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "\(Brand.name) remembers what you pick and shows it first next time. What it learns stays on this Mac."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, OnboardingView.margin)
    }
}

private struct HotkeyStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(title: "Choose Your Hotkey")
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hotkey")
                        Text("Press it anywhere to open \(Brand.name).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HotkeyRecorder(model: model.hotkey, showsHeldNote: !isWaiting)
                }
                .card()
                guide
            }
            .padding(.horizontal, OnboardingView.margin)
        }
    }

    @ViewBuilder private var guide: some View {
        switch model.hotkeyGuide {
        case .waiting(let wait) where wait.canTurnOff:
            VStack(alignment: .leading, spacing: 8) {
                Text(SpotlightShortcutGuide.takeOverNote(wait))
                    .fixedSize(horizontal: false, vertical: true)
                Text(SpotlightShortcutGuide.takeOverFootnote(wait))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .waiting(let wait):
            WaitingGuide(model: model, wait: wait)
        case .freed(let combo):
            Label(SpotlightShortcutGuide.freedLine(combo), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fontWeight(.medium)
        case .none:
            Text(SpotlightShortcutGuide.otherKeysNote)
                .foregroundStyle(.secondary)
        }
    }

    private var isWaiting: Bool {
        if case .waiting = model.hotkeyGuide { return true }
        return false
    }
}

/// What to do while a macOS shortcut the app cannot turn off uses the launcher's keys, or after a
/// try to turn Spotlight's off failed, and a line that says the launcher waits.
private struct WaitingGuide: View {
    let model: OnboardingModel
    let wait: LauncherHotkeyWait

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                wait.turnOffFailed
                    ? SpotlightShortcutGuide.failedNote(wait) : SpotlightShortcutGuide.cannotTurnOffNote(wait)
            )
            .fixedSize(horizontal: false, vertical: true)
            Button(SpotlightShortcutGuide.openButton) { model.openKeyboardSettings() }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(SpotlightShortcutGuide.waitingLine(wait)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct FeaturesStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StepHeader(
                title: "Optional Features",
                text: "Turn on what you want. You can change this later in Settings, under Features.")
            StepScrollArea {
                VStack(spacing: 10) {
                    ForEach(model.optionalFeatures) { feature in
                        HStack(alignment: .center, spacing: 12) {
                            IconView(icon: feature.icon, size: 24, resolver: model.icons)
                                .frame(width: 24, height: 24)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(feature.name).fontWeight(.medium)
                                Text(feature.summary)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Toggle(
                                feature.name,
                                isOn: Binding(
                                    get: { feature.isEnabled },
                                    set: { model.setEnabled($0, feature: feature.id) })
                            )
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                        .card()
                    }
                }
            }
        }
    }
}

private struct PermissionsStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StepHeader(
                title: "Permissions",
                text:
                    "Some features need a permission from macOS. You can skip any of them. A feature asks again when you use it."
            )
            StepScrollArea {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.permissionGroups.enumerated()), id: \.element.group) { index, section in
                        Text(section.group.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.top, index == 0 ? 0 : 8)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.items) { item in
                            PermissionCard(
                                model: model, item: item,
                                coversFolders: item.permission == .fullDiskAccess
                                    && PermissionGroup.listsFolderFullDiskAccessAllows(
                                        section.items.map(\.permission))
                            )
                        }
                    }
                }
            }
        }
        .task { await model.watchPermissions() }
    }
}

/// One permission on the permissions step: what it is, who wants it and why, and what the person
/// can do about it now.
private struct PermissionCard: View {
    let model: OnboardingModel
    let item: OnboardingModel.PermissionItem
    /// True for Full Disk Access while folders it also allows are listed below it.
    let coversFolders: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.permission.symbol)
                .frame(width: 22)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).fontWeight(.medium)
                ForEach(Array(item.reasons.enumerated()), id: \.offset) { _, reason in
                    Text(Self.sentence(feature: reason.feature, reason: reason.reason))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if coversFolders {
                    Text(PermissionGroup.fullDiskAccessCoversFolders)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .card()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var trailing: some View {
        if item.status.isGranted {
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if item.isAsking {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Asking macOS for \(item.title)")
        } else if let sentence = item.unansweredSentence {
            VStack(alignment: .trailing, spacing: 6) {
                Text(sentence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { Task { await model.openSettings(for: item.permission) } }
                    .accessibilityLabel("Open \(item.permission.displayName) in System Settings")
            }
            .frame(width: 220, alignment: .trailing)
        } else if let sentence = item.waitingSentence {
            Text(sentence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(width: 220, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        } else if item.isSkipped {
            HStack(spacing: 8) {
                Text("Skipped").foregroundStyle(.secondary)
                Button("Allow…") { Task { await model.allow(item.permission) } }
                    .accessibilityLabel("Allow \(item.title)")
            }
        } else {
            HStack(spacing: 8) {
                Button("Skip") { model.skip(item.permission) }
                    .accessibilityLabel("Skip \(item.title)")
                Button("Allow…") { Task { await model.allow(item.permission) } }
                    .accessibilityLabel("Allow \(item.title)")
            }
        }
    }

    /// One feature's reason as a sentence: who uses the permission and for what. Kit asks each
    /// reason to start with a verb, so the verb follows "uses it to".
    static func sentence(feature: String, reason: String) -> String {
        guard let first = reason.first else { return feature }
        let rest = reason.dropFirst()
        let startsWithWord = first.isUppercase && (rest.first.map { $0.isLowercase } ?? true)
        return "\(feature) uses it to \(startsWithWord ? first.lowercased() : String(first))\(rest)"
    }
}

private struct ThemeStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StepHeader(title: "Pick a Look", text: "You can change the theme later in Settings, under Appearance.")
            StepScrollArea {
                ThemeTiles(model: model)
            }
        }
    }
}

/// Every theme as a tile of one size, four to a row, with its name under it. Clicking a tile
/// selects that theme and moves the ring to it.
struct ThemeTiles: View {
    let model: OnboardingModel

    static let columns = 4
    static let spacing: CGFloat = 14
    /// The height of every preview's frame. Each preview fits inside it at its own proportions.
    static let previewHeight: CGFloat = 88

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: Self.columns),
            alignment: .leading, spacing: Self.spacing
        ) {
            ForEach(model.themes) { named in
                ThemeTile(named: named, isSelected: named.name == model.selectedTheme) {
                    model.selectTheme(named.name)
                }
            }
        }
    }
}

/// One theme: the launcher drawn with it, fitted in a fixed frame, with the selection ring around
/// the frame. The preview is an AppKit view, which SwiftUI's button never sees a click on, so the
/// preview runs the click itself; the name under it is the SwiftUI button's.
private struct ThemeTile: View {
    let named: NamedTheme
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                let size = ThemePreviewView.logicalSize(for: named.theme)
                ThemePreview(theme: named.theme, onClick: select)
                    .aspectRatio(size.width / size.height, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: ThemeTiles.previewHeight)
                    .background(.quaternary.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 3)
                            .allowsHitTesting(false)
                    }
                Text(named.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(named.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DoneStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You're All Set").font(.largeTitle).fontWeight(.semibold)
            Group {
                if case .waiting(let wait) = model.hotkeyGuide {
                    Text(SpotlightShortcutGuide.doneWaiting(wait))
                } else if let combo = model.hotkey.combo {
                    Text(SpotlightShortcutGuide.doneBound(combo))
                } else {
                    Text(SpotlightShortcutGuide.doneNoHotkey)
                }
            }
            .font(.title3)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "Type to search. Press Return to open the top result. Press Command-K to see what else you can do with it. Press Command-comma to open Settings."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if model.offersUpdates {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(UpdateStrings.automaticTitle).fontWeight(.medium)
                        Text(UpdateStrings.whatIsSent)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(
                        UpdateStrings.automaticTitle,
                        isOn: Binding(get: { model.checksForUpdates }, set: { model.checksForUpdates = $0 })
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .card()
            }
        }
        .padding(.horizontal, OnboardingView.margin)
    }
}
