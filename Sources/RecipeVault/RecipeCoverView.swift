import SwiftUI
import AppKit
import FujiCore

struct LocalCoverImage: View {
    let url: URL
    var height: CGFloat
    var compact = false
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Palette.paper)
                        .overlay { Image(systemName: "photo").foregroundStyle(Palette.secondary) }
                }
            }.frame(width: geometry.size.width, height: height).clipped()
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 3 : 5))
        .onAppear { load() }
        .onChange(of: url) { newURL in image = NSImage(contentsOf: newURL) }
        .accessibilityHidden(true)
    }

    private func load() { image = NSImage(contentsOf: url) }
}

struct RecipeCoverPanel: View {
    let cover: RecipeCover
    let url: URL
    let recipeName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            LocalCoverImage(url: url, height: 230)
                .accessibilityHidden(false)
                .accessibilityLabel("Illustrative cover for \(recipeName)")
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Approximate preview").font(.system(size: 11, weight: .semibold))
                    Text(cover.renderingNote).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let source = cover.sourceURL, let link = URL(string: source), ["https", "http"].contains(link.scheme?.lowercased() ?? "") {
                    Link(cover.credit, destination: link).font(.system(size: 11)).multilineTextAlignment(.trailing)
                } else {
                    Text(cover.credit).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
        }
    }
}
