import AppKit
import SwiftUI

struct AboutPane: View {
    let model: AboutModel

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(model.name).font(.largeTitle).fontWeight(.semibold)
            Text(model.versionText).foregroundStyle(.secondary).textSelection(.enabled)
            Text(model.licenseText)
            Text(model.privacyText).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !model.info.links.isEmpty {
                HStack(spacing: 16) {
                    ForEach(model.info.links) { link in
                        Button(link.title) {
                            Task { await model.open(link) }
                        }
                        .buttonStyle(.link)
                        .help(link.url.absoluteString)
                    }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
