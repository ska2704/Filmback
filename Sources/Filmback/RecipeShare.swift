import AppKit
import CoreText
import FujiCore

enum RecipeShare {
    static func text(_ recipe: Recipe) -> String {
        var lines = [recipe.name]
        if let author = recipe.author, !author.isEmpty { lines.append("By \(author)") }
        if let source = recipe.sourceURL, !source.isEmpty { lines.append(source) }
        lines.append("")
        for group in RecipeSettingGroup.all {
            let fields = group.fields.filter { recipe.settings[$0] != nil }
            guard !fields.isEmpty else { continue }
            lines.append(group.title)
            lines += fields.map { "\($0.label): \(recipe.settings[$0]!)" }
            lines.append("")
        }
        if !recipe.notes.isEmpty { lines += ["Field notes", recipe.notes, ""] }
        lines.append("Only listed settings are specified. Exported with Filmback.")
        return lines.joined(separator: "\n")
    }

    static func pdf(_ recipe: Recipe) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw VaultError.message("Could not create the recipe PDF.") }
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw VaultError.message("Could not create the PDF drawing context.") }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 4
        let content = NSMutableAttributedString(string: text(recipe), attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1), .paragraphStyle: paragraph
        ])
        content.addAttributes([.font: NSFont.systemFont(ofSize: 23, weight: .semibold)], range: NSRange(location: 0, length: (recipe.name as NSString).length))
        let framesetter = CTFramesetterCreateWithAttributedString(content)
        var offset = 0
        while offset < content.length {
            context.beginPDFPage(nil)
            let path = CGPath(rect: CGRect(x: 44, y: 45, width: 507, height: 752), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let count = CTFrameGetVisibleStringRange(frame).length
            guard count > 0 else { throw VaultError.message("The recipe contains text that could not fit on a PDF page.") }
            offset += count
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
