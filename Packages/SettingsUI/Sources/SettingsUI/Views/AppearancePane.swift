import AppKit
import LauncherUI
import SwiftUI

struct AppearancePane: View {
    @Bindable var model: AppearanceModel
    @State private var isNaming = false
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                preview
            }
            Section("Theme") {
                Picker("Theme", selection: Binding(get: { model.selectedName }, set: { model.select($0) })) {
                    Section("Built in") {
                        ForEach(model.themes.filter(\.isBuiltIn)) { Text($0.name).tag($0.name) }
                    }
                    let own = model.themes.filter { !$0.isBuiltIn }
                    if !own.isEmpty {
                        Section("Yours") {
                            ForEach(own) { Text($0.name).tag($0.name) }
                        }
                    }
                }
                HStack {
                    if !model.isBuiltIn {
                        Button("Save") { model.save() }
                            .disabled(!model.isEdited)
                    }
                    Button("Save as New Theme…") {
                        newName = model.suggestedNewName
                        isNaming = true
                    }
                    Button("Revert") { model.revert() }
                        .disabled(!model.isEdited)
                    Spacer()
                    Menu("More") {
                        Button("Import Theme…") { Task { await model.importTheme() } }
                        Button("Export Theme…") { Task { await model.exportTheme() } }
                        if !model.isBuiltIn {
                            Divider()
                            Button("Delete \(model.selectedName)…", role: .destructive) {
                                Task { await model.delete(model.selectedName) }
                            }
                        }
                    }
                    .fixedSize()
                }
                if !model.summary.isEmpty {
                    Text(model.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if model.isEdited {
                    Text(
                        model.isBuiltIn
                            ? "Built-in themes stay as they ship. Save your changes as a new theme."
                            : "The launcher keeps the saved theme until you save."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                ForEach(model.problems, id: \.file) { problem in
                    Label(
                        "\(problem.file.lastPathComponent) was skipped: \(problem.reason).",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            }
            Section("Glass") {
                Picker("Style", selection: $model.glassStyle) {
                    Text("Regular").tag(GlassStyle.regular)
                    Text("Clear").tag(GlassStyle.clear)
                }
                .pickerStyle(.segmented)
                Picker("Arrangement", selection: $model.layout) {
                    Text("One Piece").tag(PanelLayout.single)
                    Text("Search Field Apart").tag(PanelLayout.split)
                }
                .pickerStyle(.segmented)
                tintRow("Light tint", dark: false)
                tintRow("Dark tint", dark: true)
                LabeledContent {
                    Slider(value: $model.clarity, in: AppearanceModel.Limits.clarity)
                        .accessibilityValue(String(format: "%.2f", model.clarity))
                } label: {
                    Text("Clarity")
                    Text("Scales the tint. Lower shows more glass; higher reads more easily.")
                }
                Picker("Selection", selection: $model.lensStyle) {
                    Text("Glass").tag(LensMetrics.Style.glass)
                    Text("Fill").tag(LensMetrics.Style.fill)
                }
                .pickerStyle(.segmented)
            }
            Section("Accent") {
                Toggle("Use the system accent color", isOn: $model.followsSystemAccent)
                if !model.followsSystemAccent {
                    ColorPicker("Accent color", selection: accentBinding, supportsOpacity: false)
                }
            }
            Section("Text and layout") {
                metric("Search text", value: $model.querySize, range: AppearanceModel.Limits.querySize, step: 0.5)
                metric("Titles", value: $model.titleSize, range: AppearanceModel.Limits.titleSize, step: 0.5)
                metric("Subtitles", value: $model.subtitleSize, range: AppearanceModel.Limits.subtitleSize, step: 0.5)
                metric("Row height", value: $model.rowHeight, range: AppearanceModel.Limits.rowHeight, step: 1)
                metric("Corner radius", value: $model.cornerRadius, range: AppearanceModel.Limits.cornerRadius, step: 1)
                metric(
                    "Selection corner radius", value: $model.lensCornerRadius,
                    range: AppearanceModel.Limits.lensRadius, step: 1)
            }
        }
        .formStyle(.grouped)
        .task { model.reload() }
        .alert("Save as New Theme", isPresented: $isNaming) {
            TextField("Name", text: $newName)
            Button("Save") { model.saveAsNew(named: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your themes are files in the themes folder. You can share them with Export.")
        }
    }

    private var preview: some View {
        VStack(alignment: .trailing, spacing: 8) {
            let size = ThemePreviewView.logicalSize(for: model.draft)
            ThemePreview(theme: model.draft, dark: model.previewDark)
                .aspectRatio(size.width / size.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Picker("Preview", selection: $model.previewDark) {
                Text("Match System").tag(Bool?.none)
                Text("Light").tag(Bool?.some(false))
                Text("Dark").tag(Bool?.some(true))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Preview appearance")
        }
    }

    private func tintRow(_ title: String, dark: Bool) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(
                    value: Binding(
                        get: { model.tintStrength(dark: dark) }, set: { model.setTintStrength($0, dark: dark) }),
                    in: AppearanceModel.Limits.tintStrength
                )
                .accessibilityLabel("\(title) strength")
                .accessibilityValue("\(Int(model.tintStrength(dark: dark) * 100)) percent")
                ColorPicker(title, selection: tintBinding(dark: dark), supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }

    private func metric(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View
    {
        ValueStepper(
            title: title, value: value, range: range, step: step,
            text: value.wrappedValue.formatted(.number.precision(.fractionLength(0...1))) + " pt")
    }

    private func tintBinding(dark: Bool) -> Binding<CGColor> {
        Binding(
            get: { ColorBridge.cgColor(model.glassTint(dark: dark), dark: dark) },
            set: { color in
                guard let rgb = ColorBridge.srgb(color) else { return }
                model.setGlassTintColor(red: rgb.red, green: rgb.green, blue: rgb.blue, dark: dark)
            })
    }

    private var accentBinding: Binding<CGColor> {
        Binding(
            get: { ColorBridge.cgColor(model.accent ?? ThemeColor(.accent), dark: false) },
            set: { color in
                guard let rgb = ColorBridge.srgb(color) else { return }
                model.accent = ThemeColor(red: rgb.red, green: rgb.green, blue: rgb.blue)
            })
    }
}

/// Converts theme colours to and from the colour picker's.
enum ColorBridge {
    /// The colour at full alpha, resolved for an appearance when it is a system colour.
    static func cgColor(_ color: ThemeColor, dark: Bool) -> CGColor {
        var opaque = color
        opaque.alpha = 1
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        return opaque.cgColor(in: appearance)
    }

    /// sRGB components of a picked colour.
    static func srgb(_ color: CGColor) -> (red: Double, green: Double, blue: Double)? {
        guard let converted = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
        return (Double(converted.redComponent), Double(converted.greenComponent), Double(converted.blueComponent))
    }
}
