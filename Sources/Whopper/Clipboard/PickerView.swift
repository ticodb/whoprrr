import SwiftUI
import ImageIO
import ClipboardCore

struct PickerView: View {
    @ObservedObject var model: PickerModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard", text: $model.query).textFieldStyle(.plain).font(Brand.title3).focused($focused)
                Picker("", selection: $model.filter) { ForEach(ClipListFilter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 270)
            }
            .padding(12)
            Divider()
            if model.items.isEmpty {
                Spacer()
                Text(model.query.isEmpty ? "Nothing copied yet" : "No matches").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                                ClipRow(item: item, index: idx, selected: item.id == model.selected)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selected = item.id }
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.choose(item) })
                            }
                        }.padding(6)
                    }
                    .onChange(of: model.selected) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
            Divider()
            HStack(spacing: 14) {
                hint("↩", "paste"); hint("⇧↩", "plain text"); hint("⌘P", "pin"); hint("⌘⌫", "delete"); hint("⇥", "filter"); hint("⌘1–9", "quick")
                Spacer()
            }
            .font(Brand.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 7)
        }
        .frame(width: 640, height: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
        .onAppear { focused = true }
    }

    private func hint(_ k: String, _ t: String) -> some View {
        HStack(spacing: 4) { Text(k).font(Brand.caption.monospaced()).padding(.horizontal, 4).background(.quaternary, in: RoundedRectangle(cornerRadius: 3)); Text(t) }
    }
}

struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            leading.frame(width: 44, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? firstLines).lineLimit(2).font(Brand.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if item.isSnippet { Text("snippet").padding(.horizontal, 4).background(.blue.opacity(0.2), in: Capsule()) }
                    if let a = item.sourceApp { Text(a) }
                    Text(item.lastUsedAt, style: .relative)
                    if item.useCount > 1 { Text("×\(item.useCount)") }
                }.font(Brand.caption2).foregroundStyle(.secondary)
            }
            if item.pinned { Image(systemName: "pin.fill").font(Brand.caption).foregroundStyle(.orange) }
            if index < 9 { Text("⌘\(index + 1)").font(Brand.caption2.monospaced()).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private var firstLines: String { item.preview.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder private var leading: some View {
        switch item.kind {
        case .image: ThumbnailView(file: item.imageFile)
        case .files: Image(systemName: item.files.count > 1 ? "doc.on.doc" : "doc").font(Brand.title3).foregroundStyle(.secondary)
        case .text: Image(systemName: item.hasRich ? "textformat" : "text.alignleft").font(Brand.title3).foregroundStyle(.secondary)
        }
    }
}

struct ThumbnailView: View {
    let file: String?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 2).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: file) {
            guard let file else { return }
            let dir = ClipStore.defaultDirectory().appendingPathComponent("images")
            image = await Task.detached { Self.thumb(dir.appendingPathComponent(file)) }.value
        }
    }

    nonisolated static func thumb(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }
}
