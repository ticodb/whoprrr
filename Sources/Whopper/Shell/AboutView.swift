import SwiftUI
import AppKit

/// Version, how to report a problem, the privacy promise and who made what Whoprrr stands on.
struct AboutView: View {
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                LogoMark(size: 84).shadow(color: Brand.violetDeep.opacity(0.35), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Wordmark(size: 34)
                        if AppInfo.isBeta { StatusChip(text: "Beta", tone: .warn) }
                    }
                    Text(AppInfo.tagline).font(Brand.body).foregroundStyle(.secondary)
                    Text(AppInfo.versionLine).font(Brand.caption).foregroundStyle(.secondary)
                }
            }

            BrandCard {
                SectionLabel("Beta")
                Text("Whoprrr is in public beta. It changes real things on your Mac: display brightness over DDC, key and mouse events, system audio. Please report anything odd, and keep Emergency off (⌃⌥⇧⌘⎋) in mind while you try the keys and mouse rules.")
                    .font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Report a problem") { DiagnosticsReport.copy(); copied = true; NSWorkspace.shared.open(AppInfo.issuesURL) }.buttonStyle(.brand)
                    Button(copied ? "Copied" : "Copy diagnostics") { DiagnosticsReport.copy(); copied = true }.buttonStyle(.brandQuiet)
                    Button("Open data folder") { NSWorkspace.shared.open(Self.dataFolder) }.buttonStyle(.brandQuiet)
                }
                Text("“Report a problem” copies a short diagnostics summary (versions, permission states, counts: no device names, clipboard contents or rules) and opens the issue form. Paste it in.")
                    .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            BrandCard {
                SectionLabel("Privacy")
                Text("Everything stays on this Mac. Whoprrr has no account and no analytics. Its only network request is a daily check for a newer version (whoprrr.app), which you can turn off in Features. Clipboard history, rules, recipes and presets are plain files in the data folder; audio is processed live and never recorded. Otherwise it opens a web page only when you press a button above.")
                    .font(Brand.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Acknowledgments")
                ForEach(Acknowledgment.Kind.allCases, id: \.rawValue) { kind in
                    let items = Acknowledgments.all.filter { $0.kind == kind }
                    if !items.isEmpty {
                        Text(kind.rawValue).font(Brand.display(14, .semibold)).padding(.top, 4)
                        ForEach(items) { a in
                            BrandCard {
                                HStack(alignment: .firstTextBaseline) {
                                    Button(a.name) { if let u = URL(string: a.url) { NSWorkspace.shared.open(u) } }.buttonStyle(.link).font(Brand.display(14.5, .semibold))
                                    Spacer()
                                    Text(a.license).font(Brand.caption).foregroundStyle(.secondary)
                                }
                                Text(a.what).font(Brand.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            Text("\(AppInfo.name) is released under the \(AppInfo.licenseName). It is not affiliated with or endorsed by Apple, Samsung, Logitech, RØDE or any other company named here; all names are trademarks of their owners. Full notices: ACKNOWLEDGMENTS.md and THIRD_PARTY_LICENSES.md in the project.")
                .font(Brand.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Whopper", isDirectory: true)
    }
}

